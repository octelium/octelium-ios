import NetworkExtension
import OcteliumCore
import SwiftUI
import UIKit
import XCTest

final class VPNControllerTests: XCTestCase {

    func testGetVPNState() {
        XCTAssertEqual(.invalid, getVPNState(.invalid))
        XCTAssertEqual(.disconnected, getVPNState(.disconnected))
        XCTAssertEqual(.connecting, getVPNState(.connecting))
        XCTAssertEqual(.connected, getVPNState(.connected))
        XCTAssertEqual(.reasserting, getVPNState(.reasserting))
        XCTAssertEqual(.disconnecting, getVPNState(.disconnecting))
        XCTAssertEqual(.disconnected, getVPNState(nil))
    }
}

final class PrefsStoreTests: XCTestCase {

    func testPrefsStore() throws {
        let suite = "octelium-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
        }

        let s = PrefsStore(defaults: defaults)
        XCTAssertEqual(defaultPrefs, s.get())

        s.setTheme(.dark)
        s.setPrimaryDomain("Example.com")
        s.setMultiCluster(true)
        XCTAssertEqual(Prefs(theme: .dark, primaryDomain: "example.com", multiCluster: true), s.get())

        s.setPrimaryDomain(nil)
        XCTAssertNil(s.get().primaryDomain)

        s.setPrimaryDomain("")
        XCTAssertNil(s.get().primaryDomain)
    }
}

final class ThemeTests: XCTestCase {

    func testColors() {
        XCTAssertFalse(OcteliumColors.light.isDark)
        XCTAssertTrue(OcteliumColors.dark.isDark)

        for palette: Palette in [.slate, .emerald, .sky, .amber, .rose, .blue, .violet, .indigo, .cyan, .teal, .green, .fuchsia, .purple, .orange] {
            XCTAssertNotEqual(palette.getColors(false).content, palette.getColors(true).content)
        }

        for tone: LabelTone in [.neutral, .slate, .emerald, .sky, .amber, .rose] {
            XCTAssertNotEqual(getLabelToneColors(tone, false).background, getLabelToneColors(tone, true).background)
        }

        XCTAssertEqual(getConnectivityToneColor(.connected, false), getConnectivityToneColor(.connected, true))
        XCTAssertNotEqual(getConnectivityToneColor(.idle, false), getConnectivityToneColor(.idle, true))
    }

    func testColorScheme() {
        XCTAssertNil(getColorScheme(.system))
        XCTAssertEqual(.light, getColorScheme(.light))
        XCTAssertEqual(.dark, getColorScheme(.dark))
        XCTAssertEqual(3, Set(ThemeMode.allCases.map { getThemeModeIcon($0) }).count)
    }
}

final class ServiceTypesTests: XCTestCase {

    func testGetServiceTypeStyle() {
        let icons = serviceTypes.map { getServiceTypeStyle($0.type).icon }
        XCTAssertEqual(serviceTypes.count - 1, Set(icons).count)
        XCTAssertEqual("server.rack", getServiceTypeStyle(.unset).icon)
        XCTAssertEqual("server.rack", getServiceTypeStyle(.UNRECOGNIZED(99)).icon)
        XCTAssertEqual(getServiceTypeStyle(.rdp).icon, getServiceTypeStyle(.rdpWeb).icon)

        for itm in serviceTypes {
            XCTAssertNotNil(UIImage(systemName: getServiceTypeStyle(itm.type).icon), itm.label)
        }
    }
}

final class PathMonitorTests: XCTestCase {

    func testGetNetworkTransport() {
        XCTAssertEqual(.wifi, getNetworkTransport(.wifi))
        XCTAssertEqual(.cellular, getNetworkTransport(.cellular))
        XCTAssertEqual(.ethernet, getNetworkTransport(.wiredEthernet))
        XCTAssertEqual(.other, getNetworkTransport(.loopback))
        XCTAssertEqual(.other, getNetworkTransport(.other))
    }

    func testPathMonitor() async {
        let monitor = PathMonitor()
        var updates = monitor.start().makeAsyncIterator()

        guard let info = await updates.next() else {
            return XCTFail()
        }
        XCTAssertEqual(getNetworkState(info).isAvailable, info.isSatisfied && (info.supportsIPv4 || info.supportsIPv6))

        monitor.cancel()
        while await updates.next() != nil {}
    }
}
