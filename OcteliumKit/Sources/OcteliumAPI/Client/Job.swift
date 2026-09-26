import Foundation
import Synchronization

final class Job: Sendable {
    private struct State {
        var task: Task<Void, Never>?
        var isCancelled = false
        var cause: (any Error)?
        var isDone = false
        var waiters: [UInt64: CheckedContinuation<Bool, Never>] = [:]
        var nextWaiterID: UInt64 = 0
    }

    private let state = Mutex(State())

    var cause: (any Error)? {
        state.withLock { $0.cause }
    }

    func start(_ fn: @escaping @Sendable () async -> Void) {
        let task = Task {
            await fn()
            self.finish()
        }

        let isCancelled = state.withLock { st in
            if !st.isDone {
                st.task = task
            }
            return st.isCancelled
        }

        if isCancelled {
            task.cancel()
        }
    }

    func cancel(_ cause: (any Error)? = nil) {
        let task = state.withLock { st in
            if !st.isCancelled {
                st.isCancelled = true
                st.cause = cause
            }
            return st.task
        }

        task?.cancel()
    }

    func join(timeout: Duration) async -> Bool {
        await withCheckedContinuation { cont in
            let id: UInt64? = state.withLock { st in
                if st.isDone {
                    return nil
                }

                st.nextWaiterID += 1
                st.waiters[st.nextWaiterID] = cont
                return st.nextWaiterID
            }

            guard let id else {
                cont.resume(returning: true)
                return
            }

            Task {
                try? await Task.sleep(for: timeout)
                self.resumeWaiter(id, false)
            }
        }
    }

    private func finish() {
        let waiters = state.withLock { st in
            st.isDone = true
            st.task = nil

            let ret = Array(st.waiters.values)
            st.waiters.removeAll()
            return ret
        }

        for itm in waiters {
            itm.resume(returning: true)
        }
    }

    private func resumeWaiter(_ id: UInt64, _ arg: Bool) {
        state.withLock { $0.waiters.removeValue(forKey: id) }?.resume(returning: arg)
    }
}

final class AsyncMutex: Sendable {
    private struct State {
        var isLocked = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func withLock<T>(_ fn: () async throws -> T) async rethrows -> T {
        await lock()
        defer {
            unlock()
        }

        return try await fn()
    }

    private func lock() async {
        await withCheckedContinuation { cont in
            let isLocked = state.withLock { st in
                if !st.isLocked {
                    st.isLocked = true
                    return true
                }

                st.waiters.append(cont)
                return false
            }

            if isLocked {
                cont.resume()
            }
        }
    }

    private func unlock() {
        let next = state.withLock { st in
            if st.waiters.isEmpty {
                st.isLocked = false
                return nil
            }

            return st.waiters.removeFirst()
        }

        next?.resume()
    }
}

func withTimeout<T: Sendable>(
    _ timeout: Duration,
    _ fn: @escaping @Sendable () async throws -> T
) async throws -> T? {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask {
            try await fn()
        }

        group.addTask {
            try await Task.sleep(for: timeout)
            return nil
        }

        defer {
            group.cancelAll()
        }

        return try await group.next() ?? nil
    }
}

func catchError(_ fn: () async throws -> Void) async -> (any Error)? {
    do {
        try await fn()
        return nil
    } catch {
        return error
    }
}
