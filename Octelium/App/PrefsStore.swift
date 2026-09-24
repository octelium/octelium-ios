import Foundation
import OcteliumCore

struct PrefsStore {
    private let defaults: UserDefaults

    private let themeKey = "theme"
    private let primaryDomainKey = "primaryDomain"
    private let multiClusterKey = "multiCluster"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func get() -> Prefs {
        normalizePrefs(
            defaults.string(forKey: themeKey),
            defaults.string(forKey: primaryDomainKey),
            defaults.object(forKey: multiClusterKey) as? Bool
        )
    }

    func setTheme(_ arg: ThemeMode) {
        defaults.set(arg.rawValue, forKey: themeKey)
    }

    func setPrimaryDomain(_ arg: String?) {
        if let arg, !arg.isEmpty {
            defaults.set(arg, forKey: primaryDomainKey)
        } else {
            defaults.removeObject(forKey: primaryDomainKey)
        }
    }

    func setMultiCluster(_ arg: Bool) {
        defaults.set(arg, forKey: multiClusterKey)
    }
}
