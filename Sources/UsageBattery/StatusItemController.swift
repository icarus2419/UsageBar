import AppKit
import Combine
import SwiftUI

/// Mini batteries in the menu bar, right next to the Mac's own.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let store: UsageStore
    private let prefs: Prefs
    private let menus: MenuBuilder
    private var item: NSStatusItem?
    private var appearanceObservation: NSKeyValueObservation?
    private var cancellables: Set<AnyCancellable> = []

    init(store: UsageStore, prefs: Prefs, menus: MenuBuilder) {
        self.store = store
        self.prefs = prefs
        self.menus = menus
        super.init()

        store.objectWillChange.merge(with: prefs.objectWillChange)
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &cancellables)
    }

    func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let item = NSStatusItem.variableLength
            let statusItem = NSStatusBar.system.statusItem(withLength: item)
            let menu = NSMenu()
            menu.delegate = self
            statusItem.menu = menu
            statusItem.button?.imagePosition = .imageOnly
            appearanceObservation = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
                DispatchQueue.main.async { self?.render() }
            }
            self.item = statusItem
            render()
        } else if !visible, let item {
            appearanceObservation = nil
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    /// Rebuilt every time it opens so the numbers and checkmarks are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for entry in menus.build().items {
            entry.menu?.removeItem(entry)
            menu.addItem(entry)
        }
    }

    private func render() {
        guard let button = item?.button else { return }
        let readings = prefs.providers.map { store.reading(for: $0) }
        guard !readings.isEmpty else {
            button.image = NSImage(systemSymbolName: "battery.50", accessibilityDescription: "UsageBar")
            return
        }
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let renderer = ImageRenderer(content: MenuBarLabel(readings: readings)
            .environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        button.image = renderer.nsImage
        button.toolTip = readings.map { reading in
            "\(reading.provider.displayName): " + (reading.percent.map { "\(Int($0.rounded()))% left" } ?? "no data")
        }.joined(separator: " · ")
        button.setAccessibilityLabel(button.toolTip)
    }
}
