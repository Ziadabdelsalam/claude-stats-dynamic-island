import SwiftUI
import Foundation

// Reusable building blocks for the popover. Every view here takes plain data (String, Int,
// Double, [Double], Color) — never a ClaudeStatsCore type and never app state — so each one
// previews standalone with dummy data.

// MARK: - Formatting helpers

extension Int {
    /// Compact, stable-width token count: `847` / `847K` / `1.2M` / `1.2B`. Deliberately drops
    /// the decimal below 1M so a live-refreshing figure doesn't jitter as it crosses a
    /// threshold. Tier boundaries sit where the *rounded* value would reach the next unit, so
    /// this never renders `1000K` or `1000.0M`. The billions tier matters: all-time totals over
    /// the real corpus are ~10^9 tokens.
    var compactTokens: String {
        // `.magnitude` rather than `abs()` — `abs(Int.min)` traps.
        let magnitude = self.magnitude
        let sign = self < 0 ? "-" : ""
        switch magnitude {
        case 999_950_000...:
            return "\(sign)\(String(format: "%.1f", Double(magnitude) / 1_000_000_000))B"
        case 1_000_000...:
            return "\(sign)\(String(format: "%.1f", Double(magnitude) / 1_000_000))M"
        case 1_000...:
            return "\(sign)\(magnitude / 1_000)K"
        default:
            return "\(self)"
        }
    }
}

/// Thousands-grouped, always-two-decimals formatter backing `Double.currency` (D1c). A single
/// shared instance is fine here — currency formatting only ever happens on the main actor while
/// rendering SwiftUI views.
private let currencyMagnitudeFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    // Pinned, NOT `Locale.current`: D1c specifies `$1,234.56` for every user. An unpinned
    // formatter renders Arabic-Indic digits under `ar_*` and lakh/crore grouping under
    // `en_IN` (`$12,34,567.89`), which also breaks monospaced-digit column alignment.
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = true
    formatter.groupingSeparator = ","
    formatter.decimalSeparator = "."
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    return formatter
}()

extension Double {
    /// USD currency string with thousands separators, always two decimals: `$1,234.56`
    /// (D1c). `estimated: true` prefixes `≈` — the mandatory signal (D1) that this figure
    /// includes spend from a model with no confirmed list price. Exempt: the status-item's
    /// compact form, which keeps `Int.compactTokens` unchanged.
    func currency(estimated: Bool) -> String {
        let magnitude = abs(self)
        let sign = self < 0 ? "-" : ""
        let formatted = currencyMagnitudeFormatter.string(from: NSNumber(value: magnitude)) ?? String(format: "%.2f", magnitude)
        let body = "$" + formatted
        let prefix = estimated ? "≈" : ""
        return "\(prefix)\(sign)\(body)"
    }
}

// MARK: - StatTile

/// A labeled headline figure — the primary way numbers are surfaced ("Today", "12.4K tokens").
struct StatTile: View {
    let label: String
    let value: String
    /// Small secondary figure under the value, e.g. a delta or a unit ("$4.12 today").
    var delta: String? = nil
    var deltaColor: Color = Theme.Color.textSecondary

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(label)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Color.textSecondary)
            Text(value)
                .font(Theme.Typography.statValue())
                .foregroundStyle(Theme.Color.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let delta {
                Text(delta)
                    .font(Theme.Typography.numeric(11, weight: .regular))
                    .foregroundStyle(deltaColor)
            }
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
    }
}

#Preview("StatTile") {
    HStack(spacing: Theme.Spacing.sm) {
        StatTile(label: "TOKENS TODAY", value: "1.2M", delta: "+18% vs yesterday", deltaColor: Theme.Color.positive)
        StatTile(label: "COST TODAY", value: "≈$1,234.56")
    }
    .padding()
    .frame(width: Theme.Layout.popoverWidth)
    .background(Theme.Color.background)
}

// MARK: - BarRow

/// A single labeled row with a proportional horizontal bar and a right-aligned value —
/// the workhorse for "top projects" / "per-model split" lists.
struct BarRow: View {
    let label: String
    /// This row's magnitude relative to `maxValue` (both plain `Double`s; caller decides
    /// whether that's tokens, cost, or anything else).
    let value: Double
    let maxValue: Double
    let displayValue: String
    var color: Color = Theme.Color.accent

    private var fraction: Double {
        guard maxValue > 0 else { return 0 }
        return min(max(value / maxValue, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Text(label)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Color.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: Theme.Spacing.sm)
                Text(displayValue)
                    .font(Theme.Typography.numeric())
                    .foregroundStyle(Theme.Color.textSecondary)
                    .lineLimit(1)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.Color.surfaceElevated)
                    Capsule()
                        .fill(color)
                        .frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 5)
        }
    }
}

#Preview("BarRow") {
    VStack(spacing: Theme.Spacing.md) {
        BarRow(label: "claude-stats-dynamic-island", value: 820_000, maxValue: 820_000, displayValue: "820K", color: Theme.Color.forModel("claude-sonnet-5"))
        BarRow(label: "esca-platform", value: 410_000, maxValue: 820_000, displayValue: "410K", color: Theme.Color.forModel("claude-opus-4-8"))
        BarRow(label: "notes", value: 12_000, maxValue: 820_000, displayValue: "12K", color: Theme.Color.forModel("claude-haiku-4-5"))
    }
    .padding()
    .frame(width: Theme.Layout.popoverWidth)
    .background(Theme.Color.background)
}

