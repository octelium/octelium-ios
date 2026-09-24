import OcteliumProto
import XCTest

@testable import OcteliumCore

final class SettingsTests: XCTestCase {

    func testGetDomainSettingsForm() {
        do {
            XCTAssertEqual(DomainSettingsForm(), getDomainSettingsForm(nil))
        }
        do {
            XCTAssertEqual(DomainSettingsForm(), getDomainSettingsForm(Daemonv1.DomainSettings()))
        }
        do {
            var settings = Daemonv1.DomainSettings()
            settings.domain = "example.com"
            settings.autoConnect = true
            settings.connectionOptions.tunnelMode = .quicv0
            settings.connectionOptions.l3Mode = .both
            settings.connectionOptions.dns.mode = .full
            settings.connectionOptions.mtu = 1400

            XCTAssertEqual(
                DomainSettingsForm(autoConnect: true, tunnelMode: .quicv0, dnsMode: .full, l3Mode: .both, mtu: "1400"),
                getDomainSettingsForm(settings)
            )
        }
        do {
            var settings = Daemonv1.DomainSettings()
            settings.connectionOptions.dns.mode = .unspecified
            XCTAssertEqual(.default, getDomainSettingsForm(settings).dnsMode)
        }
        do {
            var settings = Daemonv1.DomainSettings()
            settings.connectionOptions.tunnelMode = .UNRECOGNIZED(9)
            settings.connectionOptions.l3Mode = .UNRECOGNIZED(9)
            XCTAssertEqual(.unspecified, getDomainSettingsForm(settings).tunnelMode)
            XCTAssertEqual(.unspecified, getDomainSettingsForm(settings).l3Mode)
        }
    }

    func testValidateDomainSettingsForm() {
        XCTAssertNil(validateDomainSettingsForm(DomainSettingsForm()))
        XCTAssertNil(validateDomainSettingsForm(DomainSettingsForm(mtu: " ")))
        XCTAssertNil(validateDomainSettingsForm(DomainSettingsForm(l3Mode: .v4, mtu: "576")))
        XCTAssertNil(validateDomainSettingsForm(DomainSettingsForm(mtu: "1280")))
        XCTAssertNil(validateDomainSettingsForm(DomainSettingsForm(mtu: "1500")))
        XCTAssertEqual("The MTU must be between 576 and 1500", validateDomainSettingsForm(DomainSettingsForm(mtu: "575")))
        XCTAssertEqual("The MTU must be between 576 and 1500", validateDomainSettingsForm(DomainSettingsForm(mtu: "1501")))
        XCTAssertEqual("The MTU must be between 576 and 1500", validateDomainSettingsForm(DomainSettingsForm(mtu: "abc")))

        for itm: Daemonv1.ConnectionOptions.L3Mode in [.unspecified, .both, .v6] {
            XCTAssertEqual(
                "The MTU must be at least 1280 unless the IPv4 only mode is used",
                validateDomainSettingsForm(DomainSettingsForm(l3Mode: itm, mtu: "1279"))
            )
        }
    }

    func testGetDNSModeOptionLabel() {
        XCTAssertEqual("Split DNS", getDNSModeOptionLabel(.default))
        XCTAssertEqual("Split DNS", getDNSModeOptionLabel(.unspecified))
        XCTAssertEqual("Full DNS", getDNSModeOptionLabel(.full))
        XCTAssertEqual("Disabled", getDNSModeOptionLabel(.disabled))
        XCTAssertEqual(3, Set(dnsModes.map { getDNSModeOptionLabel($0) }).count)
        XCTAssertEqual(3, tunnelModes.count)
        XCTAssertEqual(4, l3Modes.count)
    }

    func testToDomainSettings() {
        do {
            let ret = toDomainSettings("example.com", DomainSettingsForm())
            XCTAssertEqual("example.com", ret.domain)
            XCTAssertFalse(ret.autoConnect)
            XCTAssertEqual(.default, ret.connectionOptions.dns.mode)
            XCTAssertEqual(0, ret.connectionOptions.mtu)
            XCTAssertFalse(ret.connectionOptions.hasServiceOptions)
            XCTAssertEqual(.unspecified, ret.connectionOptions.implementationMode)
        }
        do {
            let form = DomainSettingsForm(
                autoConnect: true,
                tunnelMode: .wireguard,
                dnsMode: .disabled,
                l3Mode: .v4,
                mtu: " 1280 "
            )
            let ret = toDomainSettings("example.com", form)
            XCTAssertEqual(1280, ret.connectionOptions.mtu)

            var expected = form
            expected.mtu = "1280"
            XCTAssertEqual(expected, getDomainSettingsForm(ret))
        }
    }
}
