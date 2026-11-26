import SwiftUI

/// 直播：M3U / M3U8 播放列表，按分组浏览、频道搜索、收藏。
/// 列表地址由用户在设置里自填；不填则不显示任何频道。
struct LiveView: View {
    @EnvironmentObject private var player: VideoPlayerService
    @EnvironmentObject private var history: HistoryStore

    @State private var groups: [LiveGroup] = []
    @State private var selectedGroup: String?
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var m3uText = ""
    @State private var favoritesOnly = false

    private var visibleChannels: [LiveChannel] {
        let base: [LiveChannel]
        if let selectedGroup, let group = groups.first(where: { $0.name == selectedGroup }) {
            base = group.channels
        } else {
            base = groups.flatMap { $0.channels }
        }
        let searched = searchText.isEmpty ? base : base.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        guard favoritesOnly else { return searched }
        return searched.filter { isChannelFavorite($0) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if player.settings.m3uURL.trimmingCharacters(in: .whitespaces).isEmpty {
                    emptyState
                } else if isLoading && groups.isEmpty {
                    ProgressView()
                } else if let errorMessage, groups.isEmpty {
                    errorView(errorMessage)
                } else {
                    content
                }
            }
            .navigationTitle("直播")
            .task { await loadIfNeeded() }
        }
    }

    // MARK: - 空态 / 错误

    private var emptyState: some View {
        VStack(spacing: HaoMovieDesign.space16) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 48))
                .foregroundStyle(HaoMovieDesign.textSecondary)
            Text("还没有直播列表")
                .font(.system(size: 17, weight: .semibold))
            Text("在设置里填入 M3U 播放列表地址即可看直播。")
                .font(.system(size: 14))
                .foregroundStyle(HaoMovieDesign.textSecondary)
                .multilineTextAlignment(.center)
            HStack {
                TextField("https://…/playlist.m3u", text: $m3uText)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                Button("保存") {
                    player.settings.m3uURL = m3uText.trimmingCharacters(in: .whitespaces)
                    LocalStore.save(player.settings, key: "hao_movie_settings")
                    Task { await loadIfNeeded(force: true) }
                }
                .disabled(m3uText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(HaoMovieDesign.space12)
            .background(HaoMovieDesign.surface, in: RoundedRectangle(cornerRadius: HaoMovieDesign.cardRadius))
            .haoPagePadding()
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: HaoMovieDesign.space16) {
            Text("直播列表加载失败")
                .font(.system(size: 17, weight: .semibold))
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(HaoMovieDesign.textSecondary)
            Button("重试") { Task { await loadIfNeeded(force: true) } }
                .buttonStyle(.borderedProminent)
                .tint(HaoMovieDesign.accent)
        }
        .haoPagePadding()
    }

    // MARK: - 内容

    private var content: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("搜频道", text: $searchText)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                Toggle("只看收藏", isOn: $favoritesOnly)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, HaoMovieDesign.space16)
            .padding(.vertical, HaoMovieDesign.space8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HaoMovieDesign.space8) {
                    groupChip(name: nil, label: "全部")
                    ForEach(groups) { group in
                        groupChip(name: group.name, label: group.name)
                    }
                }
                .padding(.horizontal, HaoMovieDesign.space16)
            }
            .padding(.bottom, HaoMovieDesign.space8)

            List(visibleChannels) { channel in
                Button { player.playLive(channel) } label: {
                    HStack(spacing: HaoMovieDesign.space12) {
                        ZStack {
                            HaoMovieDesign.surface
                            Image(systemName: "tv.fill")
                                .foregroundStyle(HaoMovieDesign.textSecondary)
                        }
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: HaoMovieDesign.chipRadius))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(channel.name)
                                .font(.system(size: 15, weight: .semibold))
                                .lineLimit(1)
                            Text(channel.group)
                                .font(.system(size: 12))
                                .foregroundStyle(HaoMovieDesign.textSecondary)
                        }
                        Spacer()
                        Button {
                            toggleChannelFavorite(channel)
                        } label: {
                            Image(systemName: isChannelFavorite(channel) ? "star.fill" : "star")
                                .foregroundStyle(isChannelFavorite(channel) ? HaoMovieDesign.accent : HaoMovieDesign.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }

    private func groupChip(name: String?, label: String) -> some View {
        Button(label) { selectedGroup = name }
            .padding(.horizontal, HaoMovieDesign.space12)
            .padding(.vertical, 6)
            .background(
                selectedGroup == name ? HaoMovieDesign.accent : HaoMovieDesign.surface,
                in: Capsule()
            )
            .foregroundStyle(selectedGroup == name ? .white : HaoMovieDesign.textPrimary)
            .font(.system(size: 13, weight: .semibold))
    }

    // MARK: - 数据

    private func loadIfNeeded(force: Bool = false) async {
        let url = player.settings.m3uURL.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        guard force || groups.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        do {
            groups = try await TVBoxClient.fetchM3U(urlString: url)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func isChannelFavorite(_ channel: LiveChannel) -> Bool {
        history.isFavorite(vodId: channel.url, siteKey: "m3u")
    }

    private func toggleChannelFavorite(_ channel: LiveChannel) {
        history.toggleFavorite(vodId: channel.url, siteKey: "m3u", siteName: channel.group, vodName: channel.name, poster: channel.logo)
    }
}
