import Foundation
import Observation
import OcteliumCore
import OcteliumProto

public let servicesPerPage = 50
public let servicesSearchDebounce: Duration = .milliseconds(250)
public let servicesSearchStaleTime: TimeInterval = 30

public struct ServicesFilter: Equatable, Sendable {
    public var search = ""
    public var namespace: String?
    public var typeKey: String?

    public init(search: String = "", namespace: String? = nil, typeKey: String? = nil) {
        self.search = search
        self.namespace = namespace
        self.typeKey = typeKey
    }
}

private struct AllServices {
    let namespace: String
    let type: ServiceType
    let items: [Userv1.Service]
    let fetchedAt: Date
}

@MainActor
@Observable
public final class ServicesModel {
    public private(set) var filter = ServicesFilter()
    public private(set) var items: [Userv1.Service] = []
    public private(set) var namespaces: [Userv1.Namespace] = []
    public private(set) var isLoading = true
    public private(set) var isLoadingMore = false
    public private(set) var error: String?
    public private(set) var hasMore = false

    @ObservationIgnored private let cluster: ClusterClient
    @ObservationIgnored private let domain: String
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var nextPage = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var allServices: AllServices?
    @ObservationIgnored private var isStarted = false

    public init(cluster: ClusterClient, domain: String, now: @escaping () -> Date = { Date() }) {
        self.cluster = cluster
        self.domain = domain
        self.now = now
    }

    public func start() {
        if isStarted {
            return
        }

        isStarted = true
        load(debounce: false)

        Task {
            do {
                namespaces = try await cluster.listAllNamespaces(domain)
            } catch {
                namespaces = []
            }
        }
    }

    public func setSearch(_ arg: String) {
        if arg == filter.search {
            return
        }

        filter.search = arg
        load(debounce: true)
    }

    public func setNamespace(_ arg: String?) {
        filter.namespace = arg
        load(debounce: false)
    }

    public func setType(_ arg: String?) {
        filter.typeKey = arg
        load(debounce: false)
    }

    public func refresh() async {
        task?.cancel()
        let task = Task {
            await fetch(filter, debounce: false)
        }
        self.task = task
        await task.value
    }

    public func loadMore() {
        if isLoading || isLoadingMore || !hasMore {
            return
        }

        isLoadingMore = true
        let page = nextPage
        let filter = self.filter

        task = Task {
            do {
                let resp = try await listPage(filter, page)
                if Task.isCancelled {
                    return
                }

                items += resp.items
                hasMore = resp.listResponseMeta.hasMore_p && !resp.items.isEmpty
                nextPage = page + 1
            } catch is CancellationError {
            } catch {
                self.error = getErrorMessage(error)
            }

            isLoadingMore = false
        }
    }

    private func load(debounce: Bool) {
        task?.cancel()
        isLoadingMore = false

        if let ret = getCachedSearch(filter) {
            items = ret
            isLoading = false
            hasMore = false
            error = nil
            return
        }

        isLoading = true
        error = nil

        let filter = self.filter
        task = Task {
            await fetch(filter, debounce: debounce)
        }
    }

    private func fetch(_ filter: ServicesFilter, debounce: Bool) async {
        if debounce {
            do {
                try await Task.sleep(for: servicesSearchDebounce)
            } catch {
                return
            }
        }

        let tokens = tokenizeQuery(filter.search)

        do {
            if !tokens.isEmpty {
                let ret = try await listAllServices(filter).filter { matchesService($0, tokens) }
                if Task.isCancelled {
                    return
                }

                items = ret
                hasMore = false
                nextPage = 0
            } else {
                let resp = try await listPage(filter, 0)
                if Task.isCancelled {
                    return
                }

                items = resp.items
                hasMore = resp.listResponseMeta.hasMore_p && !resp.items.isEmpty
                nextPage = 1
            }

            error = nil
            isLoading = false
        } catch is CancellationError {
        } catch {
            if Task.isCancelled {
                return
            }

            self.error = getErrorMessage(error)
            isLoading = false
        }
    }

    private func getCachedSearch(_ filter: ServicesFilter) -> [Userv1.Service]? {
        let tokens = tokenizeQuery(filter.search)

        guard let ret = allServices, !tokens.isEmpty,
              ret.namespace == (filter.namespace ?? ""),
              ret.type == getServiceType(filter),
              now().timeIntervalSince(ret.fetchedAt) < servicesSearchStaleTime else {
            return nil
        }

        return ret.items.filter { matchesService($0, tokens) }
    }

    private func listAllServices(_ filter: ServicesFilter) async throws -> [Userv1.Service] {
        let namespace = filter.namespace ?? ""
        let type = getServiceType(filter)

        let ret = try await cluster.listAllServices(domain, namespace: namespace, type: type)
        allServices = AllServices(namespace: namespace, type: type, items: ret, fetchedAt: now())

        return ret
    }

    private func getServiceType(_ filter: ServicesFilter) -> ServiceType {
        getServiceTypeByKey(filter.typeKey)?.type ?? .unset
    }

    private func listPage(_ filter: ServicesFilter, _ page: Int) async throws -> Userv1.ServiceList {
        var options = Userv1.ListServiceOptions()
        options.common = getCommonListOptions(page, servicesPerPage)
        options.namespace = filter.namespace ?? ""
        options.type = getServiceType(filter)

        return try await cluster.listService(domain, options)
    }
}
