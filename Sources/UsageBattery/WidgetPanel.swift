import AppKit
import Combine
import SwiftUI

/// Borderless, non-activating panel: it never steals focus from the app you're typing in.
final class WidgetPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 150, height: 28),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that reports when its SwiftUI content changes size.
final class SizingHostingView<Content: View>: NSHostingView<Content> {
    var onSizeChange: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.onSizeChange?() }
    }
}

/// Frosted background + SwiftUI content. Owns all mouse handling so the pill can be
/// dragged, clicked and right-clicked anywhere.
final class WidgetContainerView: NSView {
    let hosting: SizingHostingView<AnyView>
    private let effect = NSVisualEffectView()

    var isLocked: () -> Bool = { false }
    var onClick: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var menuProvider: (() -> NSMenu)?

    private var dragOrigin: (mouse: NSPoint, window: NSPoint)?
    private var dragged = false

    init(content: AnyView) {
        hosting = SizingHostingView(rootView: content)
        super.init(frame: .zero)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        addSubview(effect)
        addSubview(hosting)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        effect.frame = bounds
        hosting.frame = bounds
        let radius = min(bounds.height / 2, 16)
        effect.maskImage = Self.mask(radius: radius)
    }

    /// Stretchable rounded-rect mask; the window shadow follows its alpha.
    private static func mask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // Swallow all events so SwiftUI doesn't, and so the first click works without activation.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func resetCursorRects() {
        if !isLocked() { addCursorRect(bounds, cursor: .openHand) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragOrigin = (NSEvent.mouseLocation, window.frame.origin)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let origin = dragOrigin, !isLocked() else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - origin.mouse.x
        let dy = mouse.y - origin.mouse.y
        if !dragged, hypot(dx, dy) < 3 { return }
        if !dragged { NSCursor.closedHand.push() }
        dragged = true
        window.setFrameOrigin(NSPoint(x: origin.window.x + dx, y: origin.window.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragOrigin = nil }
        if dragged {
            NSCursor.pop()
            dragged = false
            onDragEnded?()
        } else if dragOrigin != nil {
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = menuProvider?() {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}

/// Positions, sizes, snaps and persists the floating widget and its detail popover.
@MainActor
final class WidgetController: NSObject {
    private let panel = WidgetPanel()
    private let container: WidgetContainerView
    private let popover = NSPopover()
    private let prefs: Prefs
    private let store: UsageStore
    private var cancellables: Set<AnyCancellable> = []

    private static let frameKey = "widget.frame"
    private let snapDistance: CGFloat = 28
    private let margin: CGFloat = 10

    var menu: (() -> NSMenu)? {
        didSet { container.menuProvider = menu }
    }

    init(store: UsageStore, prefs: Prefs) {
        self.store = store
        self.prefs = prefs
        container = WidgetContainerView(content: AnyView(WidgetView(store: store, prefs: prefs)))
        super.init()

        panel.contentView = container
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.button)
        container.setAccessibilityHelp("Open usage details. Drag to move; right-click for settings.")
        container.isLocked = { [weak prefs] in prefs?.locked ?? false }
        container.onClick = { [weak self] in self?.toggleDetail() }
        container.onDragEnded = { [weak self] in self?.snap() }
        container.hosting.onSizeChange = { [weak self] in self?.fitToContent() }

        let detail = NSHostingController(rootView: DetailView(
            store: store, prefs: prefs,
            onRefresh: { [weak store] in store?.refresh() },
            onSettings: { [weak self] in self?.showSettingsMenu() }
        ))
        detail.sizingOptions = .preferredContentSize
        popover.contentViewController = detail
        popover.behavior = .transient
        popover.animates = true

        applyPrefs()
        restoreFrame()

        prefs.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyPrefs()
                self?.fitToContent()
                self?.updateTooltip()
            }
            .store(in: &cancellables)

        store.objectWillChange
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.fitToContent()
                self?.updateTooltip()
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepOnScreen(animated: false) }
        }
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        prefs.widgetVisible = true
        fitToContent()
        keepOnScreen(animated: false)
        panel.orderFrontRegardless()
    }

    func hide() {
        prefs.widgetVisible = false
        popover.performClose(nil)
        panel.orderOut(nil)
    }

    func resetPosition() {
        panel.setFrame(defaultFrame(size: panel.frame.size), display: true)
        saveFrame()
    }

    // MARK: Appearance

    private func applyPrefs() {
        panel.level = prefs.placement.level
        panel.alphaValue = prefs.opacity
        panel.appearance = prefs.theme.appearance
        popover.appearance = prefs.theme.appearance
        panel.invalidateCursorRects(for: container)
    }