// MARK: - Sparkline

/// A tiny trend line over a fixed series (e.g. 30 days of cost/tokens), drawn with a plain
/// `Path` so there's no dependency on a charting framework.
struct Sparkline: View {
    let values: [Double]
    var color: Color = Theme.Color.accent
    var fill: Bool = true

    /// A NaN or infinity reaching a `Path` is a hard crash in AppKit, not a warning — so any
    /// non-finite sample is clamped to 0 before it can contaminate the normalization.
    private var samples: [Double] {
        values.map { $0.isFinite ? $0 : 0 }
    }

    private var normalized: [Double] {
        let samples = self.samples
        // `hi > lo` also covers the all-identical case (zero range) — no divide by zero.
        guard let lo = samples.min(), let hi = samples.max(), hi > lo else {
            return samples.map { _ in 0.5 }
        }
        return samples.map { ($0 - lo) / (hi - lo) }
    }

    /// Builds the open stroke path for the trend line itself.
    private func linePath(width: CGFloat, height: CGFloat) -> Path {
        let points = normalized
        guard !points.isEmpty else { return Path() }
        let step = points.count > 1 ? width / CGFloat(points.count - 1) : 0
        return Path { path in
            for (index, value) in points.enumerated() {
                let point = CGPoint(x: CGFloat(index) * step, y: height - CGFloat(value) * height)
                if index == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
            // One sample has no segment to stroke and would render nothing — draw it flat
            // across the full width instead.
            if points.count == 1 {
                path.addLine(to: CGPoint(x: width, y: height - CGFloat(points[0]) * height))
            }
        }
    }

    /// Closes the line path down to the baseline so it can be filled as a gradient wash.
    private func fillPath(width: CGFloat, height: CGFloat) -> Path {
        // `addLine` on an empty path has no current point — bail before building one.
        guard !values.isEmpty else { return Path() }
        var path = linePath(width: width, height: height)
        path.addLine(to: CGPoint(x: width, y: height))
        path.addLine(to: CGPoint(x: 0, y: height))
        path.closeSubpath()
        return path
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height

            ZStack {
                if fill {
                    fillPath(width: width, height: height)
                        .fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                }
                linePath(width: width, height: height)
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

#Preview("Sparkline") {
    Sparkline(values: (0..<30).map { i in Double(50 + Int(30 * sin(Double(i) / 3)) + i) })
        .frame(width: Theme.Layout.popoverWidth - 32, height: 44)
        .padding()
        .background(Theme.Color.background)
}

// MARK: - SectionHeader

/// A small uppercase caption used to separate blocks within a panel ("PROJECTS", "MODELS").
struct SectionHeader: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack {
            Text(title)
                .font(Theme.Typography.sectionHeader)
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(Theme.Color.textTertiary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(Theme.Typography.numeric(11))
                    .foregroundStyle(Theme.Color.textTertiary)
            }
        }
    }
}

#Preview("SectionHeader") {
    SectionHeader(title: "Projects", trailing: "30 days")
        .padding()
        .frame(width: Theme.Layout.popoverWidth)
        .background(Theme.Color.background)
}

// MARK: - TokenBadge

/// A small colored pill pairing a model (or any label) with a compact token count — used in
/// legends and per-model summaries.
struct TokenBadge: View {
    let label: String
    let tokens: Int
    var color: Color = Theme.Color.accent

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Color.textPrimary)
            Text(tokens.compactTokens)
                .font(Theme.Typography.numeric(11))
                .foregroundStyle(Theme.Color.textSecondary)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .background(Theme.Color.surfaceElevated, in: Capsule())
    }
}

#Preview("TokenBadge") {
    HStack(spacing: Theme.Spacing.sm) {
        TokenBadge(label: "sonnet-5", tokens: 820_000, color: Theme.Color.forModel("claude-sonnet-5"))
        TokenBadge(label: "opus-4-8", tokens: 1_240_000, color: Theme.Color.forModel("claude-opus-4-8"))
        TokenBadge(label: "haiku-4-5", tokens: 42_000, color: Theme.Color.forModel("claude-haiku-4-5"))
    }
    .padding()
    .frame(width: Theme.Layout.popoverWidth)
    .background(Theme.Color.background)
}

// MARK: - FootnoteLabel

/// Small tertiary disclaimer text, e.g. the pricing-estimate footer ("≈ rates estimated
/// for: claude-fable-5" per D1c). Deliberately quiet — it's a footnote, not a warning.
struct FootnoteLabel: View {
    let text: String
    /// The leading `≈` is the estimated-pricing marker (D1c — `≈` everywhere, not `~`). Turn
    /// it off for footnotes that aren't about estimates (e.g. "updated 2s ago") so the marker
    /// keeps its meaning.
    var showsEstimateMarker: Bool = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
            if showsEstimateMarker {
                Text("≈")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.Color.textTertiary)
            }
            Text(text)
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.Color.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

#Preview("FootnoteLabel") {
    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
        FootnoteLabel(text: "rates estimated for: claude-fable-5")
        FootnoteLabel(text: "updated 2s ago", showsEstimateMarker: false)
    }
    .padding()
    .frame(width: Theme.Layout.popoverWidth, alignment: .leading)
    .background(Theme.Color.background)
}
