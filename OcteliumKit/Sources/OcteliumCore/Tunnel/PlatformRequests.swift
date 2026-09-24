import Foundation
import OcteliumProto

public protocol TunnelHost: Sendable {
    func apply(domain: String, generation: UInt64, spec: TunnelSpec) async throws -> Int32?
}

public protocol RequestCompleter: Sendable {
    func complete(_ requestID: UInt64, _ response: Data) -> Int32
}

public struct PlatformRequestHandler: Sendable {
    private let host: any TunnelHost
    private let completer: any RequestCompleter

    public init(host: any TunnelHost, completer: any RequestCompleter) {
        self.host = host
        self.completer = completer
    }

    public func handle(_ requestID: UInt64, _ data: Data) async {
        let req: Mobilev1.PlatformRequest
        do {
            req = try Mobilev1.PlatformRequest(serializedBytes: data)
        } catch {
            completeError(requestID, "Could not unmarshal the platform request: \(error)")
            return
        }

        switch req.type {
        case .applyTunnelConfiguration(let arg):
            await applyTunnelConfiguration(requestID, arg)
        case nil:
            completeError(requestID, "Unsupported platform request")
        }
    }

    private func applyTunnelConfiguration(
        _ requestID: UInt64,
        _ req: Mobilev1.PlatformRequest.ApplyTunnelConfiguration
    ) async {
        if req.domain.isEmpty {
            completeError(requestID, "The domain is not set")
            return
        }

        let spec: TunnelSpec
        do {
            spec = try getTunnelSpec(req.configuration)
        } catch {
            completeError(requestID, getErrorMessage(error))
            return
        }

        let tunFD: Int32?
        do {
            tunFD = try await host.apply(domain: req.domain, generation: req.generation, spec: spec)
        } catch {
            completeError(requestID, getErrorMessage(error))
            return
        }

        complete(requestID, getApplyTunnelConfigurationResponse(tunFD: tunFD))
    }

    private func completeError(_ requestID: UInt64, _ message: String) {
        complete(requestID, getPlatformErrorResponse(message))
    }

    private func complete(_ requestID: UInt64, _ resp: Mobilev1.PlatformResponse) {
        guard let data: Data = try? resp.serializedBytes() else {
            return
        }

        _ = completer.complete(requestID, data)
    }
}

public func getPlatformErrorResponse(_ message: String) -> Mobilev1.PlatformResponse {
    var ret = Mobilev1.PlatformResponse()
    ret.error.message = message
    return ret
}

public func getApplyTunnelConfigurationResponse(tunFD: Int32?) -> Mobilev1.PlatformResponse {
    var ret = Mobilev1.PlatformResponse()
    ret.applyTunnelConfiguration = Mobilev1.PlatformResponse.ApplyTunnelConfiguration()
    if let tunFD {
        ret.applyTunnelConfiguration.tunFd = tunFD
    }
    return ret
}
