import OcteliumAPI
import OcteliumCore
import OcteliumProto
import SwiftUI

struct ServicesView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigation.self) private var navigation

    var body: some View {
        let state = getDomainState(model.status, model.selectedDomain)

        if let domain = model.selectedDomain, isAuthenticated(state) {
            ServiceList(domain: domain, state: state)
                .id(domain)
        } else {
            ScreenScroll {
                EmptyState(
                    title: model.selectedDomain.map { "Sign in to \($0)" } ?? "Set up your Cluster",
                    message: model.selectedDomain == nil
                        ? "Add your primary domain to browse the Services available to you."
                        : "The Cluster resources are read directly from the Cluster API using your Session.",
                    icon: model.selectedDomain == nil ? "shield" : "person.crop.circle.badge.plus"
                ) {
                    OctButton(text: model.selectedDomain == nil ? "Get started" : "Sign in again") {
                        navigation.tab = .connection
                    }
                }
            }
        }
    }
}

private struct ServiceList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.octColors) private var colors

    let domain: String
    let state: Daemonv1.DomainState?

    @State private var services: ServicesModel?
    @State private var search = ""

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                DomainOperationBanner(state: state)

                PageHeader(title: "Services", description: "The Services you are authorized to access at \(domain)")

                if !isConnected(state) {
                    Notice(
                        title: "Not connected",
                        content: "You can browse the Services of the Cluster while disconnected. Connect in order to actually reach them from this device."
                    )
                    .padding(.bottom, 10)
                }

                if let services {
                    filters(services)
                    content(services)
                }

                Footer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search the Services")
        .onChange(of: search) { _, new in
            services?.setSearch(new)
        }
        .refreshable {
            await services?.refresh()
        }
        .onAppear {
            if services == nil {
                let ret = ServicesModel(cluster: model.cluster, domain: domain)
                services = ret
                ret.start()
            }
        }
    }

    private func filters(_ services: ServicesModel) -> some View {
        HStack(spacing: 12) {
            SelectField(
                options: services.namespaces.map { SelectOption(value: $0.metadata.name, label: $0.metadata.name) },
                value: services.filter.namespace,
                label: "Namespace",
                placeholder: "Every Namespace",
                isClearable: true
            ) {
                services.setNamespace($0)
            }

            SelectField(
                options: serviceTypes.map { SelectOption(value: $0.key, label: $0.label) },
                value: services.filter.typeKey,
                label: "Type",
                placeholder: "Every type",
                isClearable: true
            ) {
                services.setType($0)
            }
        }
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func content(_ services: ServicesModel) -> some View {
        let tokens = tokenizeQuery(services.filter.search)

        if services.isLoading {
            ResourceListSkeleton()
        } else if let err = services.error, services.items.isEmpty {
            ErrorState(
                title: "Unable to load the Services",
                message: "The Cluster API could not be reached. Check that you are still signed in. \(err)"
            ) {
                Task {
                    await services.refresh()
                }
            }
        } else if services.items.isEmpty {
            EmptyState(
                title: tokens.isEmpty ? "No Service" : "Nothing found",
                message: tokens.isEmpty
                    ? "You are not authorized to access any Service yet."
                    : "No Service matches your search in this Cluster.",
                icon: "magnifyingglass"
            )
        } else {
            ForEach(services.items, id: \.metadata.name) { itm in
                ServiceItem(item: itm, domain: domain)
                    .onAppear {
                        if itm.metadata.name == services.items.last?.metadata.name {
                            services.loadMore()
                        }
                    }
            }

            if services.isLoadingMore {
                ProgressView()
                    .tint(colors.muted)
                    .frame(maxWidth: .infinity)
                    .padding(12)
            }
        }
    }
}

private struct ServiceItem: View {
    @Environment(\.octColors) private var colors
    @Environment(\.openURL) private var openURL

    let item: Userv1.Service
    let domain: String

    @State private var isExpanded = false

