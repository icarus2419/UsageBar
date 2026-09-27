import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated static let showNotification = Notification.Name("UsageBar.show")

    let prefs = Prefs()
    lazy var store = UsageStore(prefs: prefs)
    lazy var notifier = Notifier(prefs: prefs)
    private(set) var widget: WidgetController!
    private var statusItem: StatusItemController!
    private var menus: MenuBuilder!
    private var cancellables: Set<AnyCancellable> = []

    var widgetVisible: Bool { widget?.isVisible ?? false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        menus = MenuBuilder(prefs: prefs, store: store)
        menus.app = self
        widget = WidgetController(store: store, prefs: prefs)
        widget.menu = { [weak self] in self?.menus.build() ?? NSMenu() }
        statusItem = StatusItemController(store: store, prefs: prefs, menus: menus)

        // Without a menu bar item the widget is the only way back in, so never hide both.
        if prefs.widgetVisible || !prefs.showMenuBar { widget.show() }
        statusItem.setVisible(prefs.showMenuBar)
        prefs.$showMenuBar.dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] visible in
                self?.statusItem.setVisible(visible)
                if !visible { self?.widget.show() }
            }
            .store(in: &cancellables)

        store.objectWillChange
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.notifier.evaluate(self.store)
            }
            .store(in: &cancellables)

        // A second launch (e.g. `open -n`) asks this instance to show itself, then quits.
        DistributedNotificationCenter.default().addObserver(forName: Self.showNotification, object: nil,
                                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showWidget() }
        }

        store.start()
        notifier.requestPermission()
    }

    /// Opening the app again from Finder or Spotlight brings the widget back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWidget()
        return false
    }

    func showWidget() {
        widget.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }

    func hideWidget() {
        // Keep a way back: hiding the widget turns the menu bar item on.
        if !prefs.showMenuBar { prefs.showMenuBar = true }
        widget.hide()
    }
}
