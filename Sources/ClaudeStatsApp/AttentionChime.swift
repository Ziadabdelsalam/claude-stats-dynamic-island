import AppKit
import Observation
import ClaudeStatsCore

/// The audible counterpart of the character walking out: whenever attention
/// goes from none to some, plays an 8-bit "coin" chime three times.
///
/// The sound is synthesized at startup — a two-note square-wave blip
/// (B5 -> E6) with a fast decay, rendered as 16-bit mono WAV in memory and
/// handed to `NSSound` — no audio asset, matching the character's no-asset
/// `Canvas` art. The three repeats (with gaps) are baked into the buffer,
/// so one `play()` is the whole notification.
@MainActor
@Observable
final class AttentionChime {
    @ObservationIgnored private let store: UsageStore
    @ObservationIgnored private var wasNudging: Bool
    @ObservationIgnored private var sound: NSSound?

    /// User-facing mute switch (the popover header's speaker button). Persisted so a
    /// muted chime stays muted across relaunches; the attention beacons (character walk,
    /// status-item dot) are visual and keep working regardless.
    var isMuted: Bool = UserDefaults.standard.bool(forKey: AttentionChime.mutedDefaultsKey) {
        didSet { UserDefaults.standard.set(isMuted, forKey: Self.mutedDefaultsKey) }
    }

    private static let mutedDefaultsKey = "attentionChimeMuted"

    init(store: UsageStore) {
        self.store = store
        self.wasNudging = !store.pendingAttention.isEmpty
        armObservation()
    }

    /// Same one-shot re-arming pattern as `StatusItemController`'s title
    /// observation: `withObservationTracking` fires once per registration.
    private func armObservation() {
        withObservationTracking {
            _ = store.pendingAttention
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.pendingAttentionChanged()
                self.armObservation()
            }
        }
    }

    private func pendingAttentionChanged() {
        let nudging = !store.pendingAttention.isEmpty
        defer { wasNudging = nudging }
        // Edge-triggered: chime only when attention appears where there was
        // none — a second session joining an already-lit beacon stays silent.
        guard nudging, !wasNudging, !isMuted else { return }
        sound?.stop()
        sound = NSSound(data: Self.chimeWAV)
        sound?.volume = 0.5
        sound?.play()
    }

    // MARK: - Synthesis

    private static let sampleRate = 44_100.0

    /// Three repeats of the blip, gaps included, as one WAV.
    private static let chimeWAV: Data = {
        var samples: [Int16] = []
        for _ in 0..<3 {
            samples += squareNote(frequency: 988, duration: 0.085, amplitude: 0.22, decayRate: 3)
            samples += squareNote(frequency: 1319, duration: 0.26, amplitude: 0.22, decayRate: 11)
            samples += [Int16](repeating: 0, count: Int(0.38 * sampleRate))
        }
        return wav(from: samples)
    }()

    /// A square wave — the 8-bit timbre — with an exponential decay envelope.
    private static func squareNote(
        frequency: Double, duration: Double, amplitude: Double, decayRate: Double
    ) -> [Int16] {
        let count = Int(duration * sampleRate)
        return (0..<count).map { i in
            let t = Double(i) / sampleRate
            let wave: Double = sin(2 * .pi * frequency * t) >= 0 ? 1 : -1
            let envelope = exp(-decayRate * t)
            return Int16(max(-1, min(1, wave * amplitude * envelope)) * 32_767)
        }
    }

    /// Minimal RIFF/WAVE wrapper: PCM, 16-bit, mono.
    private static func wav(from samples: [Int16]) -> Data {
        var data = Data()
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        append(36 + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))                       // fmt chunk size
        append(UInt16(1))                        // PCM
        append(UInt16(1))                        // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate) * 2)           // byte rate
        append(UInt16(2))                        // block align
        append(UInt16(16))                       // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(byteCount)
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}
