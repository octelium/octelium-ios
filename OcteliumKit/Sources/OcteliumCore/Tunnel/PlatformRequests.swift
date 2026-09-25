import Foundation
import OcteliumProto
import Synchronization

public protocol TunnelHost: Sendable {
    func apply(domain: String, generation: UInt64, spec: TunnelSpec) async throws -> Int32?
}

public protocol RequestCompleter: Sendable {
    func complete(_ requestID: UInt64, _ response: Data) -> Int32
}

public final class PlatformRequestHandler: Sendable {
    private struct ApplyState {
        var latestGeneration: UInt64 = 0
        var lastApply: Task<Void, Never>?
    }

    private let host: any TunnelHost
    private let completer: any RequestCompleter
    private let state = Mutex(ApplyState())

    public init(host: any TunnelHost, completer: any RequestCompleter) {
        self.host = host
        self.completer = completer
    }

    var latestGeneration: UInt64 {
        state.withLock { $0.latestGeneration }
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
        state.withLock { $0.latestGeneration = max($0.latestGeneration, req.generation) }

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

        let task = state.withLock { st in
            let prev = st.lastApply
            let ret = Task {
                if let prev {
                    await prev.value
                }
                await self.apply(requestID, req, spec)
            }
            st.lastApply = ret
            return ret
        }

        await task.value
    }

    private func apply(
        _ requestID: UInt64,
        _ req: Mobilev1.PlatformRequest.ApplyTunnelConfiguration,
        _ spec: TunnelSpec
    ) async {
        if state.withLock({ req.generation < $0.latestGeneration }) {
            completeError(requestID, "The tunnel configuration is stale")
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
