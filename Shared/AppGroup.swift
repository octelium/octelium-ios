import Foundation
import OcteliumCore

enum AppGroup {
    static let identifier: String = getInfoString("OcteliumAppGroup") ?? "group.com.octelium.client"

    static let keychainService = "com.octelium.client"

    static let deviceNameKey = "deviceName"

    static let tunnelStatusNotification = getTunnelStatusNotification(identifier)

    static var defaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }

    static func getStateDir() throws -> URL {
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            throw StatusError(.failedPrecondition, "The App Group \(identifier) is not available")
        }

        var ret = base.appendingPathComponent("octelium", isDirectory: true)

        try FileManager.default.createDirectory(
            at: ret,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )

        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? ret.setResourceValues(values)

        return ret
    }

    static func getSecretStore() -> KeychainStore {
        KeychainStore(service: keychainService, accessGroup: identifier)
    }
}

func getInfoString(_ key: String) -> String? {
    guard let ret = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
        return nil
    }

    let trimmed = ret.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
