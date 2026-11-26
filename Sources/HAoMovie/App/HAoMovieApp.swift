import SwiftUI

/// 入口：无启动动画，直接进主界面（chen 2026-11-26 决定：三个应用都不要启动动画）。
/// 订阅 → 搜索/历史 → 播放器的依赖链在这里组装。
@main
struct HAoMovieApp: App {
    @StateObject private var subscriptionStore = SubscriptionStore()
    @StateObject private var historyStore = HistoryStore()
    @StateObject private var searchService = SearchService()
    @StateObject private var playerService: VideoPlayerService

    init() {
        // 偏好只存本机；播放器持有同一份设置对象，设置页直接改它。
        let settings = LocalStore.load(MovieSettings.self, key: "hao_movie_settings") ?? MovieSettings()
        _playerService = StateObject(wrappedValue: VideoPlayerService(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(subscriptionStore)
                .environmentObject(historyStore)
                .environmentObject(searchService)
                .environmentObject(playerService)
        }
    }
}
