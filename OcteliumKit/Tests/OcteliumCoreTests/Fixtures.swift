import Foundation
import OcteliumProto
import SwiftProtobuf

func getTestDomain(
    _ domain: String = "example.com",
    auth: Daemonv1.AuthenticationStatus.State = .loggedOut,
    conn: Daemonv1.ConnectionStatus.State = .disconnected,
    op: Daemonv1.Operation? = nil,
    autoConnect: Bool = false
) -> Daemonv1.DomainState {
    var ret = Daemonv1.DomainState()
    ret.domain = domain
    ret.authentication.state = auth
    ret.connection.state = conn
    ret.settings.domain = domain
    ret.settings.autoConnect = autoConnect

    if let op {
        ret.lastOperation = op
    }

    return ret
}

func getTestOperation(
    type: Daemonv1.Operation.TypeEnum = .connect,
    state: Daemonv1.Operation.State = .running,
    id: String = "op",
    url: String? = nil,
    updatedAt: Int64 = 0
) -> Daemonv1.Operation {
    var ret = Daemonv1.Operation()
    ret.id = id
    ret.type = type
    ret.state = state

    if updatedAt > 0 {
        ret.updatedAt = Google_Protobuf_Timestamp(seconds: updatedAt, nanos: 0)
    }

    if let url {
        ret.action.openURL.url = url
    }

    return ret
}

func getTestError(_ code: Daemonv1.Error.Code, message: String = "", retryable: Bool = false) -> Daemonv1.Error {
    var ret = Daemonv1.Error()
    ret.code = code
    ret.message = message
    ret.retryable = retryable
    return ret
}

func getTestStatus(
    _ domains: Daemonv1.DomainState...,
    revision: UInt64 = 1,
    instanceID: String = "instance"
) -> Daemonv1.GetStatusResponse {
    var ret = Daemonv1.GetStatusResponse()
    ret.instanceID = instanceID
    ret.revision = revision
    ret.domains = domains
    return ret
}

func getTimestamp(_ arg: Date) -> Google_Protobuf_Timestamp {
    Google_Protobuf_Timestamp(date: arg)
}

func getDate(_ arg: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = arg.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
    return formatter.date(from: arg)!
}
