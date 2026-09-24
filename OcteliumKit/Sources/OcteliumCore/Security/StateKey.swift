import Foundation

public let stateKeyLen = 32
public let stateKeyAccount = "state-key"
public let installationIDAccount = "installation-id"

public enum SecretStoreError: Error, Equatable, LocalizedError {
    case locked
    case failure(String)

    public var errorDescription: String? {
        switch self {
        case .locked:
            "The secure storage is not available until this device is unlocked"
        case .failure(let message):
            message
        }
    }
}

public protocol SecretStore: Sendable {
    func get(_ account: String) throws -> Data?

    func set(_ account: String, _ data: Data) throws

    func delete(_ account: String) throws
}

public struct StateKeyUnavailableError: Error, Equatable, LocalizedError {
    public let message: String
    public let isLocked: Bool

    public init(_ message: String, isLocked: Bool = false) {
        self.message = message
        self.isLocked = isLocked
    }

    public var errorDescription: String? {
        message
    }
}

public func generateStateKey() -> Data {
    var rng = SystemRandomNumberGenerator()
    return Data((0..<stateKeyLen).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &rng) })
}

public struct StateKeyStore: Sendable {
    private let store: any SecretStore
    private let stateDir: URL
    private let generate: @Sendable () -> Data

    public init(store: any SecretStore, stateDir: URL, generate: @escaping @Sendable () -> Data = generateStateKey) {
        self.store = store
        self.stateDir = stateDir
        self.generate = generate
    }

    public func get() throws -> Data {
        guard let ret = try read() else {
            throw StateKeyUnavailableError("The state key does not exist. Open Octelium in order to set it up")
        }

        return ret
    }

    public func getOrCreate() throws -> Data {
        if let ret = try read() {
            return ret
        }

        if hasState() {
            throw StateKeyUnavailableError("The state exists but its key is missing")
        }

        let ret = generate()
        if ret.count != stateKeyLen {
            throw StateKeyUnavailableError("The state key must be \(stateKeyLen) bytes")
        }

        do {
            try store.set(stateKeyAccount, ret)
        } catch {
            throw StateKeyUnavailableError("Could not store the state key: \(getErrorMessage(error))")
        }

        return ret
    }

    public func reset() throws {
        try store.delete(stateKeyAccount)

        if FileManager.default.fileExists(atPath: stateDir.path) {
            try FileManager.default.removeItem(at: stateDir)
        }
    }

    private func read() throws -> Data? {
        let ret: Data?

        do {
            ret = try store.get(stateKeyAccount)
        } catch SecretStoreError.locked {
            throw StateKeyUnavailableError(
                "The state key is not available until this device is unlocked for the first time after a restart",
                isLocked: true
            )
        } catch {
            throw StateKeyUnavailableError("Could not read the state key: \(getErrorMessage(error))")
        }

        guard let ret else {
            return nil
        }

        if ret.count != stateKeyLen {
            throw StateKeyUnavailableError("The state key must be \(stateKeyLen) bytes")
        }

        return ret
    }

    private func hasState() -> Bool {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: stateDir.path)) ?? []
        return !items.isEmpty
    }
}

public struct InstallationID: Sendable {
    private let store: any SecretStore

    public init(store: any SecretStore) {
        self.store = store
    }

    public func get() throws -> String? {
        guard let data = try store.get(installationIDAccount),
              let ret = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              isValidInstallationID(ret) else {
            return nil
        }

        return ret
    }

    public func getOrCreate() throws -> String {
        if let ret = try get() {
            return ret
        }

        let ret = UUID().uuidString.lowercased()
        try store.set(installationIDAccount, Data(ret.utf8))

        return ret
    }
}

public func isValidInstallationID(_ arg: String) -> Bool {
    guard let ret = UUID(uuidString: arg) else {
        return false
    }

    return ret.uuidString.lowercased() == arg.lowercased()
}
