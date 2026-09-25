import OcteliumCore
import OcteliumProto
import SwiftUI

enum AppTab: Hashable {
    case connection
    case services
    case settings
}

@MainActor
@Observable
final class Navigation {
    var tab: AppTab = .connection
    var settingsSection: SettingsSection = .application
    var settingsPath = NavigationPath()

    func openClusters() {
        settingsSection = .clusters
        settingsPath = NavigationPath()
        tab = .settings
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.octColors) private var colors

    var body: some View {
        ZStack {
            colors.app
                .ignoresSafeArea()

            switch model.runtimeState {
            case .loading:
                SplashView()
                    .transition(.opacity)
            case .failed(let message, let isResettable):
                StartupErrorView(message: message, isResettable: isResettable)
                    .transition(.opacity)
            case .ready:
                MainView()
                    .transition(.opacity)
            }
        }
        .animation(.smooth, value: model.runtimeState)
    }
}

struct LogoCircle: View {
    let size: CGFloat

    var body: some View {
        Image("LogoMark")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .foregroundStyle(.white)
            .frame(width: size * 0.62, height: size * 0.62)
            .frame(width: size, height: size)
            .background(Color.black, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.1), lineWidth: 1))
            .accessibilityLabel("Octelium")
    }
}

private struct SplashView: View {
    @Environment(\.octColors) private var colors

    var body: some View {
        VStack(spacing: 28) {
            LogoCircle(size: 96)

            ProgressView()
                .tint(colors.muted)
        }
    }
}

private struct StartupErrorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.octColors) private var colors

    let message: String
    let isResettable: Bool

    @State private var isConfirmingReset = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                LogoCircle(size: 96)
                    .padding(.top, 60)

                Text("Octelium could not start")
                    .font(.ubuntu(22, .bold, relativeTo: .title2))
                    .foregroundStyle(colors.strong)
                    .multilineTextAlignment(.center)
                    .padding(.top, 28)

                AlertBox(tone: .red, icon: "exclamationmark.triangle") {
                    AlertText(text: message)
                }
                .frame(maxWidth: 480)
                .padding(.top, 20)

                HStack(spacing: 12) {
                    OctButton(text: "Try again", icon: "arrow.clockwise") {
                        model.retryStart()
                    }

                    if isResettable {
                        OctButton(text: "Reset local state", variant: .outline, isDanger: true) {
                            isConfirmingReset = true
                        }
                    }
                }
                .padding(.top, 24)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .alert("Reset the local state", isPresented: $isConfirmingReset) {
            Button("Reset", role: .destructive) {
                model.resetState()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Resetting removes every stored Cluster domain, its credentials and its settings as well as the Octelium VPN configuration from this device. You will have to sign in again.")
        }
    }
}

private struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.octColors) private var colors

    @State private var navigation = Navigation()

    var body: some View {
        let isSignedIn = isAuthenticated(getDomainState(model.status, model.selectedDomain))

        TabView(selection: $navigation.tab) {
            NavigationStack {
                ConnectionView()
                    .mainToolbar()
            }
            .tabItem {
                Label(
                    isSignedIn ? "Connection" : "Sign in",
                    systemImage: isSignedIn ? "bolt.horizontal.circle" : "person.crop.circle.badge.plus"
                )
            }
            .tag(AppTab.connection)

            if isSignedIn {
                NavigationStack {
                    ServicesView()
                        .mainToolbar()
                }
                .tabItem {
                    Label("Services", systemImage: "square.grid.2x2")
                }
                .tag(AppTab.services)
            }

            NavigationStack(path: $navigation.settingsPath) {
                SettingsView()
                    .mainToolbar()
                    .navigationDestination(for: SettingsDestination.self) { _ in
                        DiagnosticsView()
                    }
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
            .tag(AppTab.settings)
        }
        .environment(navigation)
        .webAuthenticationProvider()
        .onChange(of: isSignedIn) { _, new in
            if !new && navigation.tab == .services {
                navigation.tab = .connection
            }
        }
    }
}

enum SettingsDestination: Hashable {
    case diagnostics
}

private struct MainToolbar: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.octColors) private var colors

    @State private var isSheetOpen = false

    func body(content: Content) -> some View {
        let current = getDomainState(model.status, model.selectedDomain)

        content
            .background(colors.app.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(colors.app, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Image("LogoWordmark")
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .foregroundStyle(colors.strong)
                        .frame(width: 104, height: 20)
                        .accessibilityLabel("Octelium")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isSheetOpen = true
                    } label: {
                        HStack(spacing: 8) {
                            StatusDot(
                                tone: getConnectionStateTone(current?.connection.state),
                                size: 8,
                                pulse: isConnectionBusy(current)
                            )

                            Text(model.selectedDomain ?? "Set up")
                                .font(.ubuntu(13, .medium, relativeTo: .subheadline))
                                .foregroundStyle(colors.strong)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 140, alignment: .leading)

                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(colors.faint)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(colors.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(colors.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open Cluster menu")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.setTheme(getNextThemeMode(model.prefs.theme))
                    } label: {
                        Image(systemName: getThemeModeIcon(model.prefs.theme))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(colors.strong)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .accessibilityLabel("\(getThemeModeLabel(model.prefs.theme)) theme")
                    .sensoryFeedback(.selection, trigger: model.prefs.theme)
                }
            }
            .sheet(isPresented: $isSheetOpen) {
                DomainSheet(isPresented: $isSheetOpen)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(colors.surface)
            }
    }
}

extension View {
    fileprivate func mainToolbar() -> some View {
        modifier(MainToolbar())
    }
}

private struct DomainSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigation.self) private var navigation
    @Environment(\.octColors) private var colors

    @Binding var isPresented: Bool

    var body: some View {
        let domains = model.status?.domains ?? []
        let current = getDomainState(model.status, model.selectedDomain)
        let visible: [Daemonv1.DomainState] = if model.prefs.multiCluster {
            domains
        } else if let current {
            [current]
        } else {
            Array(domains.prefix(1))
        }

        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("CLUSTER DOMAINS")
                    .font(.ubuntu(11, .bold, relativeTo: .caption))
                    .foregroundStyle(colors.faint)
                    .padding(.bottom, 8)

                ForEach(visible, id: \.domain) { itm in
                    Button {
                        model.selectDomain(itm.domain)
                        isPresented = false
                    } label: {
                        HStack(spacing: 12) {
                            StatusDot(tone: getConnectionStateTone(itm.connection.state), pulse: isConnectionBusy(itm))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(itm.domain)
                                    .font(.ubuntu(15, .bold))
                                    .foregroundStyle(colors.strong)
                                    .lineLimit(1)

                                Text(
                                    isAuthenticated(itm)
                                        ? getConnectionStateLabel(itm.connection.state)
                                        : getAuthenticationStateLabel(itm.authentication.state)
                                )
                                .font(.ubuntu(12, .medium, relativeTo: .caption))
                                .foregroundStyle(colors.muted)
                            }

                            Spacer()

                            if itm.domain == model.selectedDomain {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(colors.strong)
                            }
                        }
                        .padding(12)
                        .background(
                            itm.domain == model.selectedDomain ? colors.surface3 : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if !domains.isEmpty {
                    LineDivider()
                        .padding(.vertical, 8)
                }

                Button {
                    isPresented = false
                    navigation.openClusters()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Manage Clusters")
                            .font(.ubuntu(15, .bold))
                    }
                    .foregroundStyle(colors.strong)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, 24)
        }
    }
}
