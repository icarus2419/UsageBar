import SwiftUI
import UsageCore

enum Palette {
    static let green = Color(red: 0.20, green: 0.78, blue: 0.35)
    static let yellow = Color(red: 1.00, green: 0.80, blue: 0.00)
    static let red = Color(red: 1.00, green: 0.23, blue: 0.19)
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)

    /// iOS rules: red under 20%. Colourful mode adds green/yellow; mono mode fills with the label colour.
    static func level(_ percent: Double?, colorful: Bool) -> Color {
        guard let percent else { return .secondary }
        if percent < 20 { return red }
        if !colorful { return .primary }
        return percent < 50 ? yellow : green
    }
}

/// A compact battery with text that keeps its contrast on both the fill and track.
struct BatteryView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var percent: Double?
    var color: Color
    var scale: CGFloat = 1
    var dimmed = false
    var monochrome = false

    private var label: String {
        percent.map { "\(Int($0.rounded()))" } ?? "–"
    }

    var body: some View {
        let width = 34 * scale
        let height = 18 * scale
        let body = RoundedRectangle(cornerRadius: 4.4 * scale, style: .continuous)
        let value = percent ?? 0
        // Like iOS, a nearly empty battery still shows a red sliver; a flat one turns its body red.
        let fillWidth = value > 0 ? max(width * CGFloat(value / 100), 2.5 * scale) : 0
        let track = percent == 0 ? Palette.red.opacity(0.18) : Color.primary.opacity(0.12)
        let fillText: Color = monochrome && value >= 20
            ? (colorScheme == .dark ? .black : .white) : .black

        HStack(spacing: 1.2 * scale) {
            ZStack(alignment: .leading) {
                body.fill(track)
                Rectangle()
                    .fill(color)
                    .frame(width: fillWidth)
                number(width: width, height: height).foregroundStyle(.primary)
                number(width: width, height: height).foregroundStyle(fillText)
                    .mask(alignment: .leading) { Rectangle().frame(width: fillWidth) }
            }
            .frame(width: width, height: height)
            .clipShape(body)
            .overlay(body.strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.7 * scale))

            RoundedRectangle(cornerRadius: 1.1 * scale, style: .continuous)
                .fill((percent ?? 0) >= 99.5 ? color : track)
                .frame(width: 2 * scale, height: 5.5 * scale)
        }
        .opacity(dimmed ? 0.6 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: percent)
        .accessibilityElement()
        .accessibilityLabel(percent.map { "\(Int($0.rounded())) percent" } ?? "Unknown")
    }

    private func number(width: CGFloat, height: CGFloat) -> some View {
        Text(label)
            .font(.system(size: 12 * scale, weight: .bold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: width, height: height)
    }
}

/// A small, logo-free mark for each provider: a Claude-orange spark and a hexagon for OpenAI.
struct ProviderMark: View {
    var provider: Provider
    var size: CGFloat

    var body: some View {
        switch provider {
        case .claude:
            Spark()
                .stroke(Palette.claude, style: StrokeStyle(lineWidth: size * 0.15, lineCap: .round))
                .frame(width: size, height: size)
        case .openai:
            Hexagon()
                .stroke(Color.primary.opacity(0.9), style: StrokeStyle(lineWidth: size * 0.15, lineJoin: .round))
                .frame(width: size * 0.9, height: size)
                .frame(width: size, height: size)
        }
    }
}

private struct Spark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 * 0.92
        let rays = 10
        for index in 0..<rays {
            let angle = CGFloat(index) / CGFloat(rays) * 2 * .pi - .pi / 2
            let length = radius * (index.isMultiple(of: 2) ? 1 : 0.68)
            path.move(to: CGPoint(x: center.x + cos(angle) * radius * 0.18,
                                  y: center.y + sin(angle) * radius * 0.18))
            path.addLine(to: CGPoint(x: center.x + cos(angle) * length,
                                     y: center.y + sin(angle) * length))
        }
        return path
    }
}

private struct Hexagon: Shape {
    func path(in rect: CGRect) -> Path {
        let inset = rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.08)
        let center = CGPoint(x: inset.midX, y: inset.midY)
        let radius = min(inset.width, inset.height) / 2
        var path = Path()
        for index in 0..<6 {
            let angle = CGFloat(index) / 6 * 2 * .pi - .pi / 2
            let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}
