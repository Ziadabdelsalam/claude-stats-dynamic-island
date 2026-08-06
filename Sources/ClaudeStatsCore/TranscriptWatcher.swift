import CoreServices
import Foundation

/// FSEvents-backed watcher for `~/.claude/projects` (D4, E15, E16).
/// `FSEventStreamCreate` with `kFSEventStreamCreateFlagFileEvents` is
/// inherently recursive — a single stream on `root` catches events for
/// files at any depth, including the
/// `<encoded-dir>/<sessionId>/subagents/agent-*.jsonl` / `wf_*` layouts
/// (D2a). Deliberately not `DispatchSourceFileSystemObject`: this corpus is
/// 1500+ files, and that API neither recurses nor scales to that many open
/// fds.
///
/// **Ownership (E16).** `TranscriptWatcher` is an ordinary ARC handle: it
/// holds no reference that keeps itself alive, so it deinits immediately —
/// synchronously, on whatever thread drops its last strong reference — the
/// moment its owner is done with it, exactly like any other Swift object.
/// All of the FSEvents state instead lives on `Core`, a *separate* object
/// handed to `FSEventStreamCreate` via `Unmanaged.passRetained`: CoreServices
/// holds a genuine +1 on `Core` for as long as the stream exists, and only
/// gives that +1 back (via the context's `release` callback) once
/// `FSEventStreamRelease` actually runs. That means a callback already
/// queued on `callbackQueue` can never reference deallocated memory,
/// regardless of what happens to the public `TranscriptWatcher` handle in
/// the meantime — there is no unretained-self pointer, and no ARC-timing
/// dependence between "the owner dropped its reference" and "the stream is
/// done delivering callbacks." Because of that retain, `TranscriptWatcher
/// .deinit` cannot itself finish the teardown (`Core` may still be very
/// much alive, kept up by CoreServices) — it only *schedules* the stop,
/// asynchronously, on `callbackQueue`.
///
/// **Debounce (D4 + E15).** Coalesces bursts of filesystem activity into a
/// single `onChange` call, fired `debounceInterval` (1.0s) after the *last*
/// observed event. During a sustained burst that never has a 1.0s gap,
/// `onChange` still fires at least every `maxWaitInterval` (5.0s),
/// measured from the first event of that burst — a later, burst-ending
/// event then goes back to the normal 1.0s trailing rule. `onChange` fires
/// on `callbackQueue`, not the main thread — callers must hop to whatever
/// isolation they need themselves (`UsageStore` does this explicitly by
/// dispatching into a `@MainActor` `Task`).
public final class TranscriptWatcher {
    public typealias ChangeHandler = @Sendable () -> Void

    private let core: Core

    /// - Parameters:
    ///   - debounceInterval: fire `onChange` this long after the *last*
    ///     observed event (D4; 1.0s in production).
    ///   - maxWaitInterval: even during a continuous burst with no 1.0s
    ///     gap, fire at least this often, measured from the burst's first
    ///     event (E15; 5.0s in production).
    public init(
        root: URL,
        debounceInterval: TimeInterval = 1.0,
        maxWaitInterval: TimeInterval = 5.0,
        onChange: @escaping ChangeHandler
    ) {
        core = Core(root: root, debounceInterval: debounceInterval, maxWaitInterval: maxWaitInterval, onChange: onChange)
        core.start()
    }

    deinit {
        core.scheduleStop()
    }

    /// Synchronously tears the FSEvents stream down before returning. Safe
    /// to call more than once, and safe to just let `deinit` handle it
    /// instead — this exists for callers (tests, explicit shutdown paths)
    /// that need the stream demonstrably stopped before proceeding.
    public func stopWatching() {
        core.stopSync()
    }

