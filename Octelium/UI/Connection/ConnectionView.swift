import OcteliumAPI
import OcteliumCore
import OcteliumProto
import SwiftUI

struct ConnectionView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = getDomainState(model.status, model.selectedDomain)

        ScreenScroll {
            DomainOperationBanner(state: state)

            if model.isCompletingAuthentication {
                AlertBox(tone: .blue, title: "Completing the sign in", isLoading: true) {
                    AlertText(text: "The Cluster is verifying your browser authentication.")
                }
                .padding(.bottom, 20)
            }

            if let err = model.authCallbackError {
                AlertBox(tone: .red, title: "Could not complete the sign in") {
                    AlertText(text: err)

                    OctButton(text: "Dismiss", variant: .outline, size: .xs, isDanger: true) {
                        model.dismissAuthCallbackError()
                    }
                    .padding(.top, 6)
                }
                .padding(.bottom, 20)
            }

            if let selected = model.selectedDomain {
                if let state, isAuthenticated(state) {
                    ConnectionDetails(domain: selected, state: state)
                } else {
                    ErrorBanner(error: getLastError(state))
                    ClusterSignInView(domain: selected)
                }
            } else {
                ClusterSignInView()
            }
        }
        .refreshable {
            await model.refreshAppStatus()
            await model.refreshTunnel()
        }
        .animation(.snappy, value: model.authCallbackError)
        .animation(.snappy, value: model.isCompletingAuthentication)
    }
}

private struct ConnectionDetails: View {
    @Environment(AppModel.self) private var model
    @Environment(\.octColors) private var colors

    let domain: String
    let state: Daemonv1.DomainState

    @State private var mutationConnect = Mutation<String>()
    @State private var mutationDisconnect = Mutation<String>()
    @State private var mutationLogout = Mutation<String>()
    @State private var isConfirmingLogout = false

    var body: some View {
        let connection = state.connection
        let connected = isConnected(state)
        let tunnelDomain = getTunnelDomainState(model.status)?.domain
        let isOtherTunnel = tunnelDomain != nil && tunnelDomain != domain
        let isBusy = isConnectionBusy(state) || mutationConnect.isPending || mutationDisconnect.isPending

        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Connection", description: domain) {
                OctLabel(
                    text: getAuthenticationStateLabel(state.authentication.state),
                    tone: getAuthenticationStateTone(state.authentication.state),
                    icon: "checkmark.shield"
                )
            }

            ErrorBanner(error: getLastError(state), onRetry: connect, isPending: mutationConnect.isPending)

            if model.isOffline {
                Notice(
                    title: "No network",
                    icon: "wifi.slash",
                    content: "This device is currently offline. Octelium reconnects automatically once a network becomes available."
                )
                .padding(.bottom, 16)
            }

            SectionCard(padding: 20) {
                HStack(spacing: 16) {
                    StatusDot(tone: getConnectionStateTone(connection.state), size: 14, pulse: isConnectionBusy(state))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(getConnectionStateLabel(connection.state))
                            .font(.ubuntu(20, .bold, relativeTo: .title3))
                            .foregroundStyle(colors.strong)
                            .contentTransition(.opacity)

                        if connected && connection.hasConnectedAt {
                            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                Text("Connected for \(printDuration(connection.connectedAt, now: ctx.date))")
                                    .font(.ubuntu(14, .medium))
                                    .foregroundStyle(colors.muted)
                                    .monospacedDigit()
                            }
                        } else {
                            Text("Your Cluster credentials are ready")
                                .font(.ubuntu(14, .medium))
                                .foregroundStyle(colors.muted)
                        }
                    }
                }

                Group {
                    if canDisconnect(state) {
                        OctButton(
                            text: "Disconnect",
                            icon: "bolt.slash.fill",
                            variant: .outline,
                            size: .md,
                            isLoading: mutationDisconnect.isPending,
                            fullWidth: true
                        ) {
                            mutationDisconnect.mutate(domain) { try await model.disconnect($0) }
                        }
                    } else {
                        OctButton(
                            text: "Connect",
                            icon: "bolt.fill",
                            size: .md,
                            isLoading: mutationConnect.isPending,
                            isEnabled: canConnect(state) && !isBusy && !isOtherTunnel,
                            fullWidth: true,
                            action: connect
                        )
                    }
                }
                .padding(.top, 20)

                let err = mutationConnect.error ?? mutationDisconnect.error ?? (isOtherTunnel
                    ? "The domain \(tunnelDomain ?? "") is already connected. Only a single Cluster can be connected at a time on this device."
                    : nil)

                if let err {
                    Text(err)
                        .font(.ubuntu(14, .medium))
                        .foregroundStyle(AlertTone.red.getColors(colors.isDark).content)
                        .padding(.top, 14)
                }
            }
            .sensoryFeedback(.success, trigger: connected) { _, new in new }

            if connected {
                TunnelCard(state: state)
                    .padding(.top, 16)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))

                SessionCard(domain: domain)
                    .padding(.top, 16)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            OctButton(text: "Sign out", icon: "rectangle.portrait.and.arrow.right", variant: .subtle) {
                isConfirmingLogout = true
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 24)

            if let err = mutationLogout.error {
                Text(err)
                    .font(.ubuntu(14, .medium))
                    .foregroundStyle(AlertTone.red.getColors(colors.isDark).content)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }
        }
        .animation(.smooth, value: connected)
        .alert("Sign out", isPresented: $isConfirmingLogout) {
            Button("Sign out", role: .destructive) {
                mutationLogout.mutate(domain) { try await model.logout($0) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Signing out of \(domain) disconnects the Cluster, invalidates the Session and removes the stored credentials of this device.")
        }
    }

    private func connect() {
        mutationConnect.mutate(domain) { try await model.connect($0) }
    }
}

