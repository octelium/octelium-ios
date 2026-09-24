import XCTest

@testable import OcteliumCore

final class PrefsTests: XCTestCase {

    func testNormalizePrefs() {
        do {
            XCTAssertEqual(defaultPrefs, normalizePrefs(nil, nil, nil))
        }
        do {
            let ret = normalizePrefs("dark", "example.com", true)
            XCTAssertEqual(.dark, ret.theme)
            XCTAssertEqual("example.com", ret.primaryDomain)
            XCTAssertTrue(ret.multiCluster)
        }
        do {
            let ret = normalizePrefs("neon", "", nil)
            XCTAssertEqual(.system, ret.theme)
            XCTAssertNil(ret.primaryDomain)
            XCTAssertFalse(ret.multiCluster)
        }
        do {
            XCTAssertEqual("example.com", normalizePrefs("light", " Example.COM ", false).primaryDomain)
            XCTAssertNil(normalizePrefs("light", "   ", false).primaryDomain)
        }
    }

    func testResolveTheme() {
        XCTAssertFalse(resolveTheme(.light, prefersDark: true))
        XCTAssertTrue(resolveTheme(.dark, prefersDark: false))
        XCTAssertTrue(resolveTheme(.system, prefersDark: true))
        XCTAssertFalse(resolveTheme(.system, prefersDark: false))
    }

    func testGetNextThemeMode() {
        XCTAssertEqual(.light, getNextThemeMode(.system))
        XCTAssertEqual(.dark, getNextThemeMode(.light))
        XCTAssertEqual(.system, getNextThemeMode(.dark))
        XCTAssertEqual("System", getThemeModeLabel(.system))
        XCTAssertEqual("Light", getThemeModeLabel(.light))
        XCTAssertEqual("Dark", getThemeModeLabel(.dark))
        XCTAssertEqual(["system", "light", "dark"], ThemeMode.allCases.map(\.rawValue))
    }
}
