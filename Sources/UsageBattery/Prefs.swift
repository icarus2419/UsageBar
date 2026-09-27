import AppKit
import UsageCore

enum Metric: String, CaseIterable {
    case lowest, session, weekly

    var title: String {
        switch self {
        case .lowest: return "Whichever Is Lower"
        case .session: return "5-Hour Session"
        case .weekly: return "Weekly"
        }
    }
}

enum Placement: String, CaseIterable {
    case floating, desktop

    var title: String {
        switch self {
        case .floating: return "Float Above All Windows"
        case .desktop: return "Stick to Desktop"
        }
    }

    var level: NSWindow.Level {
        switch self {
        case .floating: return .floating
        case .desktop: return NSWindow.Level(Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        }
    }
}

enum WidgetSize: String, CaseIterable {
    case small, medium, large

    var title: String { rawValue.capitalized }

    var scale: CGFloat {
        switch self {
        case .small: return 0.85
        case .medium: return 1
        case .large: return 1.35
        }
    }
}

enum Layout: String, CaseIterable {
    case horizontal, vertical
    var title: String { rawValue.capitalized }
}

enum Theme: String, CaseIterable {
    case system, light, dark

    var title: String { rawValue.capitalized }

    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// User settings, persisted to UserDefaults as they change.
final class Prefs: ObservableObject {
    private let defaults: UserDefaults

    @Published var showClaude: Bool { didSet { save(showClaude, "showClaude") } }
    @Published var showOpenAI: Bool { didSet { save(showOpenAI, "showOpenAI") } }
    @Published var metric: Metric { didSet { save(metric.rawValue, "metric") } }
    @Published var placement: Placement { didSet { save(placement.rawValue, "placement") } }
    @Published var size: WidgetSize { didSet { save(size.rawValue, "size") } }
    @Published var layout: Layout { didSet { save(layout.rawValue, "layout") } }
    @Published var theme: Theme { didSet { save(theme.rawValue, "theme") } }
    @Published var opacity: Double { didSet { save(opacity, "opacity") } }
    @Published var colorful: Bool { didSet { save(colorful, "colorful") } }
    @Published var showNames: Bool { didSet { save(showNames, "showNames") } }
    @Published var locked: Bool { didSet { save(locked, "locked") } }
    @Published var snapToEdges: Bool { didSet { save(snapToEdges, "snapToEdges") } }
    @Published var widgetVisible: Bool { didSet { save(widgetVisible, "widgetVisible") } }
    @Published var showMenuBar: Bool { didSet { save(showMenuBar, "showMenuBar") } }
    @Published var alerts: Bool { didSet { save(alerts, "alerts") } }
    @Published var refreshMinutes: Int { didSet { save(refreshMinutes, "refreshMinutes") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func value<T>(_ key: String, _ fallback: T) -> T { defaults.object(forKey: key) as? T ?? fallback }
        func choice<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
            defaults.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
        }
        showClaude = value("showClaude", true)
        showOpenAI = value("showOpenAI", true)
        metric = choice("metric", .lowest)
        placement = choice("placement", .floating)
        size = choice("size", .medium)
        layout = choice("layout", .horizontal)
        theme = choice("theme", .system)
        opacity = value("opacity", 1.0)
        colorful = value("colorful", true)
        showNames = value("showNames", false)
        locked = value("locked", false)
        snapToEdges = value("snapToEdges", true)
        widgetVisible = value("widgetVisible", true)
        showMenuBar = value("showMenuBar", true)
        alerts = value("alerts", true)
        refreshMinutes = value("refreshMinutes", 2)
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    var providers: [Provider] {
        Provider.allCases.filter(isShown)
    }

    func isShown(_ provider: Provider) -> Bool {
        provider == .claude ? showClaude : showOpenAI
    }

    func setShown(_ provider: Provider, _ shown: Bool) {
        if provider == .claude { showClaude = shown } else { showOpenAI = shown }
    }
}
