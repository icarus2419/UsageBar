import Foundation

public enum UsageFormat {
    /// "45m", "2h 13m", "3d 4h".
    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded(.up)))
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
        let days = hours / 24
        return hours % 24 == 0 ? "\(days)d" : "\(days)d \(hours % 24)h"
    }

    /// "refills in 2h 13m", or "refills Tue 9:00 AM" when the reset is more than a day out.
    public static func refill(_ window: UsageWindow, now: Date) -> String? {
        guard let resetsAt = window.resetsAt else {
            return window.kind == .session && window.remainingPercent == 100 ? "full · starts on next use" : nil
        }
        let remaining = resetsAt.timeIntervalSince(now)
        if remaining <= 0 { return "refilled" }
        if remaining < 24 * 3600 { return "refills in \(duration(remaining))" }
        return "refills \(weekdayTime.string(from: resetsAt))"
    }

    /// "just now", "4 min ago", "3 h ago".
    public static func ago(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) h ago" }
        return "\(Int(seconds / 86400)) d ago"
    }

    public static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    private static let weekdayTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE j:mm")
        return formatter
    }()

    /// One line per provider, for `--print` and status lines.
    public static func summary(_ usage: ProviderUsage, now: Date) -> String {
        let projected = usage.projected(at: now)
        var parts: [String] = []
        for window in projected.windows {
            var part = "\(window.label) \(percent(window.remainingPercent)) left"
            if let refill = refill(window, now: now) { part += " (\(refill))" }
            parts.append(part)
        }
        let plan = usage.plan.map { " [\($0)]" } ?? ""
        return "\(usage.provider.displayName)\(plan): " + parts.joined(separator: " · ")
    }
}