private struct TunnelCard: View {
    let state: Daemonv1.DomainState

    var body: some View {
        let connection = state.connection
        let dns = connection.dns
        let addresses = connection.addresses.flatMap { [$0.v4, $0.v6] }.filter { !$0.isEmpty }

        SectionCard {
            SectionTitle(text: "Tunnel")
                .padding(.bottom, 16)

            InfoGrid(items: [
                InfoGridItem("Tunnel mode") { InfoText(text: getTunnelModeLabel(connection.tunnelMode)) },
                InfoGridItem("Implementation") { InfoText(text: getImplementationModeLabel(connection.implementationMode)) },
                InfoGridItem("MTU") { InfoText(text: connection.mtu > 0 ? String(connection.mtu) : "—") },
                InfoGridItem("Connected at") { InfoText(text: printTimeAgo(connection.connectedAt)) },
                InfoGridItem("DNS") {
                    InfoText(text: getDNSModeLabel(dns.mode) + (connection.hasDns && !dns.isConfigured ? " (not applied)" : ""))
                },
            ])

            if !addresses.isEmpty {
                InfoItem(title: "Addresses") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(addresses, id: \.self) { itm in
                            CopyText(value: itm)
                        }
                    }
                }
                .padding(.top, 16)
            }

            if !dns.servers.isEmpty {
                InfoItem(title: "DNS servers") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(dns.servers, id: \.self) { itm in
                            CopyText(value: itm)
                        }
                    }
                }
                .padding(.top, 16)
            }
        }
    }
}

private struct SessionCard: View {
    @Environment(AppModel.self) private var model

    let domain: String

    @State private var resp: Userv1.GetStatusResponse?

    var body: some View {
        Group {
            if let resp {
                SectionCard {
                    SectionTitle(text: "Session")
                        .padding(.bottom, 16)

                    InfoGrid(items: [
                        InfoGridItem("User") { InfoText(text: resp.user.metadata.name.isEmpty ? "—" : resp.user.metadata.name) },
                        InfoGridItem("Email") { InfoText(text: resp.user.spec.email.isEmpty ? "—" : resp.user.spec.email) },
                        InfoGridItem("Cluster") {
                            InfoText(text: resp.cluster.metadata.name.isEmpty ? domain : resp.cluster.metadata.name)
                        },
                        InfoGridItem("Cluster-side state") {
                            InfoText(text: resp.session.status.isConnected ? "Connected" : "Not connected")
                        },
                        InfoGridItem("Network") { InfoText(text: getNetworkLabel(model.networkInfo)) },
                    ])

                    InfoItem(title: "Session") {
                        Mono(text: resp.session.metadata.name.isEmpty ? "—" : resp.session.metadata.name)
                    }
                    .padding(.top, 16)
                }
            }
        }
        .task(id: domain) {
            resp = try? await model.cluster.getStatus(domain)
        }
    }
}
