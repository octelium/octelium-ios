import Observation
import OcteliumCore
import SwiftUI

@MainActor
@Observable
final class Mutation<T> {
    private(set) var isPending = false
    private(set) var error: String?
    private(set) var variables: T?
    private(set) var isSuccess = false

    func mutate(_ arg: T, onSuccess: ((T) -> Void)? = nil, _ fn: @escaping (T) async throws -> Void) {
        if isPending {
            return
        }

        isPending = true
        error = nil
        isSuccess = false
        variables = arg

        Task {
            do {
                try await fn(arg)
                isSuccess = true
                onSuccess?(arg)
            } catch is CancellationError {
            } catch {
                self.error = getErrorMessage(error)
            }

            isPending = false
        }
    }

    func isPendingFor(_ arg: T) -> Bool where T: Equatable {
        isPending && variables == arg
    }

    func reset() {
        error = nil
        isSuccess = false
        variables = nil
    }
}
