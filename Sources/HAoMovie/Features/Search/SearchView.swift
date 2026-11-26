import SwiftUI

/// 全源搜索：一次查询跑遍所有可搜源，结果按源陆续出现；
/// 失败的源可单独重试；搜索历史存本机 20 条。
struct SearchView: View {
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @EnvironmentObject private var searchService: SearchService

    @State private var query = ""
    @State private var selectedHit: SearchService.Hit?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                if searchService.hits.isEmpty && !searchService.isSearching && query.isEmpty {
                    historyView
                } else {
                    resultsList
                }
            }
            .navigationTitle("搜索")
            .sheet(item: $selectedHit) { hit in
                VodDetailView(item: hit.item, site: hit.site)
            }
        }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(HaoMovieDesign.textSecondary)
            TextField("搜影片、剧集", text: $query)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .onSubmit { runSearch() }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(HaoMovieDesign.textSecondary)
                }
            }
            if searchService.isSearching {
                ProgressView()
            }
        }
        .padding(HaoMovieDesign.space12)
        .background(HaoMovieDesign.surface, in: RoundedRectangle(cornerRadius: HaoMovieDesign.cardRadius))
        .padding(.horizontal, HaoMovieDesign.space16)
        .padding(.vertical, HaoMovieDesign.space8)
    }

    private var historyView: some View {
        VStack(alignment: .leading, spacing: HaoMovieDesign.space12) {
            HStack {
                Text("搜索历史")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if !searchService.history.isEmpty {
                    Button("清除") { searchService.clearHistory() }
                        .font(.system(size: 13))
                        .foregroundStyle(HaoMovieDesign.accent)
                }
            }
            if searchService.history.isEmpty {
                Text("在上方输入关键词，全源搜索影片。")
                    .font(.system(size: 14))
                    .foregroundStyle(HaoMovieDesign.textSecondary)
            } else {
                FlowChips(items: searchService.history) { term in
                    query = term
                    runSearch()
                }
            }
            Spacer()
        }
        .haoPagePadding()
        .padding(.top, HaoMovieDesign.space12)
    }

    private var resultsList: some View {
        List {
            ForEach(searchService.hits) { hit in
                Button { selectedHit = hit } label: {
                    VodRow(item: hit.item, subtitle: hit.site.name)
                }
                .buttonStyle(.plain)
            }
            if !searchService.failedSites.isEmpty {
                Section {
                    HStack {
                        Text("\(searchService.failedSites.count) 个源搜索失败")
                            .font(.system(size: 13))
                            .foregroundStyle(HaoMovieDesign.textSecondary)
                        Spacer()
                        Button("重试") { searchService.retryFailed(keyword: query) }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(HaoMovieDesign.accent)
                    }
                }
            }
            if searchService.hits.isEmpty, !searchService.isSearching, !query.isEmpty {
                Section {
                    Text("没有找到相关影片")
                        .font(.system(size: 14))
                        .foregroundStyle(HaoMovieDesign.textSecondary)
                }
            }
        }
        .listStyle(.plain)
    }

    private func runSearch() {
        searchService.search(keyword: query, sites: subscriptions.mergedSites)
    }
}

/// 简单的流式 chips 布局（搜索历史用）。
struct FlowChips: View {
    var items: [String]
    var onTap: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: HaoMovieDesign.space8)], alignment: .leading, spacing: HaoMovieDesign.space8) {
            ForEach(items, id: \.self) { item in
                Button(item) { onTap(item) }
                    .font(.system(size: 13))
                    .padding(.horizontal, HaoMovieDesign.space12)
                    .padding(.vertical, 6)
                    .background(HaoMovieDesign.surface, in: Capsule())
                    .lineLimit(1)
            }
        }
    }
}
