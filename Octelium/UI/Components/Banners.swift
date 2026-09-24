import OcteliumCore
import OcteliumProto
import SwiftUI

struct ErrorBanner: View {
    @Environment(\.octColors) private var colors

    let error: Daemonv1.Error?
    var onRetry: (() -> Void)?
    var isPending = false

    var body: some View {
        if let error {
            AlertBox(tone: .red, title: getErrorTitle(error), icon: "exclamationmark.triangle") {
                VStack(alignment: .leading, spacing: 8) {
                    if let hint = getErrorHint(error) {
                        AlertText(text: hint)
                    }

                    if !error.message.isEmpty {
                        Text(error.message)
                            .font(.mono(12))
                            .foregroundStyle(colors.body.opacity(0.8))
                            .textSelection(.enabled)
                    }

                    if let onRetry, isErrorRetryable(error) {
                        OctButton(
                            text: "Try again",
                            icon: "arrow.clockwise",
                            variant: .outline,
                            size: .xs,
                            isDanger: true,
                            isLoading: isPending,
                            action: onRetry
                        )
                    }
                }
            }
            .padding(.bottom, 20)
        }
    }
}

struct OperationBanner: View {
    @Environment(\.octColors) private var colors

    let operation: Daemonv1.Operation?
    let pendingURL: String?
    let onOpenURL: (String) -> Void
    let onCancel: (Daemonv1.Operation) -> Void
    var isCanceling = false
    var error: String?

    var body: some View {
        if let operation {
            AlertBox(
                tone: .blue,
                title: "\(getOperationTypeLabel(operation.type)) \(operation.domain)",
                isLoading: true
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    if pendingURL != nil {
                        AlertText(
                            text: "Finish signing in using your web browser. The browser opens the Cluster Portal at your identity provider."
                        )
                    }

                    HStack(spacing: 10) {
                        if let pendingURL {
                            OctButton(text: "Open the browser again", icon: "arrow.up.forward.app", size: .xs) {
                                onOpenURL(pendingURL)
                            }
                        }

                        if operation.cancellable {
                            OctButton(text: "Cancel", variant: .outline, size: .xs, isLoading: isCanceling) {
                                onCancel(operation)
                            }
                        }
                    }

                    if let error {
                        Text(error)
                            .font(.ubuntu(12, .medium, relativeTo: .caption))
                            .foregroundStyle(AlertTone.red.getColors(colors.isDark).content)
                    }
                }
            }
            .padding(.bottom, 20)
        }
    }
}

struct DomainOperationBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openLogin) private var openLogin

    let state: Daemonv1.DomainState?

    @State private var mutationCancel = Mutation<String>()

    var body: some View {
        OperationBanner(
            operation: getActiveOperation(state),
            pendingURL: getPendingOpenURL(state),
            onOpenURL: { url in
                openLogin(url, state?.domain ?? "")
            },
            onCancel: { op in
                mutationCancel.mutate(op.id) { _ in
                    try await model.cancelOperation(op)
                }
            },
            isCanceling: mutationCancel.isPending,
            error: mutationCancel.error
        )
    }
}
