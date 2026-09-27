import SwiftUI
import UsageCore

/// A readable overview with a source and age for every provider.
struct DetailView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var prefs: Prefs
    var onRefresh: () -> Void
    var onSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("UsageBar").font(.headline)
                    Text("Your plan limits, at a glance")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onSettings) { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Settings")
                    .help("Widget and update settings")
                    .padding(4)
            }

            Picker("Battery shows", selection: $prefs.metric) {
                Text("Lowest").tag(Metric.lowest)
                Text("5-hour").tag(Metric.session)
                Text("Weekly").tag(Metric.weekly)
            }
            .pickerStyle(.segmented)
            .help("Choose which limit the floating batteries show")

            if prefs.providers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "battery.0").font(.title2)
                    Text("Choose a provider").font(.headline)
                    Text("Turn on Claude or OpenAI in Settings to see your available capacity.")
                        .font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("Open Settings", action: onSettings)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 16)
            }

            ForEach(prefs.providers) { provider in
                ProviderSection(reading: store.reading(for: provider), now: store.now, colorful: prefs.colorful)
            }

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Checks use no AI tokens", systemImage: "checkmark.shield")
                        .font(.caption.weight(.medium))
                    Text("Automatic checks every \(prefs.refreshMinutes) min")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(action: onRefresh) {
                    Label(store.loading.isEmpty ? "Refresh" : "Checking", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.medium))
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!store.loading.isEmpty || prefs.providers.isEmpty)
                .help("Check usage now; rate-limit waits are respected")
            }
        }
        .padding(16)
        .frame(width: 350)
    }
}

private struct ProviderSection: View {
    var reading: Reading
    var now: Date
    var colorful: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 9) {
                ProviderMark(provider: reading.provider, size: 21).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(reading.provider.displayName).font(.headline)
                    Text(reading.usage?.plan ?? "Plan usage")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(reading.percent.map(UsageFormat.percent) ?? "–")
                        .font(.system(size: 25, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(reading.window.map { "\($0.label.lowercased()) left" } ?? "No reading yet")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Link(destination: reading.provider.usagePageURL) {
                    Image(systemName: "arrow.up.right").font(.caption.weight(.semibold))
                        .frame(width: 22, height: 28)
                }
                .accessibilityLabel("Open \(reading.provider.displayName) usage page")
                .help("Open \(reading.provider.displayName) usage page")
            }

            if let usage = reading.usage {
                ForEach(Array(usage.windows.enumerated()), id: \.offset) { _, window in
                    WindowRow(window: window, now: now, colorful: colorful)
                }
            } else {
                Text(reading.isLoading ? "Checking your plan limits…" : "A usage reading will appear after you sign in.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 4) {
                Image(systemName: statusSymbol)
                Text(status).lineLimit(2)
                Spacer(minLength: 0)
            }
            .font(.caption2)
            .foregroundStyle(reading.isStale ? Color.orange : Color.secondary)
            .accessibilityElement(children: .combine)

            if reading.isProjected {
                Text("Reset time passed · awaiting a fresh reading")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if let error = reading.error {
                VStack(alignment: .leading, spacing: 4) {
                    Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                        .fixedSize(horizontal: false, vertical: true)
                    if let retry = reading.nextCheckAt, retry > now {
                        Text("Next check in \(UsageFormat.duration(retry.timeIntervalSince(now)))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
    }

    private var statusSymbol: String {
        if reading.isLoading { return "arrow.triangle.2.circlepath" }
        if reading.isStale { return "clock.badge.exclamationmark" }
        if reading.usage == nil { return reading.error == nil ? "clock" : "exclamationmark.circle" }
        return reading.usage?.source == .localLog ? "bolt.horizontal.circle" : "checkmark.circle"
    }

    private var status: String {
        if reading.isLoading { return "Checking usage…" }
        guard let usage = reading.usage else { return reading.error?.shortLabel ?? "Waiting for first reading" }
        let source = usage.source == .localLog ? "Codex session log" : "Usage service"
        let prefix = reading.isStale ? "Last known · " : ""
        return prefix + source + " · " + UsageFormat.ago(usage.observedAt, now: now)
    }
}

private struct WindowRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var window: UsageWindow
    var now: Date
    var colorful: Bool

    var body: some View {
        let remaining = window.remainingPercent
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(window.label).font(.caption.weight(.medium))
                Spacer()
                Text("\(UsageFormat.percent(remaining)) left")
                    .font(.caption.weight(.semibold)).monospacedDigit()
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.09))
                    Capsule()
                        .fill(Palette.level(remaining, colorful: colorful))
                        .frame(width: geometry.size.width * remaining / 100)
                }
            }
            .frame(height: 5)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: remaining)
            if let refill = UsageFormat.refill(window, now: now) {
                Text(refill).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.label), \(UsageFormat.percent(remaining)) remaining. \(UsageFormat.refill(window, now: now) ?? "Reset time unavailable")")
    }
}