    var body: some View {
        let typeInfo = getServiceTypeInfo(item)
        let typeStyle = getServiceTypeStyle(item.spec.type)
        let (name, namespace) = splitServiceName(item.metadata.name)

        SectionCard(padding: 16) {
            Button {
                withAnimation(.snappy) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: typeStyle.icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(colors.isDark ? Color(hex: 0x334155) : Color(hex: 0x18181B), in: Circle())
                        .overlay(
                            Circle().strokeBorder(
                                colors.isDark ? Color(hex: 0x475569) : Color(hex: 0x3F3F46, alpha: 0.8),
                                lineWidth: 1
                            )
                        )
                        .accessibilityLabel("\(typeInfo.label) service")

                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {
                            Text(name)
                                .font(.ubuntu(15, .bold))
                                .foregroundStyle(colors.strong)
                                .lineLimit(1)

                            if let namespace {
                                Text(".")
                                    .font(.ubuntu(15, .medium))
                                    .foregroundStyle(colors.faint)
                                Text(namespace)
                                    .font(.ubuntu(15, .medium))
                                    .foregroundStyle(colors.muted)
                                    .lineLimit(1)
                            }
                        }

                        if !item.metadata.displayName.isEmpty {
                            Text(item.metadata.displayName)
                                .font(.ubuntu(14, .medium))
                                .foregroundStyle(colors.muted)
                                .lineLimit(1)
                                .padding(.top, 2)
                        }

                        FlowLayout(spacing: 6) {
                            OctLabel(text: typeInfo.label, toneColors: typeStyle.palette.getColors(colors.isDark))
                            OctLabel(text: String(item.spec.port), tone: .slate, prefix: "Port")

                            if item.spec.isTls {
                                OctLabel(text: "TLS", tone: .emerald, icon: "checkmark.shield")
                            }

                            if item.spec.isPublic {
                                OctLabel(text: "Public", tone: .sky, icon: "globe")
                            }

                            OctLabel(text: getServiceHostname(item), tone: .neutral, isMono: true)
                        }
                        .padding(.top, 8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(colors.faint)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .padding(8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Hide the details" : "Show the details")

            if item.spec.isPublic && isServiceWebBrowsable(item) {
                OctButton(text: "Open", icon: "arrow.up.right", variant: .outline, size: .xs) {
                    if let url = URL(string: getServicePublicURL(item, domain)) {
                        openURL(url)
                    }
                }
                .padding(.top, 12)
            }

            if isExpanded {
                ServiceDetails(item: item, domain: domain)
                    .padding(.top, 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private struct ServiceDetails: View {
    @Environment(\.octColors) private var colors

    let item: Userv1.Service
    let domain: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !item.metadata.description_p.isEmpty {
                Text(item.metadata.description_p)
                    .font(.ubuntu(14, .medium))
                    .foregroundStyle(colors.body)
            }

            InfoItem(title: "Private FQDN") {
                CopyText(value: getServicePrivateFQDN(item, domain))
            }

            if item.spec.isPublic {
                InfoItem(title: "Public FQDN") {
                    CopyText(value: getServicePublicFQDN(item, domain))
                }
            }

            InfoItem(title: "Resource name") {
                CopyText(value: item.metadata.name)
            }

            if !item.status.addresses.isEmpty {
                InfoItem(title: "Private addresses") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(item.status.addresses, id: \.self) { itm in
                            CopyText(value: itm)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(colors.line, lineWidth: 1))
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = getRows(proposal.width ?? .infinity, subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))

        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY

        for row in getRows(bounds.width, subviews) {
            var x = bounds.minX
            for idx in row.indices {
                let size = subviews[idx].sizeThatFits(.unspecified)
                let width = min(size.width, bounds.width)
                subviews[idx].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: width, height: size.height)
                )
                x += width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func getRows(_ maxWidth: CGFloat, _ subviews: Subviews) -> [Row] {
        var ret: [Row] = []
        var cur = Row()

        for idx in subviews.indices {
            let size = subviews[idx].sizeThatFits(.unspecified)
            let width = min(size.width, maxWidth)
            let next = cur.indices.isEmpty ? width : cur.width + spacing + width

            if next > maxWidth && !cur.indices.isEmpty {
                ret.append(cur)
                cur = Row()
                cur.indices = [idx]
                cur.width = width
                cur.height = size.height
                continue
            }

            cur.indices.append(idx)
            cur.width = next
            cur.height = max(cur.height, size.height)
        }

        if !cur.indices.isEmpty {
            ret.append(cur)
        }

        return ret
    }
}
