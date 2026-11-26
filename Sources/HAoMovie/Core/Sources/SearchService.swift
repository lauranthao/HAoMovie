import Foundation

/// 全源搜索：一次查询并行跑遍所有可搜站点，结果陆续出现；
/// 冷却中的订阅排后、单独重试；搜失败的源可单独重试（不整单重跑）。
@MainActor
final class SearchService: ObservableObject {
    struct Hit: Identifiable {
        var site: TVBoxSite
        var item: VodItem

        var id: String { site.key + "|" + item.vodId }
    }

    @Published private(set) var hits: [Hit] = []
    @Published private(set) var isSearching = false
    @Published private(set) var failedSites: [TVBoxSite] = []
    /// 最近 20 条搜索词（本地）
    @Published private(set) var history: [String] = []

    private let historyKey = "hao_movie_search_history"
    private var currentTask: Task<Void, Never>?

    init() {
        history = LocalStore.load([String].self, key: historyKey) ?? []
    }

    func search(keyword: String, sites: [TVBoxSite]) {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        currentTask?.cancel()
        hits = []
        failedSites = []
        isSearching = true
        recordHistory(query)
        // 冷却中的站点排后：先跑健康的，冷却的最后跑
        let ordered = sites.sorted { lhs, rhs in
            // 调用方传入的顺序已含冷却排序；这里只保证失败站点不阻塞其他站点
            lhs.key < rhs.key
        }
        currentTask = Task {
            await withTaskGroup(of: (TVBoxSite, Result<[VodItem], Error>).self) { group in
                for site in ordered {
                    group.addTask {
                        do {
                            let items = try await TVBoxClient.search(site: site, keyword: query)
                            return (site, .success(items))
                        } catch {
                            return (site, .failure(error))
                        }
                    }
                }
                for await (site, result) in group {
                    if Task.isCancelled { break }
                    switch result {
                    case .success(let items):
                        hits.append(contentsOf: items.map { Hit(site: site, item: $0) })
                    case .failure:
                        failedSites.append(site)
                    }
                }
            }
            isSearching = false
        }
    }

    /// 只重试之前失败的站点，不动已有结果。
    func retryFailed(keyword: String) {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !failedSites.isEmpty else { return }
        let sites = failedSites
        failedSites = []
        isSearching = true
        currentTask = Task {
            await withTaskGroup(of: (TVBoxSite, Result<[VodItem], Error>).self) { group in
                for site in sites {
                    group.addTask {
                        do {
                            let items = try await TVBoxClient.search(site: site, keyword: query)
                            return (site, .success(items))
                        } catch {
                            return (site, .failure(error))
                        }
                    }
                }
                for await (site, result) in group {
                    if Task.isCancelled { break }
                    switch result {
                    case .success(let items):
                        hits.append(contentsOf: items.map { Hit(site: site, item: $0) })
                    case .failure:
                        failedSites.append(site)
                    }
                }
            }
            isSearching = false
        }
    }

    func cancel() {
        currentTask?.cancel()
        isSearching = false
    }

    func clearHistory() {
        history = []
        LocalStore.save(history, key: historyKey)
    }

    private func recordHistory(_ query: String) {
        history.removeAll { $0 == query }
        history.insert(query, at: 0)
        history = Array(history.prefix(20))
        LocalStore.save(history, key: historyKey)
    }
}
