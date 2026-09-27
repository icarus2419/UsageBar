import AppKit
import UsageCore

/// NSMenuItem that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", checked: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
        state = checked ? .on : .off
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

/// Builds the one menu used by both the menu bar item and the widget's right-click.
@MainActor
final class MenuBuilder {
    private let prefs: Prefs
    private let store: UsageStore
    weak var app: AppDelegate?

    init(prefs: Prefs, store: UsageStore) {
        self.prefs = prefs
        self.store = store
    }

    func build() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        for provider in prefs.providers {
            menu.addItem(statusLine(provider))
        }
        if !prefs.providers.isEmpty { menu.addItem(.separator()) }

        menu.addItem(ActionItem("Usage Details", key: "d") { [weak app] in app?.widget.showDetail() })
        menu.addItem(ActionItem("Refresh Now", key: "r") { [store] in store.refresh() })
        if app?.widgetVisible == true {
            menu.addItem(ActionItem("Hide Widget") { [weak app] in app?.hideWidget() })
        } else {
            menu.addItem(ActionItem("Show Widget") { [weak app] in app?.showWidget() })
        }
        menu.addItem(.separator())

        menu.addItem(submenu("Battery Shows", Metric.allCases.map { metric in
            ActionItem(metric.title, checked: prefs.metric == metric) { [prefs] in prefs.metric = metric }
        }))
        menu.addItem(submenu("Providers", Provider.allCases.map { provider in
            ActionItem(provider.displayName, checked: prefs.isShown(provider)) { [prefs] in
                prefs.setShown(provider, !prefs.isShown(provider))
            }
        }))
        menu.addItem(widgetMenu())
        menu.addItem(submenu("Refresh Every", [1, 2, 5, 10].map { minutes in
            ActionItem("\(minutes) min", checked: prefs.refreshMinutes == minutes) { [prefs] in
                prefs.refreshMinutes = minutes
            }
        }))
        menu.addItem(.separator())

        menu.addItem(ActionItem("Low Battery Alerts", checked: prefs.alerts) { [prefs, weak app] in
            prefs.alerts.toggle()
            app?.notifier.requestPermission()
        })
        menu.addItem(ActionItem("Show in Menu Bar", checked: prefs.showMenuBar) { [prefs] in
            prefs.showMenuBar.toggle()
        })
        let login = ActionItem("Launch at Login", checked: LoginItem.isEnabled) {
            do {
                try LoginItem.set(!LoginItem.isEnabled)
            } catch {
                let alert = NSAlert(error: error)
                alert.messageText = "Couldn't change the login item"
                alert.runModal()
            }
        }
        login.isEnabled = LoginItem.isAvailable
        menu.addItem(login)
        menu.addItem(.separator())

        menu.addItem(ActionItem("About Usage Battery") {
            if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
            NSApp.orderFrontStandardAboutPanel(options: [
                .credits: NSAttributedString(
                    string: "Your Claude and OpenAI plan limits, as a battery.\nReads the logins Claude Code and Codex already have. Nothing leaves your Mac except requests to Anthropic and OpenAI.",
                    attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
                ),
            ])
        })
        menu.addItem(ActionItem("Quit Usage Battery", key: "q") { NSApp.terminate(nil) })
        return menu
    }

    private func widgetMenu() -> NSMenuItem {
        var items: [NSMenuItem] = Placement.allCases.map { placement in
            ActionItem(placement.title, checked: prefs.placement == placement) { [prefs] in
                prefs.placement = placement
            }
        }
        items.append(.separator())
        items.append(ActionItem("Lock Position", checked: prefs.locked) { [prefs] in prefs.locked.toggle() })
        items.append(ActionItem("Snap to Edges", checked: prefs.snapToEdges) { [prefs] in prefs.snapToEdges.toggle() })
        items.append(ActionItem("Reset Position") { [weak app] in app?.widget.resetPosition() })
        items.append(.separator())
        items.append(submenu("Layout", Layout.allCases.map { layout in
            ActionItem(layout.title, checked: prefs.layout == layout) { [prefs] in prefs.layout = layout }
        }))
        items.append(submenu("Size", WidgetSize.allCases.map { size in
            ActionItem(size.title, checked: prefs.size == size) { [prefs] in prefs.size = size }
        }))
        items.append(submenu("Opacity", [1.0, 0.85, 0.7, 0.5].map { value in
            ActionItem("\(Int(value * 100))%", checked: abs(prefs.opacity - value) < 0.01) { [prefs] in
                prefs.opacity = value
            }
        }))
        items.append(submenu("Appearance", Theme.allCases.map { theme in
            ActionItem(theme.title, checked: prefs.theme == theme) { [prefs] in prefs.theme = theme }
        }))
        items.append(.separator())
        items.append(ActionItem("Colored Batteries", checked: prefs.colorful) { [prefs] in prefs.colorful.toggle() })
        items.append(ActionItem("Show Provider Names", checked: prefs.showNames) { [prefs] in prefs.showNames.toggle() })
        return submenu("Widget", items)
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        items.forEach(menu.addItem)
        item.submenu = menu
        return item
    }

    /// "Claude — 21% · 5-hour · refills in 2h 29m"
    private func statusLine(_ provider: Provider) -> NSMenuItem {
        let reading = store.reading(for: provider)
        var text = provider.displayName + "  "
        if let window = reading.window {
            text += "\(UsageFormat.percent(window.remainingPercent)) · \(window.label)"
            if let refill = UsageFormat.refill(window, now: store.now) { text += " · \(refill)" }
        } else {
            text += reading.error?.shortLabel ?? (reading.isLoading ? "Loading…" : "No data")
        }
        let item = ActionItem(text) { NSWorkspace.shared.open(provider.usagePageURL) }
        item.toolTip = reading.error?.localizedDescription ?? "Open the \(provider.displayName) usage page"
        return item
    }
}
