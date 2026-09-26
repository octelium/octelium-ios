import Foundation
import OcteliumProto

public protocol LocalClient: Sendable {
    func getStatus() async throws -> Daemonv1.GetStatusResponse

    func authenticateBrowser(_ domain: String) async throws -> Daemonv1.Operation

    func authenticateToken(_ domain: String, _ authenticationToken: String) async throws -> Daemonv1.Operation

    func completeAuthentication(_ operationID: String, _ callbackURL: String) async throws -> Daemonv1.Operation

    func connect(_ domain: String) async throws -> Daemonv1.Operation

    func disconnect(_ domain: String) async throws -> Daemonv1.Operation

    func logout(_ domain: String) async throws -> Daemonv1.Operation

    func deleteDomain(_ domain: String) async throws -> Daemonv1.Operation

    func getOperation(_ id: String) async throws -> Daemonv1.Operation

    func cancelOperation(_ id: String) async throws -> Daemonv1.Operation

    func getAPICredential(_ domain: String) async throws -> Daemonv1.GetAPICredentialResponse

    func updateDomainSettings(
        _ domain: String,
        _ settings: Daemonv1.DomainSettings
    ) async throws -> Daemonv1.DomainSettings

    func setNetworkState(_ state: NetworkState) async
}
