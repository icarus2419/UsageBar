import SwiftUI
import UsageCore

/// The floating pill: one mark + battery per provider.
struct WidgetView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var prefs: Prefs

    var body: some View {
        let scale = prefs.size.scale
        let providers = prefs.providers

        Group {
            if providers.isEmpty {
                Text("Choose providers…")
                    .font(.system(size: 11 * scale, weight: .medium))
                    .foregroundStyle(.secondary)
            } else if prefs.layout == .horizontal {
                HStack(spacing: 9 * scale) {
                    ForEach(providers) { provider in
                        HStack(spacing: 5 * scale) { cells(provider, scale: scale) }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(accessibilityLabel(provider))
                        if provider != providers.last {
                            RoundedRectangle(cornerRadius: 0.5)
                                .fill(Color.primary.opacity(0.14))
                                .frame(width: 1, height: 17 * scale)
                                .accessibilityHidden(true)
                        }
                    }
                }
            } else {
                // A grid keeps the batteries lined up whatever the name widths.
                Grid(alignment: .leading, horizontalSpacing: 5 * scale, verticalSpacing: 6 * scale) {
                    ForEach(providers) { provider in
                        GridRow { cells(provider, scale: scale) }
                    }
                }
            }
        }
        .padding(.horizontal, 11 * scale)
        .padding(.vertical, 8 * scale)
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.7))
        .fixedSize()
    }

    @ViewBuilder
    private func cells(_ provider: Provider, scale: CGFloat) -> some View {
        let reading = store.reading(for: provider)
        ProviderMark(provider: provider, size: 12 * scale)
        if prefs.showNames {
            Text(provider.displayName)
                .font(.system(size: 11 * scale, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        HStack(spacing: 4 * scale) {
            BatteryView(
                percent: reading.percent,
                color: Palette.level(reading.percent, colorful: prefs.colorful),
                scale: scale,
                dimmed: reading.isStale || reading.percent == nil,
                monochrome: !prefs.colorful
            )
            .overlay(alignment: .topTrailing) {
                if reading.error?.needsUserAction == true || reading.isStale || (reading.error != nil && reading.usage == nil) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 8 * scale, weight: .bold))
                        .foregroundStyle(Color.orange)
                        .background(Circle().fill(.background))
                        .offset(x: 3 * scale, y: -3 * scale)
                }
            }
            if prefs.metric == .lowest, reading.window?.kind == .weekly {
                // Tell the user the battery is showing the weekly limit, not the 5-hour one.
                Text("W")
                    .font(.system(size: 8 * scale, weight: .heavy, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func accessibilityLabel(_ provider: Provider) -> String {
        let reading = store.reading(for: provider)
        let value = reading.percent.map { "\(UsageFormat.percent($0)) remaining" } ?? "No reading"
        return "\(provider.displayName), \(value), \(reading.window?.label ?? ""). \(reading.isStale ? "Reading is old." : "")"
    }
}

/// The compact version drawn into the menu bar image.
struct MenuBarLabel: View {
    var readings: [Reading]

    var body: some View {
        HStack(spacing: 7) {
            ForEach(readings, id: \.provider) { reading in
                HStack(spacing: 3) {
                    ProviderMark(provider: reading.provider, size: 10)
                    BatteryView(
                        percent: reading.percent,
                        color: Palette.level(reading.percent, colorful: false),
                        scale: 0.75,
                        dimmed: reading.isStale || reading.percent == nil,
                        monochrome: true
                    )
                }
            }
        }
        .padding(.vertical, 2)
        .fixedSize()
    }
}
