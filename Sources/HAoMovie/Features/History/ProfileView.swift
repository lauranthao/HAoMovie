import SwiftUI

/// “我的”页：继续观看、我的收藏、设置入口。全部只存本机。
struct ProfileView: View {
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var subscriptions: SubscriptionStore

    @State private var showSettings = false
    @State private var selectedFavorite: FavoriteEntry?

    var body: some View {
        NavigationStack {
            List {
                Section("继续观看") {
                    if history.history.isEmpty {
                        Text("还没有看过影片")
                            .foregroundStyle(HaoMovieDesign.textSecondary)
                    }
                    ForEach(history.history) { entry in
                        HStack(spacing: HaoMovieDesign.space12) {
                            AsyncPoster(urlString: entry.poster)
                                .frame(width: 56)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.vodName)
                                    .font(.system(size: 15, weight: .semibold))
                                    .lineLimit(1)
                                Text("\(entry.episodeTitle) · \(Int(entry.progress * 100))%")
                                    .font(.system(size: 12))
                                    .foregroundStyle(HaoMovieDesign.textSecondary)
                            }
                            Spacer()
                            if entry.isFinished {
                                Text("已看完")
                                    .font(.system(size: 12))
                                    .foregroundStyle(HaoMovieDesign.textSecondary)
                            }
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            history.removeHistory(history.history[index])
                        }
                    }
                    if !history.history.isEmpty {
                        Button("清空历史", role: .destructive) {
                            history.clearHistory()
                        }
                    }
                }

                Section("我的收藏") {
                    if history.favorites.isEmpty {
                        Text("还没有收藏")
                            .foregroundStyle(HaoMovieDesign.textSecondary)
                    }
                    ForEach(history.favorites) { fav in
                        Button {
                            selectedFavorite = fav
                        } label: {
                            HStack(spacing: HaoMovieDesign.space12) {
                                AsyncPoster(urlString: fav.poster)
                                    .frame(width: 56)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(fav.vodName)
                                        .font(.system(size: 15, weight: .semibold))
                                        .lineLimit(1)
                                    Text(fav.siteName)
                                        .font(.system(size: 12))
                                        .foregroundStyle(HaoMovieDesign.textSecondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section("订阅") {
                    HStack {
                        Text("已导入订阅")
                        Spacer()
                        Text("\(subscriptions.subscriptions.count) 个")
                            .foregroundStyle(HaoMovieDesign.textSecondary)
                    }
                    NavigationLink("管理订阅") {
                        SourcePickerView()
                    }
                }

                Section {
                    Button("设置") { showSettings = true }
                }
            }
            .navigationTitle("我的")
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(item: $selectedFavorite) { fav in
                // 收藏的直播频道（siteKey 为 m3u）没有详情页，直接播
                if fav.siteKey == "m3u" {
                    LiveFavoritePlayView(favorite: fav)
                } else {
                    FavoriteDetailView(favorite: fav)
                }
            }
        }
    }
}

/// 收藏影片的详情入口：按来源站点拉详情后进详情页。
struct FavoriteDetailView: View {
    var favorite: FavoriteEntry
    @EnvironmentObject private var subscriptions: SubscriptionStore

    @State private var detail: VodDetail?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let detail, let site = site {
                    VodDetailView(item: detail.item, site: site)
                } else if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(HaoMovieDesign.textSecondary)
                        .haoPagePadding()
                } else {
                    ProgressView()
                }
            }
            .task { await load() }
        }
    }

    private var site: TVBoxSite? {
        subscriptions.mergedSites.first { $0.key == favorite.siteKey }
    }

    private func load() async {
        guard let site else {
            errorMessage = "该收藏的来源已删除"
            return
        }
        do {
            detail = try await TVBoxClient.fetchDetail(site: site, vodId: favorite.vodId)
            if detail == nil { errorMessage = "没有找到该影片" }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 收藏的直播频道：直接播。
struct LiveFavoritePlayView: View {
    var favorite: FavoriteEntry
    @EnvironmentObject private var player: VideoPlayerService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Color.black.ignoresSafeArea()
            .onAppear {
                player.playLive(LiveChannel(name: favorite.vodName, logo: favorite.poster, group: favorite.siteName, url: favorite.vodId))
                dismiss()
            }
    }
}
