import Foundation
import OcteliumProto
import XCTest

@testable import OcteliumCore

final class ConnectionStateTests: XCTestCase {

    private func getGateway(_ id: String, port: Int32 = 51820) -> Userv1.Gateway {
        var ret = Userv1.Gateway()
        ret.id = id
        ret.wireguard.port = port
        return ret
    }

    private func getState() -> Userv1.ConnectionState {
        var ret = Userv1.ConnectionState()
        ret.mtu = 1280
        ret.gateways = [getGateway("gw-1"), getGateway("gw-2")]
        ret.dns.servers = ["fdee:1::53"]
        return ret
    }

    private func getResponse(_ event: Userv1.ConnectResponse.OneOf_Event?) -> Userv1.ConnectResponse {
        var ret = Userv1.ConnectResponse()
        ret.event = event
        return ret
    }

    private func getIDs(_ arg: Userv1.ConnectionState?) -> [String]? {
        arg?.gateways.map(\.id)
    }

    func testReduceConnectionState() {
        let state = getState()

        do {
            var next = Userv1.ConnectionState()
            next.mtu = 1400
            XCTAssertEqual(next, reduceConnectionState(state, getResponse(.state(next))))
        }

        do {
            var arg = Userv1.ConnectResponse.AddGateway()
            arg.gateway = getGateway("gw-3")
            XCTAssertEqual(["gw-1", "gw-2", "gw-3"], getIDs(reduceConnectionState(state, getResponse(.addGateway(arg)))))
        }

        do {
            var arg = Userv1.ConnectResponse.AddGateway()
            arg.gateway = getGateway("gw-1", port: 1000)
            let ret = reduceConnectionState(state, getResponse(.addGateway(arg)))
            XCTAssertEqual(["gw-1", "gw-2"], getIDs(ret))
            XCTAssertEqual(1000, ret?.gateways[0].wireguard.port)
        }

        do {
            var arg = Userv1.ConnectResponse.UpdateGateway()
            arg.gateway = getGateway("gw-2", port: 2000)
            let ret = reduceConnectionState(state, getResponse(.updateGateway(arg)))
            XCTAssertEqual(["gw-1", "gw-2"], getIDs(ret))
            XCTAssertEqual(2000, ret?.gateways[1].wireguard.port)

            arg.gateway = getGateway("gw-3")
            XCTAssertNil(reduceConnectionState(state, getResponse(.updateGateway(arg))))
        }

        do {
            var arg = Userv1.ConnectResponse.DeleteGateway()
            arg.id = "gw-1"
            XCTAssertEqual(["gw-2"], getIDs(reduceConnectionState(state, getResponse(.deleteGateway(arg)))))

            arg.id = "gw-3"
            XCTAssertNil(reduceConnectionState(state, getResponse(.deleteGateway(arg))))
        }

        do {
            var arg = Userv1.ConnectResponse.UpdateDNS()
            arg.dns.servers = ["fdee:1::54"]
            XCTAssertEqual(["fdee:1::54"], reduceConnectionState(state, getResponse(.updateDns(arg)))?.dns.servers)

            XCTAssertNil(reduceConnectionState(state, getResponse(.updateDns(Userv1.ConnectResponse.UpdateDNS()))))
        }

        do {
            XCTAssertNil(reduceConnectionState(state, getResponse(nil)))

            var arg = Userv1.ConnectResponse.Message()
            arg.message = "hello"
            XCTAssertNil(reduceConnectionState(state, getResponse(.message(arg))))
        }
    }

    func testGetInitializeRequest() {
        do {
            let ret = getInitializeRequest(ConnectOptions()).initialize
            XCTAssertEqual(.v6, ret.l3Mode)
            XCTAssertEqual(.unset, ret.connectionType)
            XCTAssertFalse(ret.ignoreDns)
            XCTAssertTrue(!ret.hasServiceOptions && ret.publishedServices.isEmpty)
        }

        do {
            let ret = getInitializeRequest(ConnectOptions(l3Mode: .v4, tunnelMode: .quicv0, dnsMode: .disabled)).initialize
            XCTAssertEqual(.v4, ret.l3Mode)
            XCTAssertEqual(.quicv0, ret.connectionType)
            XCTAssertTrue(ret.ignoreDns)
        }
    }
}
