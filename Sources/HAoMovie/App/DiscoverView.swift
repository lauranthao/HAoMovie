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
            VStack(alignment: .leading, spacing: 30) {
                ForEach(DoubanCatalog.Feed.allCases, id: \.self) { feed in
                    feedSection(feed)
                }
            }
            #if os(tvOS)
            .pageContainer()
            #else
            // As Discover's See All pages: 17-point gutters around the grids.
            .padding(DiscoverLayout.gutter)
            .frame(maxWidth: Layout.maxWidth).frame(maxWidth: .infinity)
            #endif
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

    /// A Douban list's grid, as Discover's See All pages draw it.
    private static var gridColumns: [GridItem] {
        #if os(tvOS)
        Array(repeating: GridItem(.fixed(DiscoverLayout.posterWidth), spacing: 55, alignment: .top), count: 6)
        #else
        [GridItem(.adaptive(minimum: DiscoverLayout.posterWidth), spacing: DiscoverLayout.spacing, alignment: .leading)]
        #endif
    }
    private static var gridRowSpacing: CGFloat {
        #if os(tvOS)
        66
        #else
        22
        #endif
    }

    @ViewBuilder private func feedSection(_ feed: DoubanCatalog.Feed) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // A shelf's heading, as Discover draws it: 16 pt semibold in a 32-point row.
            Text(feed.title).font(.system(size: DiscoverLayout.heading, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading).frame(height: DiscoverLayout.headingHeight, alignment: .top)
            let items = model.items[feed] ?? []
            if items.isEmpty, model.loading {
                PosterSkeletonGrid(columns: Self.gridColumns, rowSpacing: Self.gridRowSpacing)
            } else if items.isEmpty, model.failures[feed] != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("Couldn't load this list.")).foregroundStyle(.secondary)
                    Button(L10n.text("Retry")) { Task { await model.load(feeds: [feed], refresh: true) } }
                }
            } else {
                LazyVGrid(columns: Self.gridColumns, spacing: Self.gridRowSpacing) {
                    ForEach(items) { item in
                        Button { open(item) } label: {
                            DoubanTile(item: item)
                        }
                        .tmdbCardButton()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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

/// A Douban title as Discover draws its covers, with the year and Douban's score under it.
private struct DoubanTile: View {
    let item: DoubanCatalog.Item
    var body: some View {
        #if os(tvOS)
        VStack(spacing: 5) {
            PosterImage(url: item.cover).frame(width: DiscoverLayout.posterWidth, height: DiscoverLayout.posterWidth * 1.5)
            VStack(spacing: 0) {
                Text(item.title).font(.system(size: DiscoverLayout.caption))
                Text(item.caption.isEmpty ? " " : item.caption).font(.system(size: DiscoverLayout.secondary, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            }.lineLimit(1).cardCaption()
        }.frame(width: DiscoverLayout.posterWidth)
        #else
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.aspectRatio(2.0 / 3, contentMode: .fit)
                .overlay { PosterImage(url: item.cover) }
                .posterClip(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5) }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: DiscoverLayout.caption)).lineLimit(1)
                Text(item.caption).lineLimit(1)
                    .font(.system(size: DiscoverLayout.secondary, design: .rounded)).foregroundStyle(.primary.opacity(0.56))
            }.frame(maxWidth: .infinity, alignment: .leading).frame(height: DiscoverLayout.captionHeight)
        }
        .accessibilityElement(children: .combine)
        #endif
    }
}

private extension DoubanCatalog.Item {
    var caption: String {
        [year.map(String.init), rating.map { L10n.text("Douban") + " " + $0.formatted(.number.precision(.fractionLength(1))) }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

private extension View {
    /// A card button for Discover's tiles: plain on iPhone, iPad and Mac, the focus plate on Apple TV.
    @ViewBuilder func tmdbCardButton() -> some View {
        #if os(tvOS)
        cardButton()
        #else
        buttonStyle(.plain)
        #endif
    }
}
