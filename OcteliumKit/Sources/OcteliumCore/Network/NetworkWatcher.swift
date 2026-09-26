import Foundation
import Synchronization

public let reconnectBackoffMin: Duration = .seconds(2)
public let reconnectBackoffMax: Duration = .seconds(120)

public final class NetworkWatcher: Sendable {
    private struct State {
        var current = NetworkState(isAvailable: true, id: "")
        var subscribers: [UInt64: AsyncStream<NetworkState>.Continuation] = [:]
        var nextID: UInt64 = 0
    }

    private let state = Mutex(State())
    private let getBackoff: @Sendable (Int) -> Duration

    public init(getBackoff: @escaping @Sendable (Int) -> Duration = getReconnectBackoff) {
        self.getBackoff = getBackoff
    }

    public var current: NetworkState {
        state.withLock { $0.current }
    }

    public var isAvailable: Bool {
        current.isAvailable
    }

    public func set(_ arg: NetworkState) {
        state.withLock { st in
            if st.current == arg {
                return
            }

            st.current = arg
            for itm in st.subscribers.values {
                itm.yield(arg)
            }
        }
    }

    public func updates() -> AsyncStream<NetworkState> {
        let (ret, cont) = AsyncStream.makeStream(of: NetworkState.self, bufferingPolicy: .bufferingNewest(1))

        let id = state.withLock { st in
            st.nextID += 1
            return st.nextID
        }

        cont.onTermination = { [weak self] _ in
            guard let self else {
                return
            }

            state.withLock { $0.subscribers[id] = nil }
        }

        state.withLock { st in
            st.subscribers[id] = cont
            cont.yield(st.current)
        }

        return ret
    }

    public func waitReconnect(_ attempt: Int) async {
        let backoff = getBackoff(attempt)
        let updates = self.updates()
        let (events, cont) = AsyncStream.makeStream(of: NetworkState?.self)

        let forward = Task {
            for await itm in updates {
                cont.yield(itm)
            }
        }

        let timer = Task {
            try? await Task.sleep(for: backoff)
            cont.yield(nil)
        }

        defer {
            forward.cancel()
            timer.cancel()
            cont.finish()
        }

        var cur = current

        for await ev in events {
            guard let ev else {
                if cur.isAvailable {
                    return
                }
                continue
            }

            if ev != cur && ev.isAvailable {
                return
            }

            cur = ev
        }
    }
}

public func getReconnectBackoff(_ attempt: Int) -> Duration {
    let ret = min(reconnectBackoffMin * (1 << min(max(attempt - 1, 0), 6)), reconnectBackoffMax)
    let jitterMax = min(ret / 2, reconnectBackoffMax - ret)

    return ret + jitterMax * Double.random(in: 0...1)
}
