import OcteliumCore
import OcteliumProto
import SwiftUI

enum SignInMethod: Equatable {
    case browser
    case token
}

struct ClusterSignInView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.octColors) private var colors
    @Environment(\.openLogin) private var openLogin

    var domain: String?
    var isCompact = false
    var title: String?
    var description: String?
    var onSuccess: (String) -> Void = { _ in }

    @State private var domainInput = ""
    @State private var token = ""
    @State private var isAdvanced = false
    @State private var mutation = Mutation<SignInMethod>()

    var body: some View {
        let isBusy = isConnectionBusy(getDomainState(model.status, domain))

        VStack(alignment: isCompact ? .leading : .center, spacing: 0) {
            if !isCompact {
                LogoCircle(size: 128)
                    .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
                    .padding(.top, 12)
            }

            Text(title ?? (domain.map { "Sign in to \($0)" } ?? "Welcome to Octelium"))
                .font(.ubuntu(isCompact ? 18 : 24, .bold, relativeTo: .title2))
                .foregroundStyle(colors.strong)
                .multilineTextAlignment(isCompact ? .leading : .center)
                .padding(.top, isCompact ? 0 : 28)

            Text(
                description ?? (domain != nil
                    ? "Continue in your browser to renew this Cluster Session."
                    : "Enter your Cluster domain to securely sign in and connect this device.")
            )
            .font(.ubuntu(14, .medium))
            .foregroundStyle(colors.muted)
            .multilineTextAlignment(isCompact ? .leading : .center)
            .lineSpacing(4)
            .frame(maxWidth: 420, alignment: isCompact ? .leading : .center)
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 16) {
                if domain == nil {
                    OctTextField(
                        label: "Cluster domain",
                        placeholder: "example.com",
                        text: $domainInput,
                        keyboardType: .URL,
                        textContentType: .URL,
                        submitLabel: .go,
                        onSubmit: { signIn(.browser) }
                    )
                    .onChange(of: domainInput) {
                        mutation.reset()
                    }
                }

                if let err = mutation.error {
                    AlertBox(tone: .red, title: "Could not start sign in") {
                        AlertText(text: err)
                    }
                }

                OctButton(
                    text: "Continue in browser",
                    icon: "arrow.right.circle",
                    size: .lg,
                    isLoading: mutation.isPendingFor(.browser),
                    isEnabled: !mutation.isPending && !isBusy,
                    fullWidth: true
                ) {
                    signIn(.browser)
                }

                TextLinkButton(text: "Use an authentication Token", trailingIcon: "chevron.down", isExpanded: isAdvanced) {
                    withAnimation(.snappy) {
                        isAdvanced.toggle()
                    }
                }
                .frame(maxWidth: .infinity)

                if isAdvanced {
                    VStack(alignment: .leading, spacing: 12) {
                        LineDivider()

                        OctTextField(
                            label: "Authentication Token",
                            placeholder: "Paste the Token",
                            text: $token,
                            isSecure: true,
                            submitLabel: .done,
                            onSubmit: { signIn(.token) }
                        )

                        OctButton(
                            text: "Use Token",
                            icon: "key",
                            variant: .outline,
                            isLoading: mutation.isPendingFor(.token),
                            isEnabled: !mutation.isPending && !isBusy,
                            fullWidth: true
                        ) {
                            signIn(.token)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(20)
            .background(colors.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(colors.line, lineWidth: 1))
            .shadow(color: .black.opacity(colors.isDark ? 0 : 0.08), radius: 8, y: 2)
            .padding(.top, isCompact ? 16 : 28)
        }
        .frame(maxWidth: .infinity, alignment: isCompact ? .leading : .center)
        .animation(.snappy, value: mutation.error)
    }

    private func signIn(_ method: SignInMethod) {
        let input = domain ?? domainInput
        let authenticationToken = token.trimmingCharacters(in: .whitespacesAndNewlines)

        mutation.mutate(method, onSuccess: { _ in
            domainInput = ""
            token = ""
        }) { method in
            let target = normalizeDomain(input)
            if let err = validateDomain(target) {
                throw StatusError(.invalidArgument, err)
            }

            if method == .token && authenticationToken.isEmpty {
                throw StatusError(.invalidArgument, "The authentication Token is required")
            }

            let op: Daemonv1.Operation
            if method == .browser {
                op = try await model.authenticateBrowser(target)
            } else {
                op = try await model.authenticateToken(target, authenticationToken)
            }

            let opDomain = op.domain.isEmpty ? target : op.domain

            if op.state == .waitingForUser, case .openURL(let action) = op.action.type {
                openLogin(action.url, opDomain)
            }

            onSuccess(opDomain)
        }
    }
}
