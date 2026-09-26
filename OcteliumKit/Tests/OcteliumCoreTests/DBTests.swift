import Foundation
import OcteliumProto
import XCTest

@testable import OcteliumCore

final class DBTests: XCTestCase {

    private let key = Data((0..<encryptionKeyLen).map { UInt8($0) })

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func getSessionToken(_ accessToken: String, _ refreshToken: String) -> Authv1.SessionToken {
        var ret = Authv1.SessionToken()
        ret.accessToken = accessToken
        ret.refreshToken = refreshToken
        ret.expiresIn = 3600
        ret.refreshTokenExpiresIn = 86400
        return ret
    }

    private func getSettings(autoConnect: Bool) -> Daemonv1.DomainSettings {
        var ret = Daemonv1.DomainSettings()
        ret.autoConnect = autoConnect
        return ret
    }

    private func assertDBError(_ msg: String, _ fn: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        do {
            try fn()
            XCTFail(file: file, line: line)
        } catch let err as DBError {
            XCTAssertEqual(msg, err.message, file: file, line: line)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }

    func testDB() throws {
        let now = Date(timeIntervalSince1970: 1790157723)
        let db = try DB(dir: tmp, key: key, now: { now })

        try db.migrate()
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.appendingPathComponent(dbFileName).path))
        XCTAssertTrue(try db.list().isEmpty)
        XCTAssertNil(try db.get("example.com"))
        XCTAssertNil(try db.getSessionToken("example.com"))

        try db.setSessionToken("example.com", getSessionToken("access-1", "refresh-1"))
        try db.setDomainSettings("example.com", getSettings(autoConnect: true))
        try db.setDomainSettings("other.example.com", Daemonv1.DomainSettings())

        do {
            let itm = try XCTUnwrap(try db.get("example.com"))
            XCTAssertEqual("access-1", itm.sessionToken.accessToken)
            XCTAssertEqual(1790157723, itm.sessionTokenSetAt.seconds)
            XCTAssertTrue(itm.settings.autoConnect)
            XCTAssertEqual(["example.com", "other.example.com"], Set(try db.list().keys))
        }

        do {
            let other = try DB(dir: tmp, key: key)
            XCTAssertEqual("refresh-1", try other.getSessionToken("example.com")?.refreshToken)
            XCTAssertEqual(true, try other.get("example.com")?.settings.autoConnect)
        }

        do {
            try db.deleteStaleSessionToken("example.com", refreshToken: "refresh-0")
            XCTAssertEqual("access-1", try db.getSessionToken("example.com")?.accessToken)

            try db.deleteStaleSessionToken("example.com", refreshToken: "refresh-1")
            XCTAssertNil(try db.getSessionToken("example.com"))
            XCTAssertEqual(false, try db.get("example.com")?.hasSessionTokenSetAt)
            XCTAssertEqual(true, try db.get("example.com")?.settings.autoConnect)
        }

        do {
            try db.setSessionToken("example.com", getSessionToken("access-2", "refresh-2"))
            try db.deleteSessionToken("example.com")
            try db.deleteSessionToken("unknown.example.com")
            XCTAssertNil(try db.getSessionToken("example.com"))
            XCTAssertNil(try db.get("unknown.example.com"))
        }

        do {
            try db.delete("example.com")
            try db.delete("unknown.example.com")
            XCTAssertNil(try db.get("example.com"))
            XCTAssertEqual(["other.example.com"], Set(try DB(dir: tmp, key: key).list().keys))
        }
    }

    func testEncryption() throws {
        let url = tmp.appendingPathComponent(dbFileName)

        try DB(dir: tmp, key: key).setSessionToken("example.com", getSessionToken("access-token", "refresh-token"))

        let data = try Data(contentsOf: url)
        XCTAssertEqual(Data("octelium-db-v1:".utf8), data.prefix(15))
        XCTAssertNil(data.range(of: Data("refresh-token".utf8)))

        assertDBError("Could not decrypt the state") {
            _ = try DB(dir: tmp, key: Data(repeating: 7, count: encryptionKeyLen)).list()
        }

        try Data("plaintext".utf8).write(to: url)
        assertDBError("The state is not encrypted") {
            _ = try DB(dir: tmp, key: key).list()
        }

        assertDBError("The encryption key must be 32 bytes") {
            _ = try DB(dir: tmp, key: Data(count: 16))
        }
    }

    func testGoCompatibility() throws {
        let src = try XCTUnwrap(Bundle.module.url(forResource: "octelium", withExtension: "db", subdirectory: "Resources"))
        try FileManager.default.copyItem(at: src, to: tmp.appendingPathComponent(dbFileName))

        let db = try DB(dir: tmp, key: key)

        XCTAssertEqual(["example.com", "other.example.com"], Set(try db.list().keys))

        let itm = try XCTUnwrap(try db.get("example.com"))
        XCTAssertEqual("access-token", itm.sessionToken.accessToken)
        XCTAssertEqual("refresh-token", itm.sessionToken.refreshToken)
        XCTAssertEqual(3600, itm.sessionToken.expiresIn)
        XCTAssertEqual(86400, itm.sessionToken.refreshTokenExpiresIn)
        XCTAssertEqual(1790370294, itm.sessionTokenSetAt.seconds)
        XCTAssertTrue(itm.settings.autoConnect)
        XCTAssertEqual(.quicv0, itm.settings.connectionOptions.tunnelMode)

        try db.setSessionToken("example.com", getSessionToken("access-2", "refresh-2"))
        XCTAssertEqual("access-2", try DB(dir: tmp, key: key).getSessionToken("example.com")?.accessToken)
        XCTAssertEqual(true, try DB(dir: tmp, key: key).get("example.com")?.settings.autoConnect)
    }

    func testConcurrentWriters() async throws {
        let a = try DB(dir: tmp, key: key)
        let b = try DB(dir: tmp, key: key)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                let db = i % 2 == 0 ? a : b
                group.addTask {
                    try? db.setDomainSettings("domain-\(i).example.com", Daemonv1.DomainSettings())
                }
            }
        }

        XCTAssertEqual(20, try a.list().count)
    }
}
