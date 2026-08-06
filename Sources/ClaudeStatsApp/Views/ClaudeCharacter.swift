import SwiftUI

// The in-app "Claude character": the pixel-art Claude mascot for the collapsed island's left
// wing (D12). Pure SwiftUI — a `Canvas` painted every frame from `TimelineView`'s clock, no
// image assets, no `ClaudeStatsCore` import, no `UsageStore`. Its coral is defined locally
// (not `Theme.Color.accent`) — the two happen to share a hex value today, but the character's
// palette is its own thing, independent of the app's design system.

/// What the character is doing right now.
public enum CharacterState: Sendable {
    /// Resting: a slow breathing pulse with an occasional blink.
    case idle
    /// A working agent is waiting on the user: a faster bounce/wiggle/glow loop asking for
    /// attention.
    case nudging
}

/// The pixel-art Claude mascot: a blocky terracotta body with two rectangular cut-out eyes,
/// an arm sticking out either side, and four stubby legs — traced from the reference art as a
/// list of normalized rectangles, so it scales crisply to any size the caller lays out
/// (18×18 in the collapsed island, 64×64 in a preview) without an image asset.
public struct ClaudeCharacterView: View {
    public let state: CharacterState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(state: CharacterState) {
        self.state = state
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            Canvas { canvas, size in
                draw(&canvas, size: size, now: context.date.timeIntervalSinceReferenceDate)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    // MARK: - Pixel geometry (normalized 0…1 within the character's own bounds)

    private struct Cell {
        var x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat
    }

    /// The character is wider than tall; drawn aspect-fit inside the square canvas.
    private static let artAspect: CGFloat = 1.61

    /// Coral silhouette: body, both arms, four legs — measured off the reference image.
    private static let bodyCells: [Cell] = [
        Cell(x: 0.128, y: 0.000, w: 0.744, h: 0.803),  // body
        Cell(x: 0.000, y: 0.391, w: 0.128, h: 0.208),  // left arm
        Cell(x: 0.872, y: 0.391, w: 0.128, h: 0.208),  // right arm
        Cell(x: 0.189, y: 0.803, w: 0.060, h: 0.197),  // legs, outer left
        Cell(x: 0.322, y: 0.803, w: 0.058, h: 0.197),  // inner left
        Cell(x: 0.620, y: 0.803, w: 0.058, h: 0.197),  // inner right
        Cell(x: 0.751, y: 0.803, w: 0.060, h: 0.197),  // outer right
    ]

    /// Eye cut-outs, painted in the pill's black so they read as holes in the body.
    private static let eyeCells: [Cell] = [
        Cell(x: 0.247, y: 0.197, w: 0.062, h: 0.197),
        Cell(x: 0.692, y: 0.197, w: 0.061, h: 0.197),
    ]

    // MARK: - Drawing

    private func draw(_ context: inout GraphicsContext, size: CGSize, now: Double) {
        // `Canvas` clips to its own bounds, so the character must fit the frame in every phase of
        // every animation or the bounce flat-cuts it against the edge. Reserve the bounce
        // amplitude plus the breathing overshoot as headroom — the same reserve in both states,
        // so the character never changes size when the state flips.
        let half = min(size.width, size.height) / 2
        let reserved = max(0, (half - Self.bounceAmplitude) / Self.breathingPeak)
        let charWidth = reserved * 2
        let charHeight = charWidth / Self.artAspect

        // Every phase collapses to its rest value under reduced motion, so the character
        // renders as a single static frame — except a constant, non-animated glow while
        // nudging, which keeps the "something needs you" signal legible without motion.
        let breathe = reduceMotion ? 0 : Self.breathingScale(t: now)
        let blink = reduceMotion ? 0 : Self.blinkAmount(t: now)
        let isNudging = state == .nudging
        let bounceY = (reduceMotion || !isNudging) ? 0 : Self.bounceOffset(t: now)
        let wiggle = (reduceMotion || !isNudging) ? 0 : Self.wiggleAngle(t: now)
        let glow: Double = isNudging ? (reduceMotion ? 0.55 : Self.glowPulse(t: now)) : 0

        var body = context
        body.translateBy(x: size.width / 2, y: size.height / 2 + bounceY)
        if state == .idle {
            body.scaleBy(x: 1 + breathe, y: 1 + breathe)
        }

        if glow > 0 {
            // Capped at the reserved radius so the halo stays a circle instead of being cut
            // into a rounded square by the canvas edge.
            let glowRadius = min(charHeight * (0.9 + 0.25 * glow), reserved)
            let glowRect = CGRect(x: -glowRadius, y: -glowRadius, width: glowRadius * 2, height: glowRadius * 2)
            body.fill(
                Circle().path(in: glowRect),
                with: .radialGradient(
                    Gradient(colors: [Self.coral.opacity(0.4 * glow), Self.coral.opacity(0)]),
                    center: .zero, startRadius: 0, endRadius: glowRadius
                )
            )
        }

        // The nudge wiggle rocks the whole sprite a few degrees instead of animating limbs —
        // pixel art reads best moving as one rigid block.
        if wiggle != 0 {
            body.rotate(by: .radians(wiggle))
        }

        for cell in Self.bodyCells {
            body.fill(Path(rect(cell, charWidth: charWidth, charHeight: charHeight)), with: .color(Self.coral))
        }

        // Blink: the eye holes squash toward their top edge until they vanish into the body.
        let eyeScaleY = max(0.0, 1 - blink)
        for cell in Self.eyeCells {
            var squashed = cell
            squashed.h = cell.h * eyeScaleY
            if squashed.h > 0 {
                body.fill(Path(rect(squashed, charWidth: charWidth, charHeight: charHeight)), with: .color(Self.eyeDark))
            }
        }
    }

    /// Maps a normalized cell into canvas points, centered on the current origin.
    private func rect(_ cell: Cell, charWidth: CGFloat, charHeight: CGFloat) -> CGRect {
        CGRect(
            x: -charWidth / 2 + cell.x * charWidth,
            y: -charHeight / 2 + cell.y * charHeight,
            width: cell.w * charWidth,
            height: cell.h * charHeight
        )
    }

    // MARK: - Palette (character-owned, not `Theme`)

    private static let coral = Color(hex: 0xD97757)
    /// Matches the island pill's black so the eye cut-outs read as the background showing through.
    private static let eyeDark = Color.black

    // MARK: - Motion (pure functions of the TimelineView clock)

    /// D12's ±3pt nudge hop, in points — also the headroom reserved inside the canvas for it.
    private static let bounceAmplitude: Double = 3
    /// D12's idle breathing peak; the drawing is inset so the peak still fits the frame.
    private static let breathingPeak: Double = 1.06

    /// Idle: a 4s breathing cycle, scale 1.00 -> 1.06 -> 1.00.
    private static func breathingScale(t: Double) -> Double {
        let amplitude = (breathingPeak - 1) / 2
        let phase = t.truncatingRemainder(dividingBy: 4) / 4
        return amplitude - amplitude * cos(2 * .pi * phase)
    }

    /// Idle: a quick ~180ms blink every 3.5s, returned as 0 (open) -> 1 (closed) -> 0.
    private static func blinkAmount(t: Double) -> Double {
        let interval = 3.5
        let duration = 0.18
        let phase = t.truncatingRemainder(dividingBy: interval)
        guard phase < duration else { return 0 }
        let p = phase / duration
        return 1 - abs(2 * p - 1)
    }

    /// Nudging: a ~1.2s spring-shaped y-bounce, a decaying oscillation restarted every cycle.
    /// `exp(-3.2·p)·sin(2π·2.1·p)` peaks at ≈0.7034 (p ≈ 0.11), so dividing by that peak makes
    /// the first hop exactly the ±3pt of D12 instead of the 2.1pt the raw curve reaches.
    private static func bounceOffset(t: Double) -> Double {
        let period = 1.2
        let unitPeak = 0.7034
        let phase = t.truncatingRemainder(dividingBy: period) / period
        let decay = exp(-3.2 * phase)
        return -(bounceAmplitude / unitPeak) * decay * sin(2 * .pi * 2.1 * phase)
    }

    /// Nudging: a gentle ±4° whole-sprite rock on the same 1.2s cadence as the bounce.
    private static func wiggleAngle(t: Double) -> Double {
        let period = 1.2
        let maxRadians = 4.0 * .pi / 180
        return maxRadians * sin(2 * .pi * t / period)
    }

    /// Nudging: a soft glow pulsing 0...1 on the same 1.2s cadence.
    private static func glowPulse(t: Double) -> Double {
        let period = 1.2
        let phase = t.truncatingRemainder(dividingBy: period) / period
        return 0.5 + 0.5 * sin(2 * .pi * phase)
    }
}

// MARK: - Previews

#Preview("Idle — 18x18") {
    ClaudeCharacterView(state: .idle)
        .frame(width: 18, height: 18)
        .padding(20)
        .background(Color.black)
}

#Preview("Nudging — 18x18") {
    ClaudeCharacterView(state: .nudging)
        .frame(width: 18, height: 18)
        .padding(20)
        .background(Color.black)
}

#Preview("Idle — 64x64") {
    ClaudeCharacterView(state: .idle)
        .frame(width: 64, height: 64)
        .padding(20)
        .background(Color.black)
}

#Preview("Nudging — 64x64") {
    ClaudeCharacterView(state: .nudging)
        .frame(width: 64, height: 64)
        .padding(20)
        .background(Color.black)
}
