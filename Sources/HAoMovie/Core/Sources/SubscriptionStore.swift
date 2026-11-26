import Foundation

/// 订阅管理：导入（URL / 粘贴 JSON）、启用停用、失败冷却。
/// 多个订阅合并使用；每个订阅下的站点按 key 去重（同 key 只留第一个）。
@MainActor
final class SubscriptionStore: ObservableObject {
    @Published private(set) var subscriptions: [TVBoxSubscription] = []
    /// 订阅 id → 该订阅拉到的站点（JSON 源 only）
    @Published private(set) var sitesBySubscription: [UUID: [TVBoxSite]] = [:]
    /// 订阅 id → 分类（懒加载后缓存）
    @Published private(set) var categoriesBySite: [String: [TVBoxSiteClass]] = [:]

    private let subscriptionsKey = "hao_movie_subscriptions"
    private let sitesKey = "hao_movie_sites"

    init() {
        subscriptions = LocalStore.load([TVBoxSubscription].self, key: subscriptionsKey) ?? []
        sitesBySubscription = LocalStore.load([UUID: [TVBoxSite]].self, key: sitesKey) ?? [:]
    }

    /// 所有启用订阅下的站点，去重后按订阅顺序排；冷却中的订阅排后。
    var mergedSites: [TVBoxSite] {
        var seen: Set<String> = []
        var result: [TVBoxSite] = []
        let ordered = subscriptions
            .filter { $0.enabled }
            .sorted { lhs, rhs in
                // 冷却中的排后
                if lhs.isCoolingDown != rhs.isCoolingDown { return !lhs.isCoolingDown }
                return lhs.createdAt < rhs.createdAt
            }
        for sub in ordered {
            for site in sitesBySubscription[sub.id] ?? [] {
                guard !seen.contains(site.key) else { continue }
                seen.insert(site.key)
                result.append(site)
            }
        }
        return result
    }

    var hasAnySubscription: Bool { !subscriptions.isEmpty }

    /// 从 URL 导入订阅 JSON。返回导入的站点数。
    @discardableResult
    func importFromURL(_ urlString: String, name: String? = nil) async throws -> Int {
        let sites = try await TVBoxClient.fetchSubscription(apiURL: urlString)
        let sub = TVBoxSubscription(name: name ?? hostName(of: urlString), apiURL: urlString)
        add(subscription: sub, sites: sites)
        return sites.count
    }

    /// 从粘贴的 JSON 文本导入。
    @discardableResult
    func importFromText(_ text: String, name: String) throws -> Int {
        guard let data = text.data(using: .utf8) else { throw TVBoxClient.ClientError.emptyResponse }
        let sites = try TVBoxParsing.parseSubscription(data).filter { $0.isSupported }
        let sub = TVBoxSubscription(name: name, apiURL: "pasted")
        add(subscription: sub, sites: sites)
        return sites.count
    }

    func remove(_ subscription: TVBoxSubscription) {
        subscriptions.removeAll { $0.id == subscription.id }
        sitesBySubscription.removeValue(forKey: subscription.id)
        persist()
    }

    func setEnabled(_ subscription: TVBoxSubscription, enabled: Bool) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) else { return }
        subscriptions[index].enabled = enabled
        persist()
    }

    /// 记一次拉取失败：冷却 10 分钟（搜索与浏览时该订阅排后）。
    func markFailure(_ subscription: TVBoxSubscription) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) else { return }
        subscriptions[index].lastFailureAt = Date()
        persist()
    }

    func markFailure(site: TVBoxSite) {
        guard let sub = subscriptions.first(where: { sitesBySubscription[$0.id]?.contains(site) == true }) else { return }
        markFailure(sub)
    }

    /// 懒加载某站点的分类（带内存缓存）。
    func categories(for site: TVBoxSite) async -> [TVBoxSiteClass] {
        if let cached = categoriesBySite[site.key], !cached.isEmpty { return cached }
        do {
            let list = try await TVBoxClient.fetchCategories(site: site)
            categoriesBySite[site.key] = list
            return list
        } catch {
            markFailure(site: site)
            return []
        }
    }

    private func add(subscription: TVBoxSubscription, sites: [TVBoxSite]) {
        subscriptions.append(subscription)
        sitesBySubscription[subscription.id] = sites
        persist()
    }

    private func persist() {
        LocalStore.save(subscriptions, key: subscriptionsKey)
        LocalStore.save(sitesBySubscription, key: sitesKey)
    }

    private func hostName(of urlString: String) -> String {
        URL(string: urlString)?.host ?? "订阅"
    }
}
