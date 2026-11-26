import SwiftUI

/// 四个页签（HAo 自己的排布）：片库 / 搜索 / 直播 / 我的。
/// 播放器以全屏 cover 弹出，退出后不自动恢复其他播放。
struct RootTabView: View {
    @EnvironmentObject private var player: VideoPlayerService
    @State private var showPlayer = false

    var body: some View {
        TabView {
            LibraryView()
                .tabItem { Label("片库", systemImage: "square.grid.2x2.fill") }
            SearchView()
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
            LiveView()
                .tabItem { Label("直播", systemImage: "dot.radiowaves.left.and.right") }
            ProfileView()
                .tabItem { Label("我的", systemImage: "person.fill") }
        }
        .onReceive(player.$state) { state in
            // 播放器从 idle 进入 loading 即弹出播放页（点播/直播统一入口）
            if state == .loading { showPlayer = true }
        }
        .fullScreenCover(isPresented: $showPlayer) {
            VideoPlayerView()
        }
    }
}
