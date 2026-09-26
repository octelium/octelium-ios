#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import OcteliumProto
import SwiftProtobuf

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public let dbFileName = "octelium.db"
public let encryptionKeyLen = 32
public let dbLockTimeout: Duration = .seconds(10)

private let encryptedStatePrefix = Data("octelium-db-v1:".utf8)
private let nonceLen = 12

public struct DBError: Error, Equatable, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}

public final class DB: Sendable {
    private let url: URL
    private let lockURL: URL
    private let key: Data
    private let now: @Sendable () -> Date
    private let lock = NSLock()

    public init(dir: URL, key: Data, now: @escaping @Sendable () -> Date = { Date() }) throws {
        if key.count != encryptionKeyLen {
            throw DBError("The encryption key must be \(encryptionKeyLen) bytes")
        }

        self.url = dir.appendingPathComponent(dbFileName)
        self.lockURL = dir.appendingPathComponent("\(dbFileName).lock")
        self.key = key
        self.now = now
    }

    public func migrate() throws {
        try withLock {
            if !FileManager.default.fileExists(atPath: url.path) {
                try writeLocked(Configv1.State())
            }
        }
    }

    public func get(_ domain: String) throws -> Configv1.State.Domain? {
        try withLock {
            try readLocked().domainMap[domain]
        }
    }

    public func list() throws -> [String: Configv1.State.Domain] {
        try withLock {
            try readLocked().domainMap
        }
    }

    public func getSessionToken(_ domain: String) throws -> Authv1.SessionToken? {
        guard let itm = try get(domain), itm.hasSessionToken else {
            return nil
        }

        return itm.sessionToken
    }

    public func setSessionToken(_ domain: String, _ arg: Authv1.SessionToken) throws {
        let at = now()

        try update(domain) { itm in
            itm.sessionToken = arg
            itm.sessionTokenSetAt = Google_Protobuf_Timestamp(date: at)
        }
    }

    public func setDomainSettings(_ domain: String, _ arg: Daemonv1.DomainSettings) throws {
        try update(domain) { itm in
            itm.settings = arg
        }
    }

    public func deleteSessionToken(_ domain: String) throws {
        try withLock {
            var state = try readLocked()
            guard var itm = state.domainMap[domain] else {
                return
            }

            itm.clearSessionToken()
            itm.clearSessionTokenSetAt()
            state.domainMap[domain] = itm

            try writeLocked(state)
        }
    }

    public func deleteStaleSessionToken(_ domain: String, refreshToken: String) throws {
        try withLock {
            var state = try readLocked()
            guard var itm = state.domainMap[domain], itm.sessionToken.refreshToken == refreshToken else {
                return
            }

            itm.clearSessionToken()
            itm.clearSessionTokenSetAt()
            state.domainMap[domain] = itm

            try writeLocked(state)
        }
    }

    public func delete(_ domain: String) throws {
        try withLock {
            var state = try readLocked()
            if state.domainMap.removeValue(forKey: domain) == nil {
                return
            }

            try writeLocked(state)
        }
    }

    private func update(_ domain: String, _ fn: (inout Configv1.State.Domain) -> Void) throws {
        try withLock {
            var state = try readLocked()
            var itm = state.domainMap[domain] ?? Configv1.State.Domain()
            fn(&itm)
            state.domainMap[domain] = itm

            try writeLocked(state)
        }
    }

    private func withLock<T>(_ fn: () throws -> T) throws -> T {
        try lock.withLock {
            let fd = try lockFile()
            defer {
                unlockFile(fd)
            }

            return try fn()
        }
    }

    private func lockFile() throws -> Int32 {
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        if fd < 0 {
            throw DBError("Could not open the file lock at \(lockURL.path): \(getPOSIXErrorMessage(errno))")
        }

        let deadline = ContinuousClock.now + dbLockTimeout

        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let err = errno
            if (err != EWOULDBLOCK && err != EINTR) || ContinuousClock.now >= deadline {
                close(fd)
                throw DBError("Could not acquire the file lock at \(lockURL.path)")
            }

            usleep(10_000)
        }

        return fd
    }

    private func unlockFile(_ fd: Int32) {
        flock(fd, LOCK_UN)
        close(fd)
    }

    private func readLocked() throws -> Configv1.State {
        if !FileManager.default.fileExists(atPath: url.path) {
            return Configv1.State()
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DBError("Could not read the state: \(getErrorMessage(error))")
        }

        let plaintext = try data.isEmpty ? data : decrypt(data)

        do {
            return try Configv1.State(serializedBytes: plaintext)
        } catch {
            throw DBError("Could not unmarshal the state: \(getErrorMessage(error))")
        }
    }

    private func writeLocked(_ state: Configv1.State) throws {
        let data: Data
        do {
            data = try encrypt(state.serializedBytes())
        } catch {
            throw DBError("Could not marshal the state: \(getErrorMessage(error))")
        }

        do {
            try writeFileAtomically(url, data)
        } catch {
            throw DBError("Could not write the state: \(getErrorMessage(error))")
        }
    }

    private func encrypt(_ plaintext: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), authenticating: encryptedStatePrefix)
        guard let combined = box.combined else {
            throw DBError("Could not encrypt the state")
        }

        return encryptedStatePrefix + combined
    }

    private func decrypt(_ ciphertext: Data) throws -> Data {
        if ciphertext.count < encryptedStatePrefix.count + nonceLen || !ciphertext.starts(with: encryptedStatePrefix) {
            throw DBError("The state is not encrypted")
        }

        do {
            let box = try AES.GCM.SealedBox(combined: ciphertext.dropFirst(encryptedStatePrefix.count))
            return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: encryptedStatePrefix)
        } catch {
            throw DBError("Could not decrypt the state")
        }
    }
}

private func writeFileAtomically(_ url: URL, _ data: Data) throws {
    let dir = url.deletingLastPathComponent()
    let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")

    let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    if fd < 0 {
        throw DBError(getPOSIXErrorMessage(errno))
    }

    var isRenamed = false
    defer {
        if !isRenamed {
            unlink(tmp.path)
        }
    }

    let err = data.withUnsafeBytes { buf -> Int32 in
        var offset = 0
        while offset < buf.count {
            let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
            if n < 0 {
                if errno == EINTR {
                    continue
                }
                return errno
            }

            offset += n
        }

        return fsync(fd) == 0 ? 0 : errno
    }

    close(fd)

    if err != 0 {
        throw DBError(getPOSIXErrorMessage(err))
    }

    if rename(tmp.path, url.path) != 0 {
        throw DBError(getPOSIXErrorMessage(errno))
    }
    isRenamed = true

    let dirFD = open(dir.path, O_RDONLY | O_CLOEXEC)
    if dirFD >= 0 {
        fsync(dirFD)
        close(dirFD)
    }
}

private func getPOSIXErrorMessage(_ code: Int32) -> String {
    String(cString: strerror(code))
}
