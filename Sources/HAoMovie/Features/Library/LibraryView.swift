import SwiftUI

/// 片库首页（HAo 自己的排布）：顶部“继续观看”横轨 → 源站 chips → 分类 chips → 海报墙（3 列 + 分页加载）。
struct LibraryView: View {
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var player: VideoPlayerService

    @State private var selectedSite: TVBoxSite?
    @State private var categories: [TVBoxSiteClass] = []
    @State private var selectedCategory: TVBoxSiteClass?
    @State private var items: [VodItem] = []
    @State private var page = 1
    @State private var pageCount = 1
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showSourcePicker = false
    @State private var selectedItem: VodItem?

    private let columns = [
        GridItem(.flexible(), spacing: HaoMovieDesign.space12),
        GridItem(.flexible(), spacing: HaoMovieDesign.space12),
        GridItem(.flexible(), spacing: HaoMovieDesign.space12),
    ]

    var body: some View {
        NavigationStack {
            Group {
                if !subscriptions.hasAnySubscription {
                    emptyState
                } else {
                    content
                }
            }
            .navigationTitle("片库")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSourcePicker = true } label: {
                        Image(systemName: "plus.circle")
                    }
                    .accessibilityLabel("管理订阅")
                }
            }
            .sheet(isPresented: $showSourcePicker) {
                SourcePickerView()
            }
            .sheet(item: $selectedItem) { item in
                VodDetailView(item: item, site: selectedSite)
            }
            .task { await loadInitial() }
            .onChange(of: subscriptions.mergedSites) { _, _ in
                Task { await loadInitial() }
            }
        }
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: HaoMovieDesign.space16) {
            Image(systemName: "film.fill")
                .font(.system(size: 48))
                .foregroundStyle(HaoMovieDesign.textSecondary)
            Text("还没有片源")
                .font(.system(size: 17, weight: .semibold))
            Text("导入 TVBox JSON 订阅即可浏览片库。\nHAo Movie 自身不内置任何片源。")
                .font(.system(size: 14))
                .foregroundStyle(HaoMovieDesign.textSecondary)
                .multilineTextAlignment(.center)
            Button("导入订阅") { showSourcePicker = true }
                .buttonStyle(.borderedProminent)
                .tint(HaoMovieDesign.accent)
        }
        .haoPagePadding()
    }

    // MARK: - 内容

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HaoMovieDesign.space20) {
                if !history.continueWatching.isEmpty {
                    continueWatchingRail
                }
                siteChips
                categoryChips
                posterGrid
                if let errorMessage {
                    errorBanner(errorMessage)
                }
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, HaoMovieDesign.space12)
                } else if page < pageCount {
                    Button("加载更多") {
                        Task { await loadPage(page + 1, append: true) }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, HaoMovieDesign.space12)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(HaoMovieDesign.accent)
                }
            }
            .padding(.vertical, HaoMovieDesign.space12)
        }
    }

    private var continueWatchingRail: some View {
        VStack(alignment: .leading, spacing: HaoMovieDesign.space8) {
            Text("继续观看")
                .font(.system(size: 17, weight: .bold))
                .haoPagePadding()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HaoMovieDesign.space12) {
                    ForEach(history.continueWatching) { entry in
                        Button {
                            openHistoryEntry(entry)
                        } label: {
                            VStack(alignment: .leading, spacing: HaoMovieDesign.space4) {
                                AsyncPoster(urlString: entry.poster)
                                    .frame(width: 112)
                                    .overlay(alignment: .bottom) {
                                        GeometryReader { geo in
                                            Rectangle()
                                                .fill(HaoMovieDesign.accent)
                                                .frame(width: geo.size.width * entry.progress, height: 3)
                                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                                        }
                                    }
                                Text(entry.vodName)
                                    .font(.system(size: 13, weight: .semibold))
                                    .lineLimit(1)
                                    .foregroundStyle(HaoMovieDesign.textPrimary)
                                Text(entry.episodeTitle)
                                    .font(.system(size: 11))
                                    .foregroundStyle(HaoMovieDesign.textSecondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 112)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, HaoMovieDesign.space16)
            }
        }
    }

    private var siteChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HaoMovieDesign.space8) {
                ForEach(subscriptions.mergedSites) { site in
                    Button(site.name) {
                        Task { await selectSite(site) }
                    }
                    .padding(.horizontal, HaoMovieDesign.space12)
                    .padding(.vertical, 6)
                    .background(
                        selectedSite?.key == site.key
                            ? HaoMovieDesign.accent
                            : HaoMovieDesign.surface,
                        in: Capsule()
                    )
                    .foregroundStyle(selectedSite?.key == site.key ? .white : HaoMovieDesign.textPrimary)
                    .font(.system(size: 13, weight: .semibold))
                }
            }
            .padding(.horizontal, HaoMovieDesign.space16)
        }
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HaoMovieDesign.space8) {
                ForEach(categories) { category in
                    Button(category.typeName) {
                        Task { await selectCategory(category) }
                    }
                    .padding(.horizontal, HaoMovieDesign.space12)
                    .padding(.vertical, 6)
                    .background(
                        selectedCategory?.typeId == category.typeId
                            ? HaoMovieDesign.textPrimary
                            : HaoMovieDesign.surface,
                        in: Capsule()
                    )
                    .foregroundStyle(selectedCategory?.typeId == category.typeId ? HaoMovieDesign.background : HaoMovieDesign.textPrimary)
                    .font(.system(size: 13, weight: .semibold))
                }
            }
            .padding(.horizontal, HaoMovieDesign.space16)
        }
    }

    private var posterGrid: some View {
        LazyVGrid(columns: columns, spacing: HaoMovieDesign.space16) {
            ForEach(items) { item in
                Button { selectedItem = item } label: {
                    PosterCard(item: item)
                }
                .buttonStyle(.plain)
            }
        }
        .haoPagePadding()
    }

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(HaoMovieDesign.textSecondary)
            Spacer()
            Button("重试") {
                Task { await loadPage(1, append: false) }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(HaoMovieDesign.accent)
        }
        .haoPagePadding()
    }

    // MARK: - 数据

    private func loadInitial() async {
        guard selectedSite == nil else { return }
        guard let first = subscriptions.mergedSites.first else { return }
        await selectSite(first)
    }

    private func selectSite(_ site: TVBoxSite) async {
        selectedSite = site
        selectedCategory = nil
        categories = await subscriptions.categories(for: site)
        if let first = categories.first {
            await selectCategory(first)
        } else {
            items = []
            errorMessage = "该源没有分类"
        }
    }

    private func selectCategory(_ category: TVBoxSiteClass) async {
        selectedCategory = category
        page = 1
        await loadPage(1, append: false)
    }

    private func loadPage(_ targetPage: Int, append: Bool) async {
        guard let site = selectedSite, let category = selectedCategory else { return }
        isLoading = true
        errorMessage = nil
        do {
            let result = try await TVBoxClient.fetchList(site: site, typeId: category.typeId, page: targetPage)
            page = result.page
            pageCount = result.pageCount
            items = append ? items + result.items : result.items
        } catch {
            errorMessage = error.localizedDescription
            if let sub = subscriptions.subscriptions.first(where: { $0.apiURL == site.api || subscriptions.sitesBySubscription[$0.id]?.contains(site) == true }) {
                subscriptions.markFailure(sub)
            }
        }
        isLoading = false
    }

    private func openHistoryEntry(_ entry: HistoryEntry) {
        guard let site = subscriptions.mergedSites.first(where: { $0.key == entry.siteKey }) else { return }
        Task {
            if let detail = try? await TVBoxClient.fetchDetail(site: site, vodId: entry.vodId) {
                player.play(detail: detail, site: site, lineIndex: entry.lineIndex, episodeIndex: entry.episodeIndex, resumePosition: entry.position)
            }
        }
    }
}
