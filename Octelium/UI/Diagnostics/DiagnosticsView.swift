import LibOctelium
import OcteliumAPI
import OcteliumCore
import OcteliumProto
import SwiftUI
import UIKit

let maxVisibleLogs = 200

enum LogSource: String, CaseIterable, Hashable {
    case app
    case tunnel

    var label: String {
        switch self {
        case .app: "Application"
        case .tunnel: "Tunnel"
        }
    }
}

@MainActor
func getDeviceModel() -> String {
    var info = utsname()
    uname(&info)

    let ret = withUnsafeBytes(of: &info.machine) { buf in
        String(decoding: buf.prefix { $0 != 0 }, as: UTF8.self)
    }

    return ret.isEmpty ? UIDevice.current.model : ret
}

func getVPNStateLabel(_ arg: VPNState) -> String {
    switch arg {
    case .invalid: "Not configured"
    case .disconnected: "Disconnected"
    case .connecting: "Connecting"
    case .connected: "Connected"
    case .reasserting: "Reconnecting"
    case .disconnecting: "Disconnecting"
    }
}

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.octColors) private var colors

    @State private var source = LogSource.app
    @State private var tunnelLogs: [Mobilev1.Log] = []

    var body: some View {
        let info = model.info
        let status = model.status
        let logs = source == .app ? model.logs : tunnelLogs

        ScreenScroll {
            PageHeader(
                title: "Diagnostics",
                description: "Runtime information for troubleshooting the application and liboctelium."
            )

            VStack(alignment: .leading, spacing: 16) {
                SectionCard {
                    HStack(spacing: 8) {
                        SectionTitle(text: "liboctelium")
                        OctLabel(text: info != nil ? "Available" : "Unavailable", tone: info != nil ? .emerald : .rose)
                    }
                    .padding(.bottom, 16)

                    InfoGrid(items: [
                        InfoGridItem("Version") { InfoText(text: getLibVersion(info?.version)) },
                        InfoGridItem("Local API") {
                            InfoText(text: info.map { "v\($0.apiMajorVersion).\($0.apiMinorVersion)" } ?? "—")
                        },
                        InfoGridItem("C ABI") { InfoText(text: "v\(abiVersion)") },
                        InfoGridItem("State revision") { InfoText(text: model.appStatus.map { String($0.revision) } ?? "—") },
                        InfoGridItem("Instance") { Mono(text: info.map { String($0.instanceID.prefix(12)) } ?? "—") },
                        InfoGridItem("Commit") { Mono(text: libCommit.isEmpty ? "—" : String(libCommit.prefix(12))) },
                    ])
                }

                SectionCard {
                    SectionTitle(text: "Application")
                        .padding(.bottom, 16)

                    InfoGrid(items: [
                        InfoGridItem("Version") { InfoText(text: appReleaseTag.isEmpty ? "Development build" : appReleaseTag) },
                        InfoGridItem("Build") { InfoText(text: getAppBuild()) },
                        InfoGridItem("iOS") { InfoText(text: UIDevice.current.systemVersion) },
                        InfoGridItem("Device") { InfoText(text: getDeviceModel()) },
                        InfoGridItem("Network") { InfoText(text: getNetworkLabel(model.networkInfo)) },
                    ])
                }

                SectionCard {
                    SectionTitle(text: "VPN")
                        .padding(.bottom, 16)

                    InfoGrid(items: [
                        InfoGridItem("State") { InfoText(text: getVPNStateLabel(model.tunnel.state)) },
                        InfoGridItem("Domain") { InfoText(text: model.tunnel.domain ?? "—") },
                        InfoGridItem("On Demand") { InfoText(text: model.isOnDemandEnabled ? "On" : "Off") },
                        InfoGridItem("Tunnel instance") {
                            Mono(text: model.tunnel.status.map { String($0.instanceID.prefix(12)) } ?? "—")
                        },
                        InfoGridItem("Tunnel revision") {
                            InfoText(text: model.tunnel.status.map { String($0.revision) } ?? "—")
                        },
                        InfoGridItem("Last error") { InfoText(text: model.tunnel.error?.message ?? "—") },
                    ])
                }

                ForEach(status?.domains ?? [], id: \.domain) { itm in
                    SectionCard {
                        FlowLayout(spacing: 8) {
                            SectionTitle(text: itm.domain)
                            OctLabel(text: getConnectionStateLabel(itm.connection.state), tone: .slate)
                            OctLabel(text: getAuthenticationStateLabel(itm.authentication.state), tone: .neutral)
                        }
                        .padding(.bottom, 16)

                        InfoGrid(columns: 1, items: [
                            InfoGridItem("Authenticated at") { Mono(text: toRFC3339(itm.authentication.authenticatedAt) ?? "—") },
                            InfoGridItem("Credentials expire at") { Mono(text: toRFC3339(itm.authentication.expiresAt) ?? "—") },
                            InfoGridItem("Connected at") { Mono(text: toRFC3339(itm.connection.connectedAt) ?? "—") },
                            InfoGridItem("Last error") { InfoText(text: itm.lastError.message.isEmpty ? "—" : itm.lastError.message) },
                            InfoGridItem("Cluster API") { ClusterAPICheck(domain: itm.domain) },
                        ])
                    }
                }

                SectionCard {
                    HStack(spacing: 8) {
                        SectionTitle(text: "Logs")

                        Spacer()

                        ShareLink(item: logs.map { formatLog($0) }.joined(separator: "\n")) {
                            HStack(spacing: 6) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("Share")
                                    .font(.ubuntu(12, .bold))
                            }
                            .foregroundStyle(colors.strong)
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(colors.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(colors.lineStrong, lineWidth: 1)
                            )
                        }
                        .disabled(logs.isEmpty)

                        OctButton(text: "Copy", icon: "doc.on.doc", variant: .default, size: .xs, isEnabled: !logs.isEmpty) {
                            UIPasteboard.general.string = logs.map { formatLog($0) }.joined(separator: "\n")
                        }
                    }
                    .padding(.bottom, 12)

                    Picker("Source", selection: $source) {
                        ForEach(LogSource.allCases, id: \.self) { itm in
                            Text(itm.label)
                                .tag(itm)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.bottom, 12)

                    if logs.isEmpty {
                        InfoText(text: "No logs yet")
                    } else {
                        LogList(logs: Array(logs.suffix(maxVisibleLogs)))
                    }
                }

                if let info {
                    SectionCard {
                        SectionTitle(text: "Authentication callback")
                            .padding(.bottom, 8)

                        CopyText(value: info.authenticationCallbackURL)
                    }
                }
            }
        }
        .background(colors.app.ignoresSafeArea())
        .navigationTitle("Diagnostics")
        .toolbarRole(.editor)
        .toolbarBackground(colors.app, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task(id: source) {
            if source == .tunnel {
                tunnelLogs = await model.fetchTunnelLogs()
            }
        }
        .refreshable {
            await model.refreshAppStatus()
            await model.refreshTunnel()
            if source == .tunnel {
                tunnelLogs = await model.fetchTunnelLogs()
            }
        }
    }

    private func getAppBuild() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"

        return "\(version) (\(build))"
    }
}