    /// The actual FSEvents owner — see the type-level doc comment above for
    /// why this is a separate object from `TranscriptWatcher` itself.
    /// `@unchecked Sendable` here is honest, not a shortcut: every mutable
    /// property is only ever touched on `callbackQueue` (the FSEvents
    /// callback runs on it via `FSEventStreamSetDispatchQueue`, and every
    /// other entry point — `start`, `stopSync`, `scheduleStop` — hops onto
    /// it before touching state), so there is no data race for the
    /// compiler to actually be missing.
    fileprivate final class Core: @unchecked Sendable {
        private let root: URL
        private let debounceInterval: TimeInterval
        private let maxWaitInterval: TimeInterval
        private let onChange: ChangeHandler
        private let callbackQueue = DispatchQueue(label: "com.ziad.claudestats.transcriptwatcher")

        private var stream: FSEventStreamRef?
        private var debounceWorkItem: DispatchWorkItem?
        private var maxWaitWorkItem: DispatchWorkItem?
        /// Set on the first raw event of a burst, cleared once `fire()`
        /// runs — this is what "measured from the first event" (E15) reads.
        private var burstStartTime: DispatchTime?

        init(root: URL, debounceInterval: TimeInterval, maxWaitInterval: TimeInterval, onChange: @escaping ChangeHandler) {
            self.root = root
            self.debounceInterval = debounceInterval
            self.maxWaitInterval = maxWaitInterval
            self.onChange = onChange
        }

        func start() {
            callbackQueue.async { [self] in startStream() }
        }

        /// Called from `TranscriptWatcher.deinit` — fire-and-forget, must
        /// never block the deallocating thread.
        func scheduleStop() {
            callbackQueue.async { [self] in stopStream() }
        }

        /// Called from `TranscriptWatcher.stopWatching()` — blocks the
        /// caller until the stream is actually torn down.
        func stopSync() {
            callbackQueue.sync { [self] in stopStream() }
        }

        // MARK: - FSEvents plumbing (callbackQueue only)

        private func startStream() {
            guard stream == nil else { return }

            // +1 retain CoreServices now owns; handed back in the context's
            // `release` callback once `FSEventStreamRelease` (in
            // `stopStream`) actually tears the stream down (E16).
            let info = Unmanaged.passRetained(self).toOpaque()
            var context = FSEventStreamContext(
                version: 0,
                info: info,
                retain: nil,
                release: { info in
                    guard let info else { return }
                    Unmanaged<Core>.fromOpaque(info).release()
                },
                copyDescription: nil
            )

            let pathsToWatch = [root.path] as CFArray
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
            )

            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                { (_, info, _, _, _, _) in
                    guard let info else { return }
                    Unmanaged<Core>.fromOpaque(info).takeUnretainedValue().scheduleDebouncedChange()
                },
                &context,
                pathsToWatch,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.5, // stream latency, D4
                flags
            ) else {
                // Creation failed before CoreServices ever took the +1 —
                // give it back ourselves so `self` isn't leaked.
                Unmanaged<Core>.fromOpaque(info).release()
                return
            }

            self.stream = stream
            FSEventStreamSetDispatchQueue(stream, callbackQueue)
            FSEventStreamStart(stream)
        }

        private func stopStream() {
            debounceWorkItem?.cancel()
            maxWaitWorkItem?.cancel()
            debounceWorkItem = nil
            maxWaitWorkItem = nil
            burstStartTime = nil

            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream) // triggers the context's `release` above
            self.stream = nil
        }

        /// Runs on `callbackQueue`. D4's trailing-1.0s debounce, extended by
        /// E15's 5.0s max-wait measured from the first event of the current
        /// burst: whichever timer fires first wins, calls `onChange`, and
        /// resets burst tracking so the next raw event starts a fresh burst
        /// with its own normal 1.0s trailing behavior.
        private func scheduleDebouncedChange() {
            let now = DispatchTime.now()

            if burstStartTime == nil {
                burstStartTime = now
                let maxWaitItem = DispatchWorkItem { [weak self] in self?.fire() }
                maxWaitWorkItem = maxWaitItem
                callbackQueue.asyncAfter(deadline: now + maxWaitInterval, execute: maxWaitItem)
            }

            debounceWorkItem?.cancel()
            let trailingItem = DispatchWorkItem { [weak self] in self?.fire() }
            debounceWorkItem = trailingItem
            callbackQueue.asyncAfter(deadline: now + debounceInterval, execute: trailingItem)
        }

        /// Runs on `callbackQueue`, from either the trailing or the
        /// max-wait timer — cancel whichever one didn't win and reset burst
        /// tracking before calling out, so a later event is treated as a
        /// brand new burst (E15).
        private func fire() {
            debounceWorkItem?.cancel()
            maxWaitWorkItem?.cancel()
            debounceWorkItem = nil
            maxWaitWorkItem = nil
            burstStartTime = nil
            onChange()
        }
    }
}