    private func updateTooltip() {
        container.toolTip = prefs.providers.map { provider -> String in
            let reading = store.reading(for: provider)
            guard let window = reading.window else {
                return "\(provider.displayName): \(reading.error?.shortLabel ?? "no data")"
            }
            return "\(provider.displayName): \(Int(window.remainingPercent.rounded()))% of \(window.label.lowercased()) left"
        }.joined(separator: "\n")
        container.setAccessibilityLabel("UsageBar. " + (container.toolTip ?? "Open usage details"))
    }

    // MARK: Geometry

    /// Resizes to the SwiftUI content, growing away from whichever screen edge the widget is near.
    private func fitToContent() {
        let size = container.hosting.fittingSize
        guard size.width > 1, size.height > 1 else { return }
        var frame = panel.frame
        guard abs(frame.width - size.width) > 0.5 || abs(frame.height - size.height) > 0.5 else { return }
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            if frame.midX > visible.midX { frame.origin.x = frame.maxX - size.width }
            if frame.midY > visible.midY { frame.origin.y = frame.maxY - size.height }
        }
        frame.size = size
        panel.setFrame(frame.integral, display: true)
        panel.invalidateShadow()
    }

    /// Snaps to screen edges, corners and the top/bottom centre, then saves the position.
    private func snap() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        var frame = panel.frame
        let visible = screen.visibleFrame
        if prefs.snapToEdges {
            let reach = snapDistance + margin
            if abs(frame.minX - visible.minX) < reach {
                frame.origin.x = visible.minX + margin
            } else if abs(visible.maxX - frame.maxX) < reach {
                frame.origin.x = visible.maxX - frame.width - margin
            } else if abs(frame.midX - visible.midX) < snapDistance {
                frame.origin.x = visible.midX - frame.width / 2
            }
            if abs(frame.minY - visible.minY) < reach {
                frame.origin.y = visible.minY + margin
            } else if abs(visible.maxY - frame.maxY) < reach {
                frame.origin.y = visible.maxY - frame.height - margin
            }
        }
        frame = clamp(frame, to: screen.frame)
        move(to: frame, animated: true)
        saveFrame()
    }

    private func keepOnScreen(animated: Bool) {
        let frame = panel.frame
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(frame.insetBy(dx: 8, dy: 8)) }
        if onScreen {
            if let screen = panel.screen { move(to: clamp(frame, to: screen.frame), animated: animated) }
        } else {
            move(to: defaultFrame(size: frame.size), animated: animated)
        }
    }

    private func clamp(_ frame: NSRect, to bounds: NSRect) -> NSRect {
        var frame = frame
        frame.origin.x = min(max(frame.minX, bounds.minX), bounds.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, bounds.minY), bounds.maxY - frame.height)
        return frame
    }

    private func move(to frame: NSRect, animated: Bool) {
        guard frame != panel.frame else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    /// Top-right, just under the menu bar, next to the real battery.
    private func defaultFrame(size: NSSize) -> NSRect {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        return NSRect(x: visible.maxX - size.width - margin, y: visible.maxY - size.height - margin,
                      width: size.width, height: size.height)
    }

    private func restoreFrame() {
        let size = container.hosting.fittingSize
        if let saved = UserDefaults.standard.string(forKey: Self.frameKey).map(NSRectFromString),
           saved.width > 0 {
            panel.setFrame(saved, display: false)
            fitToContent()
            keepOnScreen(animated: false)
        } else {
            panel.setFrame(defaultFrame(size: size), display: false)
        }
    }

    private func saveFrame() {
        // Save the target frame, not the mid-animation one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(NSStringFromRect(self.panel.frame), forKey: Self.frameKey)
        }
    }

    // MARK: Detail popover

    private func toggleDetail() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        showDetail()
    }

    func showDetail() {
        if !panel.isVisible { show() }
        guard !popover.isShown else { return }
        store.refresh()
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let edge: NSRectEdge = panel.frame.midY > visible.midY ? .minY : .maxY
        popover.show(relativeTo: container.bounds, of: container, preferredEdge: edge)
    }

    private func showSettingsMenu() {
        // Close before opening another transient surface. Anchor to the widget
        // so keyboard/accessibility activation does not depend on the pointer.
        let wasAnimated = popover.animates
        popover.animates = false
        popover.performClose(nil)
        popover.animates = wasAnimated
        DispatchQueue.main.async { [weak self] in
            guard let self, let menu = self.menu?() else { return }
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: self.container.bounds.maxY), in: self.container)
        }
    }
}
