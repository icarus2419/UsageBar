import Foundation
import ServiceManagement
import UsageCore
import UserNotifications

/// iPhone-style "20% battery remaining" alerts, plus a heads-up when a limit refills.
@MainActor
final class Notifier {
    private let prefs: Prefs
    private var last: [String: Double] = [:]

    /// UserNotifications crashes outside an app bundle (e.g. `swift run`).
    private let available = Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")

    init(prefs: Prefs) {
        self.prefs = prefs
    }

    func requestPermission() {
        guard available, prefs.alerts else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Compares what is on screen now with what was on screen last time and alerts on crossings.
    func evaluate(_ store: UsageStore) {
        for provider in Provider.allCases {
            let usage = store.reading(for: provider).usage
            for window in [usage?.session, usage?.weekly].compactMap({ $0 }) {
                let key = "\(provider.rawValue).\(window.kind.rawValue)"
                let current = window.remainingPercent
                defer { last[key] = current }
                guard let previous = last[key], prefs.alerts, prefs.isShown(provider) else { continue }
                if let message = alert(provider, window, from: previous, to: current, now: store.now) {
                    post(id: key, title: message.title, body: message.body)
                }
            }
        }
    }

    private func alert(_ provider: Provider, _ window: UsageWindow, from previous: Double, to current: Double,
                       now: Date) -> (title: String, body: String)? {
        let name = provider.displayName
        let refill = UsageFormat.refill(window, now: now).map { " · \($0)" } ?? ""
        let windowName = window.label.lowercased()

        if previous > 0, current <= 0 {
            return ("\(name) is out of juice", "You've hit your \(windowName) limit\(refill).")
        }
        for threshold in [10.0, 20.0] where previous > threshold && current <= threshold {
            return ("\(name) battery low", "\(UsageFormat.percent(current)) of your \(windowName) limit left\(refill).")
        }
        if previous <= 20, current >= 99 {
            return ("\(name) recharged ⚡", "Your \(windowName) limit has reset.")
        }
        return nil
    }

    private func post(id: String, title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

enum LoginItem {
    static var isAvailable: Bool { Bundle.main.bundlePath.hasSuffix(".app") }

    static var isEnabled: Bool {
        isAvailable && SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
