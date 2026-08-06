import SwiftUI

/// The visual system for the Claude Stats menu bar popover: a small (~360pt wide), dense,
/// dark surface that shows live-updating numbers. Nothing in here touches app state —
/// it's pure color/spacing/type data so `Components.swift` (and the panel views built on
/// top of it) can preview standalone.
enum Theme {

    // MARK: - Surfaces

    enum Color {
        /// The popover's base background — near-black, slightly warm.
        static let background = SwiftUI.Color(hex: 0x1A1A1C)
        /// A card / tile sitting on top of `background`.
        static let surface = SwiftUI.Color(hex: 0x242427)
        /// A card sitting on top of `surface` (nested elevation, e.g. a tile inside a tile).
        static let surfaceElevated = SwiftUI.Color(hex: 0x2E2E32)
        /// 1pt separators between rows/sections.
        static let hairline = SwiftUI.Color.white.opacity(0.08)

        static let textPrimary = SwiftUI.Color.white.opacity(0.94)
        static let textSecondary = SwiftUI.Color.white.opacity(0.62)
        static let textTertiary = SwiftUI.Color.white.opacity(0.36)

        /// Claude's clay/orange accent — used sparingly for the single "live" signal
        /// (active dot, primary bar fill, highlighted numbers).
        static let accent = SwiftUI.Color(hex: 0xD97757)
        static let positive = SwiftUI.Color(hex: 0x6FCF97)
        static let negative = SwiftUI.Color(hex: 0xE0685A)

        /// Fixed per-model colors so a given model reads the same everywhere in the UI
        /// (bars, badges, legends). Unknown models fall back to a stable neutral so the
        /// UI never has to invent a color on the fly.
        private static let modelColors: [String: SwiftUI.Color] = [
            "claude-fable-5": SwiftUI.Color(hex: 0xB388FF),
            "claude-opus-4-8": SwiftUI.Color(hex: 0xD97757),
            "claude-opus-4-7": SwiftUI.Color(hex: 0xE8A87C),
            "claude-sonnet-5": SwiftUI.Color(hex: 0x6FA8DC),
            "claude-haiku-4-5": SwiftUI.Color(hex: 0x6FCF97),
        ]
        private static let unknownModelColor = SwiftUI.Color(hex: 0x8E8E93)

        /// Family-substring brand color, keyed by the same markers and checked in the same
        /// order (opus -> fable -> sonnet -> haiku) as `PricingTable.familyFallbackRate`, so an
        /// unrecognized-but-clearly-Opus/Fable/Sonnet/Haiku id (e.g. `claude-fable-6`) still
        /// gets that family's brand color instead of a hash hue — matching color classification
        /// to pricing classification (E13).
        private static func familyColor(for model: String) -> SwiftUI.Color? {
            if model.contains("-opus-") { return modelColors["claude-opus-4-8"] }
            if model.contains("-fable-") { return modelColors["claude-fable-5"] }
            if model.contains("-sonnet-") { return modelColors["claude-sonnet-5"] }
            if model.contains("-haiku-") { return modelColors["claude-haiku-4-5"] }
            return nil
        }

        /// A stable color for any model id, including ones not in the fixed map above.
        /// Callers pass the *raw* observed model id (D1b) — e.g. `claude-haiku-4-5-20251001` —
        /// which rarely equals a map key exactly, so resolution mirrors `PricingTable.lookup`:
        /// exact id, then the longest map key that is a prefix of `model`, then the family
        /// substring tier above. Only a model matching none of those falls back to a
        /// deterministic hash-derived hue, so repeated unknown models stay distinguishable
        /// without ever colliding with the fixed map or needing per-launch state.
        static func forModel(_ model: String) -> SwiftUI.Color {
            if let exact = modelColors[model] { return exact }
            let prefixMatches = modelColors.keys.filter { model.hasPrefix($0) }
            if let longest = prefixMatches.max(by: { $0.count < $1.count }) {
                return modelColors[longest]!
            }
            if let family = familyColor(for: model) { return family }
            let hue = Double(stableHash(model) % 360) / 360.0
            return SwiftUI.Color(hue: hue, saturation: 0.18, brightness: 0.62)
        }

        /// FNV-1a over the id's UTF-8 bytes. Deliberately **not** `String.hashValue`: Swift
        /// seeds String hashing randomly per process, so an unknown model's color would
        /// change on every launch of the app.
        private static func stableHash(_ string: String) -> UInt64 {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in string.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
            return hash
        }

        /// The plain gray used for "no model in particular" contexts (e.g. an empty state).
        static var unknown: SwiftUI.Color { unknownModelColor }
    }

    // MARK: - Spacing

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    // MARK: - Corner radii

    enum Radius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 10
        static let large: CGFloat = 14
    }

    // MARK: - Layout

    enum Layout {
        /// The target popover width every panel view is designed against.
        static let popoverWidth: CGFloat = 360
    }

    // MARK: - Type

    enum Typography {
        /// Large, monospaced-digit figure for a tile's headline number (e.g. token counts, cost).
        static func statValue(_ size: CGFloat = 22) -> Font {
            .system(size: size, weight: .semibold, design: .rounded).monospacedDigit()
        }
        /// Small monospaced-digit figure for inline numbers (bar rows, badges).
        static func numeric(_ size: CGFloat = 12, weight: Font.Weight = .medium) -> Font {
            .system(size: size, weight: weight, design: .default).monospacedDigit()
        }
        /// Paired with `.textCase(.uppercase)` + a touch of tracking at the call site (see
        /// `SectionHeader`) to read as a native macOS section caption.
        static let sectionHeader = Font.system(size: 11, weight: .semibold)
        static let label = Font.system(size: 12, weight: .regular)
        static let footnote = Font.system(size: 10, weight: .regular)
    }
}

extension SwiftUI.Color {
    /// Convenience hex initializer, e.g. `Color(hex: 0x1A1A1C)`.
    init(hex: UInt32, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}