private struct ClusterAPICheck: View {
    @Environment(AppModel.self) private var model

    let domain: String

    @State private var result: HostCheck?
    @State private var mutation = Mutation<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Mono(text: getClusterAPIHost(domain))
                    .frame(maxWidth: .infinity, alignment: .leading)

                OctButton(
                    text: "Check DNS",
                    variant: .default,
                    size: .xs,
                    isLoading: mutation.isPending
                ) {
                    mutation.mutate(domain) { domain in
                        result = await model.checkClusterAPIHost(domain)
                    }
                }
            }

            if let result {
                OctLabel(
                    text: getHostResolutionLabel(result.resolution),
                    tone: result.resolution == .resolved ? .emerald : .rose
                )

                if result.resolution == .resolved {
                    Mono(text: result.addresses.joined(separator: ", "))
                } else if let msg = getHostCheckError(result) {
                    InfoText(text: msg)
                }
            }
        }
    }
}

private struct LogList: View {
    @Environment(\.octColors) private var colors

    let logs: [Mobilev1.Log]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(Array(logs.reversed().enumerated()), id: \.offset) { _, itm in
                Text(formatLog(itm))
                    .font(.mono(11))
                    .foregroundStyle(getColor(itm.level))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(colors.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func getColor(_ level: Mobilev1.Log.Level) -> Color {
        switch level {
        case .error: Color(hex: 0xF43F5E)
        case .warn: Color(hex: 0xF59E0B)
        case .debug: colors.faint
        default: colors.body
        }
    }
}
