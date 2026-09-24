import OcteliumCore

struct ServiceTypeStyle {
    let icon: String
    let palette: Palette
}

func getServiceTypeStyle(_ type: ServiceType) -> ServiceTypeStyle {
    switch type {
    case .web: ServiceTypeStyle(icon: "macwindow", palette: .sky)
    case .http: ServiceTypeStyle(icon: "globe", palette: .blue)
    case .grpc: ServiceTypeStyle(icon: "point.3.connected.trianglepath.dotted", palette: .violet)
    case .ssh: ServiceTypeStyle(icon: "terminal", palette: .slate)
    case .kubernetes: ServiceTypeStyle(icon: "helm", palette: .indigo)
    case .postgres: ServiceTypeStyle(icon: "cylinder.split.1x2", palette: .cyan)
    case .mysql: ServiceTypeStyle(icon: "cylinder", palette: .amber)
    case .tcp: ServiceTypeStyle(icon: "cable.connector", palette: .teal)
    case .udp: ServiceTypeStyle(icon: "antenna.radiowaves.left.and.right", palette: .emerald)
    case .dns: ServiceTypeStyle(icon: "signpost.right", palette: .green)
    case .socks5: ServiceTypeStyle(icon: "arrow.triangle.branch", palette: .fuchsia)
    case .rdpWeb, .rdp: ServiceTypeStyle(icon: "desktopcomputer", palette: .rose)
    case .llm: ServiceTypeStyle(icon: "brain", palette: .purple)
    case .mcp: ServiceTypeStyle(icon: "puzzlepiece.extension", palette: .orange)
    default: ServiceTypeStyle(icon: "server.rack", palette: .slate)
    }
}
