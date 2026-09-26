import Foundation
import OcteliumProto
import Synchronization

public protocol TunnelHost: Sendable {
    func apply(domain: String, generation: UInt64, spec: TunnelSpec) async throws -> Int32?
}

public final class PlatformRequestHandler: Sendable {
    private struct ApplyState {
        var latestGeneration: UInt64 = 0
        var lastApply: Task<TunnelResponse, Never>?
    }

    private let host: any TunnelHost
    private let state = Mutex(ApplyState())

    public init(host: any TunnelHost) {
        self.host = host
    }

    var latestGeneration: UInt64 {
        state.withLock { $0.latestGeneration }
    }

    public func applyNetworkConfig(_ domain: String, _ cfg: NetworkConfig) async -> TunnelResponse {
        state.withLock { $0.latestGeneration = max($0.latestGeneration, cfg.generation) }

        if domain.isEmpty {
            return getPlatformErrorResponse("The domain is not set")
        }

        let spec: TunnelSpec
        do {
            spec = try getTunnelSpec(cfg)
        } catch {
            return getPlatformErrorResponse(getErrorMessage(error))
        }

        let task = state.withLock { st in
            let prev = st.lastApply
            let ret = Task {
                _ = await prev?.value
                return await self.apply(domain, cfg.generation, spec)
            }
            st.lastApply = ret
            return ret
        }

        return await task.value
    }

    private func apply(_ domain: String, _ generation: UInt64, _ spec: TunnelSpec) async -> TunnelResponse {
        if state.withLock({ generation < $0.latestGeneration }) {
            return getPlatformErrorResponse("The tunnel configuration is stale")
        }

        do {
            let tunFD = try await host.apply(domain: domain, generation: generation, spec: spec)
            return .applyNetworkConfig(tunFD: tunFD)
        } catch {
            return getPlatformErrorResponse(getErrorMessage(error))
        }
    }
}

public func getPlatformErrorResponse(_ message: String) -> TunnelResponse {
    .error(.platform, message)
}
