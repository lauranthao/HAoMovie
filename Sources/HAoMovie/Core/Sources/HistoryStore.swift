import Foundation

/// 播放历史与收藏（本地）。播放失败不回写进度，旧进度保留。
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var history: [HistoryEntry] = []
    @Published private(set) var favorites: [FavoriteEntry] = []

    private let historyKey = "hao_movie_history"
    private let favoritesKey = "hao_movie_favorites"
    private let maxHistory = 100

    init() {
        history = LocalStore.load([HistoryEntry].self, key: historyKey) ?? []
        favorites = LocalStore.load([FavoriteEntry].self, key: favoritesKey) ?? []
    }

    /// 继续观看：按更新时间倒序，未看完的在前。
    var continueWatching: [HistoryEntry] {
        history
            .filter { !$0.isFinished }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func recordProgress(
        vodId: String, siteKey: String, siteName: String, vodName: String, poster: String,
        episodeTitle: String, episodeIndex: Int, lineIndex: Int,
        position: Double, duration: Double
    ) {
        let id = siteKey + "|" + vodId
        var entry = history.first { $0.id == id } ?? HistoryEntry(
            vodId: vodId, siteKey: siteKey, siteName: siteName, vodName: vodName, poster: poster,
            episodeTitle: episodeTitle, episodeIndex: episodeIndex, lineIndex: lineIndex,
            position: 0, duration: 0, updatedAt: Date()
        )
        entry.episodeTitle = episodeTitle
        entry.episodeIndex = episodeIndex
        entry.lineIndex = lineIndex
        entry.position = position
        entry.duration = duration
        entry.updatedAt = Date()
        history.removeAll { $0.id == id }
        history.insert(entry, at: 0)
        history = Array(history.prefix(maxHistory))
        LocalStore.save(history, key: historyKey)
    }

    func progress(for vodId: String, siteKey: String) -> HistoryEntry? {
        history.first { $0.id == siteKey + "|" + vodId }
    }

    func removeHistory(_ entry: HistoryEntry) {
        history.removeAll { $0.id == entry.id }
        LocalStore.save(history, key: historyKey)
    }

    func clearHistory() {
        history = []
        LocalStore.save(history, key: historyKey)
    }

    func isFavorite(vodId: String, siteKey: String) -> Bool {
        favorites.contains { $0.id == siteKey + "|" + vodId }
    }

    func toggleFavorite(vodId: String, siteKey: String, siteName: String, vodName: String, poster: String) {
        let id = siteKey + "|" + vodId
        if let index = favorites.firstIndex(where: { $0.id == id }) {
            favorites.remove(at: index)
        } else {
            favorites.insert(
                FavoriteEntry(vodId: vodId, siteKey: siteKey, siteName: siteName, vodName: vodName, poster: poster, addedAt: Date()),
                at: 0
            )
        }
        LocalStore.save(favorites, key: favoritesKey)
    }
}
