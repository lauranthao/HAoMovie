import SwiftUI

/// Discover: Douban's hot lists as poster grids — hot movies, hot series,
/// hot variety, now showing, Top 250. No subscription needed to browse: the
/// lists are public.
/// Tapping a title searches it across the user's own sources, so it plays
/// where the subscription has it; without a subscription the search page
/// says so.
struct DiscoverView: View {
    @Environment(Store.self) private var store
    @State private var model = DiscoverModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                ForEach(DoubanCatalog.Feed.allCases, id: \.self) { feed in
                    feedSection(feed)
                }
            }
            .pageContainer()
        }
        .screenBackdrop()
        .screenTitle(L10n.text("Discover"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await model.load(refresh: true) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.loading)
                .accessibilityLabel(L10n.text("Refresh"))
            }
        }
        .refreshable { await model.load(refresh: true) }
        .task { await model.load() }
    }

    @ViewBuilder private func feedSection(_ feed: DoubanCatalog.Feed) -> some View {
        VStack(alignment: .leading, spacing: Layout.headerSpacing) {
            SectionHeader(title: feed.title)
            let items = model.items[feed] ?? []
            if items.isEmpty, model.loading {
                PosterSkeletonGrid()
            } else if items.isEmpty, model.failures[feed] != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("Couldn't load this list.")).foregroundStyle(.secondary)
                    Button(L10n.text("Retry")) { Task { await model.load(feeds: [feed], refresh: true) } }
                }
            } else {
                LazyVGrid(columns: Layout.posterColumns, spacing: Layout.gridRowSpacing) {
                    ForEach(items) { item in
                        Button { open(item) } label: {
                            PosterCard(name: item.title, poster: item.cover, remarks: remarks(for: item))
                        }
                        .cardButton()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func remarks(for item: DoubanCatalog.Item) -> String {
        var parts: [String] = []
        if let year = item.year { parts.append(String(year)) }
        if let rating = item.rating { parts.append(String(format: "%.1f", rating)) }
        return parts.joined(separator: " · ")
    }

    private func open(_ item: DoubanCatalog.Item) {
        // Without a subscription there is nothing to search: the search
        // page itself says to add one.
        guard store.subscription != nil else { store.section = .search; return }
        store.searchVideos(DoubanCatalog.searchTitle(item))
    }
}

/// Douban's five hot lists, loaded in parallel. Loaded lists stay while
/// a refresh runs, so the page does not flash empty.
@MainActor @Observable
final class DiscoverModel {
    private(set) var items: [DoubanCatalog.Feed: [DoubanCatalog.Item]] = [:]
    private(set) var failures: [DoubanCatalog.Feed: String] = [:]
    private(set) var loading = false
    private var loaded = false

    func load(feeds: [DoubanCatalog.Feed]? = nil, refresh: Bool = false) async {
        if loaded, !refresh, feeds == nil { return }
        let wanted = feeds ?? DoubanCatalog.Feed.allCases.filter { refresh || items[$0] == nil }
        guard !wanted.isEmpty else { return }
        loading = true
        defer { loading = false }
        await withTaskGroup(of: (DoubanCatalog.Feed, [DoubanCatalog.Item]?).self) { group in
            for feed in wanted {
                group.addTask { (feed, try? await DoubanCatalog.items(feed)) }
            }
            for await (feed, result) in group {
                if let result {
                    items[feed] = result
                    failures[feed] = nil
                } else if items[feed] == nil {
                    failures[feed] = "load"
                }
            }
        }
        loaded = true
    }
}
