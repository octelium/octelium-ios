import Foundation

public enum ThemeMode: String, CaseIterable, Sendable {
    case system
    case light
    case dark
}

public struct Prefs: Equatable, Sendable {
    public var theme: ThemeMode
    public var primaryDomain: String?
    public var multiCluster: Bool

    public init(theme: ThemeMode = .system, primaryDomain: String? = nil, multiCluster: Bool = false) {
        self.theme = theme
        self.primaryDomain = primaryDomain
        self.multiCluster = multiCluster
    }
}

public let defaultPrefs = Prefs()

public func normalizePrefs(_ theme: String?, _ primaryDomain: String?, _ multiCluster: Bool?) -> Prefs {
    let domain = primaryDomain?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    return Prefs(
        theme: theme.flatMap { ThemeMode(rawValue: $0) } ?? defaultPrefs.theme,
        primaryDomain: domain?.isEmpty == false ? domain : nil,
        multiCluster: multiCluster ?? defaultPrefs.multiCluster
    )
}

public func resolveTheme(_ arg: ThemeMode, prefersDark: Bool) -> Bool {
    switch arg {
    case .light: false
    case .dark: true
    case .system: prefersDark
    }
}

public func getNextThemeMode(_ arg: ThemeMode) -> ThemeMode {
    switch arg {
    case .system: .light
    case .light: .dark
    case .dark: .system
    }
}

public func getThemeModeLabel(_ arg: ThemeMode) -> String {
    switch arg {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
}
