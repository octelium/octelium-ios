import Foundation
import Synchronization
import XCTest

@testable import OcteliumCore

final class MemorySecretStore: SecretStore {
    private let state = Mutex<[String: Data]>([:])
    private let isLocked = Atomic<Bool>(false)

    func setLocked(_ arg: Bool) {
        isLocked.store(arg, ordering: .sequentiallyConsistent)
    }

    func get(_ account: String) throws -> Data? {
        if isLocked.load(ordering: .sequentiallyConsistent) {
            throw SecretStoreError.locked
        }

        return state.withLock { $0[account] }
    }

    func set(_ account: String, _ data: Data) throws {
        if isLocked.load(ordering: .sequentiallyConsistent) {
            throw SecretStoreError.locked
        }

        state.withLock { $0[account] = data }
    }

    func delete(_ account: String) throws {
        _ = state.withLock { $0.removeValue(forKey: account) }
    }
}

final class StateKeyTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func assertUnavailable(_ fn: () throws -> Void) -> StateKeyUnavailableError? {
        do {
            try fn()
            XCTFail()
        } catch let err as StateKeyUnavailableError {
            return err
        } catch {
            XCTFail("\(error)")
        }

        return nil
    }

    func testGetOrCreate() throws {
        let store = MemorySecretStore()
        let stateDir = tmp.appendingPathComponent("state")

        let s = StateKeyStore(store: store, stateDir: stateDir)

        let key = try s.getOrCreate()
        XCTAssertEqual(stateKeyLen, key.count)
        XCTAssertEqual(key, try store.get(stateKeyAccount))

        XCTAssertEqual(key, try s.getOrCreate())
        XCTAssertEqual(key, try s.get())
        XCTAssertEqual(key, try StateKeyStore(store: store, stateDir: stateDir).getOrCreate())
        XCTAssertNotEqual(key, try StateKeyStore(store: MemorySecretStore(), stateDir: stateDir).getOrCreate())
    }

    func testGet() throws {
        let store = MemorySecretStore()
        let s = StateKeyStore(store: store, stateDir: tmp.appendingPathComponent("state"))

        do {
            let err = assertUnavailable { _ = try s.get() }
            XCTAssertEqual("The state key does not exist. Open Octelium in order to set it up", err?.message)
            XCTAssertEqual(false, err?.isLocked)
            XCTAssertNil(try store.get(stateKeyAccount))
        }

        do {
            let key = try s.getOrCreate()
            store.setLocked(true)

            let err = assertUnavailable { _ = try s.get() }
            XCTAssertEqual(true, err?.isLocked)

            store.setLocked(false)
            XCTAssertEqual(key, try s.get())
        }
    }

    func testUnavailable() throws {
        let store = MemorySecretStore()
        let stateDir = tmp.appendingPathComponent("state")
        let s = StateKeyStore(store: store, stateDir: stateDir)

        do {
            _ = try s.getOrCreate()
            try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
            try Data("encrypted".utf8).write(to: stateDir.appendingPathComponent("octelium.db"))

            store.setLocked(true)
            let err = assertUnavailable { _ = try s.getOrCreate() }
            XCTAssertEqual(true, err?.isLocked)
            store.setLocked(false)
        }

        do {
            try store.delete(stateKeyAccount)
            let err = assertUnavailable { _ = try s.getOrCreate() }
            XCTAssertEqual("The state exists but its key is missing", err?.message)
        }

        do {
            try store.set(stateKeyAccount, Data(count: 16))
            let err = assertUnavailable { _ = try s.getOrCreate() }
            XCTAssertEqual("The state key must be 32 bytes", err?.message)
        }

        do {
            try s.reset()
            XCTAssertNil(try store.get(stateKeyAccount))
            XCTAssertFalse(FileManager.default.fileExists(atPath: stateDir.path))
            XCTAssertEqual(stateKeyLen, try s.getOrCreate().count)
        }

        do {
            let s = StateKeyStore(store: MemorySecretStore(), stateDir: tmp.appendingPathComponent("x")) { Data(count: 8) }
            let err = assertUnavailable { _ = try s.getOrCreate() }
            XCTAssertEqual("The state key must be 32 bytes", err?.message)
        }
    }

    func testGenerateStateKey() {
        let a = generateStateKey()
        let b = generateStateKey()
        XCTAssertEqual(stateKeyLen, a.count)
        XCTAssertNotEqual(a, b)
    }

    func testInstallationID() throws {
        let store = MemorySecretStore()

        XCTAssertNil(try InstallationID(store: store).get())

        let id = try InstallationID(store: store).getOrCreate()
        XCTAssertTrue(isValidInstallationID(id))
        XCTAssertEqual(id, id.lowercased())
        XCTAssertEqual(id, try InstallationID(store: store).getOrCreate())
        XCTAssertEqual(id, try InstallationID(store: store).get())

        try store.set(installationIDAccount, Data("invalid".utf8))
        XCTAssertNil(try InstallationID(store: store).get())

        let id2 = try InstallationID(store: store).getOrCreate()
        XCTAssertNotEqual(id, id2)
        XCTAssertTrue(isValidInstallationID(id2))
        XCTAssertEqual(Data(id2.utf8), try store.get(installationIDAccount))
    }

    func testIsValidInstallationID() {
        XCTAssertTrue(isValidInstallationID("0f8fad5b-d9cb-469f-a165-70867728950e"))
        XCTAssertTrue(isValidInstallationID("0F8FAD5B-D9CB-469F-A165-70867728950E"))
        XCTAssertFalse(isValidInstallationID(""))
        XCTAssertFalse(isValidInstallationID("invalid"))
        XCTAssertFalse(isValidInstallationID("0f8fad5b-d9cb-469f-a165"))
        XCTAssertFalse(isValidInstallationID("0f8fad5bd9cb469fa16570867728950e"))
    }

    func testGetDeviceName() {
        XCTAssertEqual("Alice's iPhone", getDeviceName(name: "Alice's iPhone", model: "iPhone", machine: "iPhone17,1"))
        XCTAssertEqual("Alice's iPhone", getDeviceName(name: " Alice's iPhone ", model: "iPhone", machine: ""))
        XCTAssertEqual("iPhone (iPhone17,1)", getDeviceName(name: "iPhone", model: "iPhone", machine: "iPhone17,1"))
        XCTAssertEqual("iPad (iPad16,3)", getDeviceName(name: "", model: "iPad", machine: "iPad16,3"))
        XCTAssertEqual("iPhone", getDeviceName(name: "iPhone", model: "iPhone", machine: ""))
        XCTAssertEqual("iPhone", getDeviceName(name: "iPhone", model: "iPhone", machine: "iPhone"))
        XCTAssertEqual("iPhone", getDeviceName(name: "iPhone", model: "", machine: "  "))
        XCTAssertEqual("iOS device (iPhone17,1)", getDeviceName(name: "", model: "", machine: "iPhone17,1"))
        XCTAssertEqual("iOS device", getDeviceName(name: "", model: "", machine: ""))
    }

    func testSecretStoreError() {
        XCTAssertEqual(
            "The secure storage is not available until this device is unlocked",
            getErrorMessage(SecretStoreError.locked)
        )
        XCTAssertEqual("failed", getErrorMessage(SecretStoreError.failure("failed")))
    }
}
