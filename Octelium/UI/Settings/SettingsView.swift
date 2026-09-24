import OcteliumCore
import OcteliumProto
import SwiftUI

enum SettingsSection: String, CaseIterable, Hashable {
    case application
    case cluster
    case clusters

    var title: String {
        switch self {
        case .application: "Application settings"
        case .cluster: "Cluster settings"
        case .clusters: "Manage Clusters"
        }
    }

    var label: String {
        switch self {
        case .application: "Application"
        case .cluster: "Cluster"
        case .clusters: "Clusters"
        }
    }

    var description: String {
        switch self {
        case .application: "Preferences for this iOS application, independent of any Cluster."
        case .cluster: "Connection policy for the selected Cluster. Changes apply on the next Connection."
        case .clusters: "Add, select, sign out of, or remove Cluster domains from this device."
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigation.self) private var navigation

    var body: some View {
        @Bindable var navigation = navigation
        let section = navigation.settingsSection == .cluster && model.selectedDomain == nil
            ? SettingsSection.application
            : navigation.settingsSection

        ScreenScroll {
            PageHeader(title: section.title, description: section.description)

            Picker("Section", selection: $navigation.settingsSection) {
                ForEach(SettingsSection.allCases, id: \.self) { itm in
                    Text(itm.label)
                        .tag(itm)
                }
            }
            .pickerStyle(.segmented)
            .padding(.bottom, 20)

            switch section {
            case .application:
                AppSettings()
            case .cluster:
                if let domain = model.selectedDomain {
                    DomainSettingsView(domain: domain)
                        .id(domain)
                }
            case .clusters:
                ClustersView()
            }
        }
        .animation(.snappy, value: section)
    }
}

private struct AppSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.octColors) private var colors

    var body: some View {
        SectionCard {
            SectionTitle(text: "Application preferences")

            Text("These preferences belong to this application. They never affect your Cluster Sessions.")
                .font(.ubuntu(14, .medium))
                .foregroundStyle(colors.muted)
                .padding(.vertical, 4)

            SettingRow(
                title: "Current version",
                description: appReleaseTag.isEmpty
                    ? "This build was not created from a release tag."
                    : "The version installed on this device."
            ) {
                ValueText(text: appReleaseTag.isEmpty ? "Development build" : appReleaseTag)
            }

            SettingRow(title: "liboctelium", description: "The embedded Octelium client library.") {
                ValueText(text: getLibVersion(model.info?.version))
            }

            SettingRow(title: "Theme") {
                SelectField(
                    options: ThemeMode.allCases.map { SelectOption(value: $0, label: getThemeModeLabel($0)) },
                    value: model.prefs.theme
                ) {
                    model.setTheme($0 ?? .system)
                }
                .frame(width: 140)
            }

            SettingRow(
                title: "Multiple Clusters",
                description: "Show every configured domain in the Cluster switcher. Most people only need one domain."
            ) {
                OctToggle(
                    label: "Multiple Clusters",
                    isOn: Binding(get: { model.prefs.multiCluster }, set: { model.setMultiCluster($0) })
                )
            }

            SettingRow(
                title: "Connect On Demand",
                description: "iOS keeps the Cluster with auto connect enabled connected whenever a network is available. Enable it per Cluster in the Cluster settings."
            ) {
                ValueText(text: model.isOnDemandEnabled ? "On" : "Off")
            }

            SettingRow(title: "Diagnostics", description: "Runtime information for troubleshooting.", isLast: true) {
                NavigationLink(value: SettingsDestination.diagnostics) {
                    HStack(spacing: 6) {
                        Image(systemName: "stethoscope")
                            .font(.system(size: 12, weight: .semibold))
                        Text("View")
                            .font(.ubuntu(12, .bold))
                    }
                    .foregroundStyle(colors.strong)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(colors.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(colors.lineStrong, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

let appReleaseTag = getInfoString("OcteliumReleaseTag") ?? ""
let libCommit = getInfoString("OcteliumLibCommit") ?? ""

func getLibVersion(_ version: String?) -> String {
    if let version, !version.isEmpty {
        return version
    }

    if !libCommit.isEmpty {
        return String(libCommit.prefix(12))
    }

    return "—"
}

struct ValueText: View {
    @Environment(\.octColors) private var colors

    let text: String

    var body: some View {
        Text(text)
            .font(.ubuntu(14, .bold))
            .foregroundStyle(colors.strong)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

private struct DomainSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.octColors) private var colors

    let domain: String

    @State private var baseline = DomainSettingsForm()
    @State private var form = DomainSettingsForm()
    @State private var isAdvanced = false
    @State private var mutation = Mutation<DomainSettingsForm>()

    var body: some View {
        let state = getDomainState(model.status, domain)
        let formError = validateDomainSettingsForm(form)
        let isDirty = form != baseline

        VStack(alignment: .leading, spacing: 0) {
            SectionCard {
                SectionTitle(text: domain)

                Text("These settings are stored by liboctelium on this device and they are used by the next Connection of this Cluster.")
                    .font(.ubuntu(14, .medium))
                    .foregroundStyle(colors.muted)
                    .padding(.top, 4)

                if isConnected(state) {
                    Notice(
                        title: "Already connected",
                        content: "Saving does not reconfigure the active Connection. Reconnect in order to apply the new settings."
                    )
                    .padding(.top, 16)
                }

                if let err = mutation.error {
                    AlertBox(tone: .red, title: "Could not save") {
                        AlertText(text: err)
                    }
                    .padding(.top, 16)
                }

                if let formError {
                    AlertBox(tone: .orange, title: "Check the settings") {
                        AlertText(text: formError)
                    }
                    .padding(.top, 16)
                }

                if mutation.isSuccess && !isDirty {
                    AlertBox(tone: .green, title: "Saved") {
                        AlertText(text: "The settings of the Cluster were stored.")
                    }
                    .padding(.top, 16)
                }

                SettingRow(
                    title: "Auto connect",
                    description: "Let iOS connect this Cluster on demand whenever a network is available and usable credentials exist."
                ) {
                    OctToggle(label: "Auto connect", isOn: binding(\.autoConnect))
                }
                .padding(.top, 4)

                SettingRow(title: "Tunnel mode") {
                    SelectField(
                        options: tunnelModes.map { SelectOption(value: $0, label: getTunnelModeLabel($0)) },
                        value: form.tunnelMode
                    ) {
                        update(\.tunnelMode, $0 ?? .unspecified)
                    }
                    .frame(width: 160)
                }

                SettingRow(
                    title: "DNS",
                    description: "Split DNS resolves only the Cluster domains via the Cluster DNS. Full DNS resolves every domain via the Cluster DNS.",
                    isLast: !isAdvanced,
                    isStacked: true
                ) {
                    SelectField(
                        options: dnsModes.map { SelectOption(value: $0, label: getDNSModeOptionLabel($0)) },
                        value: form.dnsMode
                    ) {
                        update(\.dnsMode, $0 ?? .default)
                    }
                }

                TextLinkButton(text: "Advanced", trailingIcon: "chevron.down", isExpanded: isAdvanced) {
                    withAnimation(.snappy) {
                        isAdvanced.toggle()
                    }
                }
                .padding(.top, 8)

                if isAdvanced {
                    VStack(alignment: .leading, spacing: 0) {
                        SettingRow(title: "Layer 3 mode") {
                            SelectField(
                                options: l3Modes.map { SelectOption(value: $0, label: getL3ModeLabel($0)) },
                                value: form.l3Mode
                            ) {
                                update(\.l3Mode, $0 ?? .unspecified)
                            }
                            .frame(width: 160)
                        }

                        SettingRow(title: "MTU", description: "Leave it empty in order to let Octelium choose.", isLast: true) {
                            OctTextField(
                                placeholder: "Auto",
                                text: Binding(
                                    get: { form.mtu },
                                    set: { update(\.mtu, String($0.filter(\.isNumber).prefix(4))) }
                                ),
                                keyboardType: .numberPad
                            )
                            .frame(width: 120)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            if isDirty {
                SectionCard(padding: 14) {
                    Text("Unsaved changes")
                        .font(.ubuntu(14, .bold))
                        .foregroundStyle(colors.strong)

                    Text("Save or cancel before leaving these Cluster settings.")
                        .font(.ubuntu(12, .medium, relativeTo: .caption))
                        .foregroundStyle(colors.muted)

                    HStack(spacing: 10) {
                        Spacer()

                        OctButton(text: "Cancel", variant: .outline, isEnabled: !mutation.isPending) {
                            form = baseline
                            mutation.reset()
                        }

                        OctButton(
                            text: "Save changes",
                            icon: "square.and.arrow.down",
                            isLoading: mutation.isPending,
                            isEnabled: formError == nil
                        ) {
                            save()
                        }
                    }
                    .padding(.top, 12)
                }
                .padding(.top, 16)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.snappy, value: isDirty)
        .onAppear {
            load(getSettings(state))
        }
        .onChange(of: getSettings(state)) { _, new in
            if form == baseline {
                load(new)
            }
        }
    }

    private func getSettings(_ state: Daemonv1.DomainState?) -> Daemonv1.DomainSettings? {
        guard let state, state.hasSettings else {
            return nil
        }

        return state.settings
    }

    private func load(_ settings: Daemonv1.DomainSettings?) {
        let ret = getDomainSettingsForm(settings)
        baseline = ret
        form = ret
    }

    private func binding(_ keyPath: WritableKeyPath<DomainSettingsForm, Bool>) -> Binding<Bool> {
        Binding(get: { form[keyPath: keyPath] }, set: { update(keyPath, $0) })
    }

    private func update<V>(_ keyPath: WritableKeyPath<DomainSettingsForm, V>, _ value: V) {
        mutation.reset()
        form[keyPath: keyPath] = value
    }

    private func save() {
        let domain = self.domain
        let arg = form

        mutation.mutate(arg, onSuccess: { saved in
            baseline = saved
        }) { arg in
            _ = try await model.updateDomainSettings(domain, toDomainSettings(domain, arg))
        }
    }
}

private enum ClusterAction: Equatable {
    case connect
    case disconnect
    case logout
    case delete
}

private struct ClustersView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let domains = model.status?.domains ?? []

        VStack(alignment: .leading, spacing: 16) {
            ClusterSignInView(
                isCompact: true,
                title: domains.isEmpty ? "Add a Cluster" : "Add another Cluster",
                description: domains.isEmpty
                    ? "Enter your Cluster domain to sign in and connect this device."
                    : "Add another domain. The selected domain becomes the primary Cluster shown throughout the app."
            )

            VStack(spacing: 10) {
                ForEach(domains, id: \.domain) { itm in
                    ClusterItem(item: itm)
                }
            }
        }
    }
}

private struct ClusterItem: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigation.self) private var navigation
    @Environment(\.octColors) private var colors
    @Environment(\.openLogin) private var openLogin

    let item: Daemonv1.DomainState

    @State private var mutation = Mutation<ClusterAction>()
    @State private var mutationAuth = Mutation<String>()
    @State private var confirm: ClusterAction?

    var body: some View {
        SectionCard(padding: 16) {
            HStack(spacing: 12) {
                StatusDot(tone: getConnectionStateTone(item.connection.state), size: 12, pulse: isConnectionBusy(item))

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(item.domain)
                            .font(.ubuntu(15, .bold))
                            .foregroundStyle(colors.strong)
                            .lineLimit(1)

                        if item.domain == model.selectedDomain {
                            OctLabel(text: "Selected", tone: .sky)
                        }
                    }

                    FlowLayout(spacing: 6) {
                        OctLabel(
                            text: getAuthenticationStateLabel(item.authentication.state),
                            tone: getAuthenticationStateTone(item.authentication.state)
                        )
                        OctLabel(text: getConnectionStateLabel(item.connection.state), tone: .slate)

                        if item.settings.autoConnect {
                            OctLabel(text: "Auto connect", tone: .neutral)
                        }
                    }
                }
            }
            .padding(.bottom, 14)

            FlowLayout(spacing: 8) {
                if isAuthenticated(item) {
                    if canDisconnect(item) {
                        OctButton(
                            text: "Disconnect",
                            icon: "bolt.slash.fill",
                            variant: .outline,
                            size: .xs,
                            isLoading: mutation.isPendingFor(.disconnect)
                        ) {
                            run(.disconnect)
                        }
                    } else {
                        OctButton(
                            text: "Connect",
                            icon: "bolt.fill",
                            size: .xs,
                            isLoading: mutation.isPendingFor(.connect),
                            isEnabled: canConnect(item)
                        ) {
                            run(.connect)
                        }
                    }

                    OctButton(text: "Sign out", icon: "rectangle.portrait.and.arrow.right", variant: .outline, size: .xs) {
                        confirm = .logout
                    }
                } else {
                    OctButton(
                        text: "Sign in",
                        icon: "arrow.right.circle",
                        size: .xs,
                        isLoading: mutationAuth.isPending,
                        isEnabled: !isConnectionBusy(item) && !mutation.isPending
                    ) {
                        signIn()
                    }
                }

                OctButton(text: "Open", variant: .default, size: .xs) {
                    model.selectDomain(item.domain)
                    navigation.tab = .connection
                }

                OctButton(text: "Remove", icon: "trash", variant: .outline, size: .xs, isDanger: true) {
                    confirm = .delete
                }
            }

            if let err = mutation.error ?? mutationAuth.error {
                Text(err)
                    .font(.ubuntu(14, .medium))
                    .foregroundStyle(AlertTone.red.getColors(colors.isDark).content)
                    .padding(.top, 12)
            }
        }
        .alert("Sign out", isPresented: isConfirming(.logout)) {
            Button("Sign out", role: .destructive) {
                run(.logout)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Signing out of \(item.domain) disconnects the Cluster, invalidates the Session and removes the stored credentials of this device.")
        }
        .alert("Remove the Cluster", isPresented: isConfirming(.delete)) {
            Button("Remove", role: .destructive) {
                run(.delete)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removing \(item.domain) signs out and deletes both the credentials and the locally stored settings of the Cluster.")
        }
    }

    private func isConfirming(_ action: ClusterAction) -> Binding<Bool> {
        Binding(get: { confirm == action }, set: { if !$0 { confirm = nil } })
    }

    private func run(_ action: ClusterAction) {
        let domain = item.domain

        mutation.mutate(action) { action in
            switch action {
            case .connect:
                try await model.connect(domain)
            case .disconnect:
                try await model.disconnect(domain)
            case .logout:
                try await model.logout(domain)
            case .delete:
                try await model.deleteDomain(domain)
            }
        }
    }

    private func signIn() {
        let domain = item.domain

        mutationAuth.mutate(domain) { domain in
            model.selectDomain(domain)
            let op = try await model.authenticateBrowser(domain)
            if case .openURL(let action) = op.action.type {
                openLogin(action.url, op.domain.isEmpty ? domain : op.domain)
            }
        }
    }
}
