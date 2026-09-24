import Foundation
import OcteliumProto
import SwiftProtobuf

public let apiMajorVersion: UInt32 = 1

public struct LocalClient: Sendable {
    private let transport: any LocalTransport

    public init(_ transport: any LocalTransport) {
        self.transport = transport
    }

    public func getInfo() async throws -> Mobilev1.GetInfoResponse {
        try await call("GetInfo", Mobilev1.GetInfoRequest())
    }

    public func getStatus() async throws -> Daemonv1.GetStatusResponse {
        try await call("GetStatus", Daemonv1.GetStatusRequest())
    }

    public func authenticateBrowser(_ domain: String) async throws -> Daemonv1.Operation {
        var req = Daemonv1.AuthenticateRequest()
        req.domain = domain
        req.browser = Daemonv1.AuthenticateRequest.Browser()

        return try await call("Authenticate", req)
    }

    public func authenticateToken(_ domain: String, _ authenticationToken: String) async throws -> Daemonv1.Operation {
        var req = Daemonv1.AuthenticateRequest()
        req.domain = domain
        req.authenticationToken.authenticationToken = authenticationToken

        return try await call("Authenticate", req)
    }

    public func completeAuthentication(_ operationID: String, _ callbackURL: String) async throws -> Daemonv1.Operation {
        var req = Mobilev1.CompleteAuthenticationRequest()
        req.operationID = operationID
        req.callbackURL = callbackURL

        return try await call("CompleteAuthentication", req)
    }

    public func connect(_ domain: String) async throws -> Daemonv1.Operation {
        var req = Daemonv1.ConnectRequest()
        req.domain = domain

        return try await call("Connect", req)
    }

    public func disconnect(_ domain: String) async throws -> Daemonv1.Operation {
        var req = Daemonv1.DisconnectRequest()
        req.domain = domain

        return try await call("Disconnect", req)
    }

    public func logout(_ domain: String) async throws -> Daemonv1.Operation {
        var req = Daemonv1.LogoutRequest()
        req.domain = domain

        return try await call("Logout", req)
    }

    public func deleteDomain(_ domain: String) async throws -> Daemonv1.Operation {
        var req = Daemonv1.DeleteDomainRequest()
        req.domain = domain

        return try await call("DeleteDomain", req)
    }

    public func getOperation(_ id: String) async throws -> Daemonv1.Operation {
        var req = Daemonv1.GetOperationRequest()
        req.id = id

        return try await call("GetOperation", req)
    }

    public func cancelOperation(_ id: String) async throws -> Daemonv1.Operation {
        var req = Daemonv1.CancelOperationRequest()
        req.id = id

        return try await call("CancelOperation", req)
    }

    public func getAPICredential(_ domain: String) async throws -> Daemonv1.GetAPICredentialResponse {
        var req = Daemonv1.GetAPICredentialRequest()
        req.domain = domain

        return try await call("GetAPICredential", req)
    }

    public func updateDomainSettings(
        _ domain: String,
        _ settings: Daemonv1.DomainSettings
    ) async throws -> Daemonv1.DomainSettings {
        var req = Daemonv1.UpdateDomainSettingsRequest()
        req.domain = domain
        req.settings = settings

        return try await call("UpdateDomainSettings", req)
    }

    public func setNetworkState(_ state: NetworkState) async throws -> Mobilev1.SetNetworkStateResponse {
        var req = Mobilev1.SetNetworkStateRequest()
        req.isAvailable = state.isAvailable
        req.id = state.id

        return try await call("SetNetworkState", req)
    }

    private func call<Response: SwiftProtobuf.Message>(
        _ method: String,
        _ req: some SwiftProtobuf.Message
    ) async throws -> Response {
        let reqBytes: Data = try req.serializedBytes()
        let resp = try await transport.call(method, reqBytes)

        do {
            return try Response(serializedBytes: resp)
        } catch {
            throw StatusError(.internal, "Could not unmarshal the \(method) response: \(error)")
        }
    }
}

public func checkInfo(_ info: Mobilev1.GetInfoResponse) -> String? {
    if info.apiMajorVersion != apiMajorVersion {
        return "liboctelium implements the local API version \(info.apiMajorVersion) while this application requires the version \(apiMajorVersion)"
    }

    if info.authenticationCallbackURL.isEmpty {
        return "liboctelium does not provide an authentication callback URL"
    }

    return nil
}
