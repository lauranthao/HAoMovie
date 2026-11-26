import SwiftUI

/// 详情页（HAo 自己的排布）：顶部 16:9 大图 + 渐变，标题与元信息，
/// 大红播放键在下，选集用数字格，线路用分段选择。
/// 顶部不是播放键——播放靠下面的大按钮与选集。
struct VodDetailView: View {
    var item: VodItem
    var site: TVBoxSite?

    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var player: VideoPlayerService
    @Environment(\.dismiss) private var dismiss

    @State private var detail: VodDetail?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedLine = 0
    @State private var showFullSynopsis = false

    private var savedProgress: HistoryEntry? {
        guard let site else { return nil }
        return history.progress(for: item.vodId, siteKey: site.key)
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                } else if let errorMessage {
                    errorView(errorMessage)
                } else if let detail {
                    detailContent(detail)
                }
            }
            .navigationTitle(item.vodName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { await loadDetail() }
        }
    }

    // MARK: - 内容

    private func detailContent(_ detail: VodDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HaoMovieDesign.space16) {
                // 顶部大图 + 渐变
                ZStack(alignment: .bottomLeading) {
                    AsyncPoster(urlString: item.vodPic, ratio: HaoMovieDesign.backdropRatio)
                        .frame(maxWidth: .infinity)
                    LinearGradient(
                        colors: [.clear, Color.black.opacity(0.55)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .aspectRatio(HaoMovieDesign.backdropRatio, contentMode: .fit)
                    VStack(alignment: .leading, spacing: HaoMovieDesign.space4) {
                        Text(item.vodName)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                        Text(metaLine)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(HaoMovieDesign.space16)
                }

                VStack(alignment: .leading, spacing: HaoMovieDesign.space16) {
                    // 大播放键 + 收藏
                    HStack(spacing: HaoMovieDesign.space12) {
                        Button(action: playFirst) {
                            Label(playButtonTitle, systemImage: "play.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, HaoMovieDesign.space12)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(HaoMovieDesign.accent)
                        Button(action: toggleFavorite) {
                            Image(systemName: isFavorite ? "heart.fill" : "heart")
                                .font(.system(size: 20))
                                .foregroundStyle(isFavorite ? HaoMovieDesign.accent : HaoMovieDesign.textPrimary)
                                .frame(width: 48, height: 48)
                                .background(HaoMovieDesign.surface, in: RoundedRectangle(cornerRadius: HaoMovieDesign.cardRadius))
                        }
                    }

                    // 简介（可展开）
                    if !item.vodContent.isEmpty {
                        VStack(alignment: .leading, spacing: HaoMovieDesign.space4) {
                            Text(item.vodContent)
                                .font(.system(size: 14))
                                .foregroundStyle(HaoMovieDesign.textSecondary)
                                .lineLimit(showFullSynopsis ? nil : 3)
                            Button(showFullSynopsis ? "收起" : "展开") {
                                showFullSynopsis.toggle()
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(HaoMovieDesign.accent)
                        }
                    }

                    // 线路切换
                    if detail.playLines.count > 1 {
                        VStack(alignment: .leading, spacing: HaoMovieDesign.space8) {
                            Text("播放线路")
                                .font(.system(size: 15, weight: .semibold))
                            Picker("线路", selection: $selectedLine) {
                                ForEach(detail.playLines.indices, id: \.self) { index in
                                    Text(detail.playLines[index].name).tag(index)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                    }

                    // 选集
                    if let line = currentLine(detail) {
                        VStack(alignment: .leading, spacing: HaoMovieDesign.space8) {
                            Text("选集（\(line.episodes.count)）")
                                .font(.system(size: 15, weight: .semibold))
                            LazyVGrid(columns: episodeColumns, spacing: HaoMovieDesign.space8) {
                                ForEach(line.episodes.indices, id: \.self) { index in
                                    Button(line.episodes[index].title) {
                                        playEpisode(line: selectedLine, episode: index)
                                    }
                                    .font(.system(size: 13, weight: .semibold))
                                    .padding(.vertical, HaoMovieDesign.space8)
                                    .frame(maxWidth: .infinity)
                                    .background(
                                        isCurrentEpisode(index) ? HaoMovieDesign.accent : HaoMovieDesign.surface,
                                        in: RoundedRectangle(cornerRadius: HaoMovieDesign.chipRadius)
                                    )
                                    .foregroundStyle(isCurrentEpisode(index) ? .white : HaoMovieDesign.textPrimary)
                                    .lineLimit(1)
                                }
                            }
                        }
                    }
                }
                .haoPagePadding()
            }
            .padding(.bottom, HaoMovieDesign.space24)
        }
    }

    private var episodeColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: HaoMovieDesign.space8), count: 5)
    }

    private var metaLine: String {
        [item.typeName, item.vodYear, item.vodArea, item.vodRemarks]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private var playButtonTitle: String {
        if let saved = savedProgress, saved.position > 10, !saved.isFinished {
            return "从 \(formatTime(saved.position)) 继续"
        }
        return "播放"
    }

    private var isFavorite: Bool {
        guard let site else { return false }
        return history.isFavorite(vodId: item.vodId, siteKey: site.key)
    }

    private func currentLine(_ detail: VodDetail) -> VodPlayLine? {
        guard selectedLine < detail.playLines.count else { return detail.playLines.first }
        return detail.playLines[selectedLine]
    }

    private func isCurrentEpisode(_ index: Int) -> Bool {
        guard let saved = savedProgress else { return false }
        return saved.episodeIndex == index && saved.lineIndex == selectedLine
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: HaoMovieDesign.space16) {
            Text("详情加载失败")
                .font(.system(size: 17, weight: .semibold))
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(HaoMovieDesign.textSecondary)
            Button("重试") { Task { await loadDetail() } }
                .buttonStyle(.borderedProminent)
                .tint(HaoMovieDesign.accent)
        }
        .haoPagePadding()
    }

    // MARK: - 动作

    private func loadDetail() async {
        guard let site else {
            isLoading = false
            errorMessage = "未知来源"
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            if let fetched = try await TVBoxClient.fetchDetail(site: site, vodId: item.vodId) {
                detail = fetched
                if let saved = savedProgress, saved.lineIndex < fetched.playLines.count {
                    selectedLine = saved.lineIndex
                }
            } else {
                errorMessage = "没有找到该影片"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func playFirst() {
        guard let detail, let site else { return }
        let resume = savedProgress?.position ?? 0
        let episode = savedProgress?.episodeIndex ?? 0
        player.play(detail: detail, site: site, lineIndex: selectedLine, episodeIndex: episode, resumePosition: resume)
        dismiss()
    }

    private func playEpisode(line: Int, episode: Int) {
        guard let detail, let site else { return }
        player.play(detail: detail, site: site, lineIndex: line, episodeIndex: episode, resumePosition: 0)
        dismiss()
    }

    private func toggleFavorite() {
        guard let site else { return }
        history.toggleFavorite(vodId: item.vodId, siteKey: site.key, siteName: site.name, vodName: item.vodName, poster: item.vodPic)
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds)
        let minutes = total / 60
        let secs = total % 60
        if minutes >= 60 {
            return String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
