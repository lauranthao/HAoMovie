import SwiftUI

/// Discover: Douban's hot lists as rails, as Yingxia draws them — a heading that opens the whole list,
/// a horizontal rail of covers under it. Tapping a title opens its title page, which searches the
/// viewer's sources for it.
///
/// Only the Douban section is rendered: every other section on Yingxia's Discover page (Featured Titles,
/// Following Calendar, the airing calendars, the TMDB shelves, collections, people, networks, genres,
/// rankings, studios) is TMDB data served by Yingxia's lookup service, and HAo Movie has no TMDB lookup
/// yet — the TMDB Worker is not deployed. Those sections stay in `DiscoverSection` so Edit Layout and the
/// page structure are ready when the Worker lands; until then they render nothing.
struct DiscoverView: View {
    @Environment(Store.self) private var store
    @State private var model = DiscoverModel()
    @State private var editing = false
    @AppStorage("discover.hiddenSections") private var hiddenSections = ""
    /// Douban's lists are in Chinese: shown by default only when the app is.
    @AppStorage("discover.doubanShown") private var doubanShown = L10n.resolvedLanguage().hasPrefix("zh")

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                if model.loading, !model.loaded {
                    ProgressView().frame(maxWidth: .infinity).frame(height: 160)
                }
                ForEach(DiscoverSection.allCases.filter(visible)) { section in
                    sectionView(section)
                }
                if !model.failures.isEmpty {
                    Button { Task { await model.load(refresh: true) } } label: {
                        Label(L10n.text("Some lists couldn't load. Try again."), systemImage: "arrow.clockwise")
                            #if !os(tvOS)
                            .font(.subheadline).frame(maxWidth: .infinity).padding()
                            #endif
                    }
                    #if os(tvOS)
                    .controlButton().frame(maxWidth: .infinity)
                    #else
                    .buttonStyle(.plain)
                    #endif
                    .accessibilityIdentifier("discover.retry")
                }
                if !model.loading, model.loaded, model.items.values.allSatisfy({ $0.isEmpty }) {
                    EmptyResults(symbol: "film", title: L10n.text("No Titles Available"), message: L10n.text("Please try again later."),
                                 action: model.failures.isEmpty ? L10n.text("Try Again") : nil) { Task { await model.load(refresh: true) } }
                }
                if !(model.loading && !model.loaded) {
                    Button { editing = true } label: {
                        Label(L10n.text("Edit Layout"), systemImage: "slider.horizontal.3")
                            #if !os(tvOS)
                            .font(.subheadline).padding(18).glassSurface(.regular, in: Capsule())
                            #endif
                    }
                    #if os(tvOS)
                    .controlButton()
                    #else
                    .buttonStyle(.plain)
                    #endif
                    .frame(maxWidth: .infinity).padding(.top, 10)
                }
            }
            .padding(.bottom, 28)
            #if os(tvOS)
            .pageContainer()
            #else
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
        .sheet(isPresented: $editing) {
            NavigationStack {
                Form {
                    // Only the sections the page can render are listed: the TMDB sections join
                    // when the Worker serves them.
                    ForEach(DiscoverSection.allCases.filter(\.isAvailable)) { section in
                        Toggle(section.title, isOn: shown(section))
                            #if !os(tvOS)
                            .settingsSwitch()
                            #endif
                    }
                }
                .navigationTitle(L10n.text("Edit Layout"))
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { editing = false } } }
            }.preferredColorScheme(.dark).discoverSheetSize(width: 420, height: 560)
        }
    }

    private func visible(_ section: DiscoverSection) -> Bool {
        section == .douban ? doubanShown : !hiddenSections.split(separator: ",").contains(Substring(section.rawValue))
    }

    /// Whether Edit Layout shows the section on the page.
    private func shown(_ section: DiscoverSection) -> Binding<Bool> {
        Binding(get: { visible(section) }, set: { shown in
            if section == .douban { doubanShown = shown; return }
            var hidden = Set(hiddenSections.split(separator: ",").map(String.init))
            if shown { hidden.remove(section.rawValue) } else { hidden.insert(section.rawValue) }
            hiddenSections = hidden.sorted().joined(separator: ",")
        })
    }

    @ViewBuilder private func sectionView(_ section: DiscoverSection) -> some View {
        if section == .douban { doubanShelves }
        // Every other section renders TMDB data through the Worker (not deployed): it shows nothing until then.
    }

    #if !os(tvOS)
    /// A shelf's heading that opens its full list, as the TMDB shelves' do.
    private func moreHeading<Destination: View>(_ title: String, identifier: String,
                                                @ViewBuilder destination: @escaping @MainActor () -> Destination) -> some View {
        RouteLink(destination: destination) {
            HStack {
                Text(title).font(.system(size: DiscoverLayout.heading, weight: .semibold))
                Spacer()
                Image(systemName: "chevron.forward").font(.system(size: 14, weight: .semibold))
            }.frame(height: DiscoverLayout.headingHeight, alignment: .top).contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(.horizontal, DiscoverLayout.gutter)
        .accessibilityIdentifier(identifier)
    }
    #endif

    private func sectionHeading(_ title: String) -> some View {
        Text(title).font(.system(size: DiscoverLayout.heading, weight: .semibold))
            .frame(maxWidth: .infinity, alignment: .leading).frame(height: DiscoverLayout.headingHeight, alignment: .top)
            .padding(.horizontal, DiscoverLayout.gutter)
    }

    /// Douban's hot lists, captioned with Douban's score. A title opens its title page.
    private var doubanShelves: some View {
        VStack(alignment: .leading, spacing: 30) {
            ForEach(DoubanCatalog.Feed.allCases, id: \.self) { feed in
                let items = model.items[feed] ?? []
                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        #if os(tvOS)
                        // No DiscoverTVNativeShelf in this tree: the grid, as before.
                        sectionHeading(feed.title)
                        LazyVGrid(columns: Self.gridColumns, spacing: Self.gridRowSpacing) {
                            ForEach(items) { item in
                                RouteLink { DoubanTitleView(item: item) } label: { DoubanTile(item: item) }
                                    .cardButton()
                                    .accessibilityIdentifier("discover.douban.\(feed.rawValue).\(item.id)")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        #else
                        moreHeading(feed.title, identifier: "discover.more.douban.\(feed.rawValue)") {
                            DoubanListView(feed: feed, initial: items)
                        }
                        DiscoverRail(arrowCenter: 87) {
                            LazyHStack(alignment: .top, spacing: DiscoverLayout.spacing) {
                                ForEach(items) { item in
                                    RouteLink { DoubanTitleView(item: item) } label: {
                                        DoubanTile(item: item).frame(width: DiscoverLayout.posterWidth)
                                    }
                                    .tmdbCardButton()
                                    .accessibilityIdentifier("discover.douban.\(feed.rawValue).\(item.id)")
                                }
                            }.padding(.horizontal, DiscoverLayout.gutter)
                        }
                        #endif
                    }
                }
            }
        }
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
}

/// Douban's five hot lists, loaded in parallel. Loaded lists stay while
/// a refresh runs, so the page does not flash empty.
@MainActor @Observable
final class DiscoverModel {
    private(set) var items: [DoubanCatalog.Feed: [DoubanCatalog.Item]] = [:]
    private(set) var failures: [DoubanCatalog.Feed: String] = [:]
    private(set) var loading = false
    private(set) var loaded = false

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

private enum DiscoverSection: String, CaseIterable, Identifiable {
    case hero, following, airingAnime, airingSeries, douban, nowPlaying, onTheAir, trending, collections, animation, people, networks, genres, rankings, companies
    var id: String { rawValue }
    /// Only `.douban` can render today: the rest need the TMDB Worker. Edit Layout lists only
    /// the sections the page can render, so no toggle there does nothing.
    var isAvailable: Bool { self == .douban }
    var title: String {
        switch self {
        case .hero: L10n.text("Featured Titles")
        case .following: L10n.text("Following Calendar")
        case .airingAnime: L10n.text("Anime Airing Today")
        case .airingSeries: L10n.text("Series Airing Today")
        case .douban: L10n.text("Douban Hot Lists")
        case .nowPlaying: L10n.text("In Theaters")
        case .onTheAir: L10n.text("On the Air")
        case .trending: L10n.text("Trending This Week")
        case .collections: L10n.text("Featured Collections")
        case .animation: L10n.text("Popular Animation")
        case .people: L10n.text("People")
        case .networks: L10n.text("Networks")
        case .genres: L10n.text("Browse by Genre")
        case .rankings: L10n.text("Top Rated Collections")
        case .companies: L10n.text("Film Studios")
        }
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

/// A whole Douban list, as Discover's See All pages: Douban's lists run to a few hundred titles, 30 at a time.
private struct DoubanListView: View {
    let feed: DoubanCatalog.Feed
    @State private var items: [DoubanCatalog.Item]
    @State private var loading = false
    @State private var failed = false
    @State private var ended = false
    init(feed: DoubanCatalog.Feed, initial: [DoubanCatalog.Item]) {
        self.feed = feed
        _items = State(initialValue: initial)
    }
    var body: some View {
        ScrollView {
            #if os(tvOS)
            Text(feed.title).font(.system(size: 52, weight: .semibold)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                .frame(maxWidth: .infinity).padding(.top, 60)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(DiscoverLayout.posterWidth), spacing: 55, alignment: .top), count: 6), spacing: 66) {
                cells
            }.padding(.top, 54)
            #else
            LazyVGrid(columns: [GridItem(.adaptive(minimum: DiscoverLayout.posterWidth), spacing: DiscoverLayout.spacing)], alignment: .leading, spacing: 22) {
                cells
            }.padding(DiscoverLayout.gutter)
            #endif
            if failed {
                Button(L10n.text("Try Again")) { Task { await loadMore() } }.padding()
            } else if loading {
                ProgressView().padding()
            }
        }
        #if os(tvOS)
        .scrollClipDisabled()
        .ignoresSafeArea(edges: .top)
        .toolbar(.hidden, for: .navigationBar)
        #else
        .navigationTitle(feed.title)
        #endif
        .background { DiscoverCanvas(poster: items.first?.cover) }
        .foregroundStyle(.white).preferredColorScheme(.dark)
        .task { if items.isEmpty { await loadMore() } }
    }
    private var cells: some View {
        ForEach(items) { item in
            RouteLink { DoubanTitleView(item: item) } label: {
                #if os(tvOS)
                DoubanTile(item: item)
                #else
                DoubanTile(item: item).frame(maxWidth: .infinity)
                #endif
            }
            #if os(tvOS)
            .cardButton()
            #else
            .tmdbCardButton()
            #endif
            .accessibilityIdentifier("discover.douban.list.\(item.id)")
            .task { if item.id == items.last?.id { await loadMore() } }
        }
    }
    private func loadMore() async {
        guard !loading, !ended else { return }
        loading = true; failed = false
        defer { loading = false }
        do {
            let page = try await DoubanCatalog.items(feed, start: items.count)
            guard !Task.isCancelled else { return }
            var seen = Set(items.map(\.id))
            let fresh = page.filter { seen.insert($0.id).inserted }
            items += fresh
            ended = fresh.isEmpty
        } catch { if !Task.isCancelled { failed = true } }
    }
}

/// A Douban title opens its title page, which searches the viewer's sources for it.
/// (Yingxia opens the TMDB title it matches first, and keeps Douban's card when there is none;
/// the TMDB match needs the Worker, so the title page itself is the destination until then.)
private struct DoubanTitleView: View {
    let item: DoubanCatalog.Item
    var body: some View { DiscoverDetailView(item: item) }
}

/// Search Sources (Add Subscription without one) as the detail page draws it: a white capsule, or the TV's
/// action button. Kept for the airing calendar's fallback card, which uses it the same way (not yet ported).
struct DiscoverFindSourcesButton: View {
    @Environment(Store.self) private var store
    let title: String
    var body: some View {
        Button {
            if store.subscription == nil { store.section = .settings } else { store.searchVideos(title) }
        } label: {
            Label(L10n.text(store.subscription == nil ? "Add Subscription" : "Search Sources"), systemImage: "magnifyingglass")
                #if os(tvOS)
                .frame(width: 380)
                #else
                .font(.system(size: 15, weight: .semibold)).frame(width: 260).frame(height: 50)
                .foregroundStyle(Color.black).background(Color.white, in: Capsule()).contentShape(Capsule())
                #endif
        }
        #if os(tvOS)
        .buttonStyle(DiscoverTVActionStyle(height: 86, font: 30))
        #else
        .buttonStyle(.plain)
        #endif
    }
}

struct DiscoverCanvas: View {
    let poster: URL?
    @State private var paint: DiscoverPaint?
    var body: some View {
        (paint?.color ?? Color(white: 0.06))
            .overlay(.black.opacity(0.4)).discoverFullBleed()
            .task(id: poster) {
                guard let poster else { return }
                let value = await DiscoverPainter.shared.paint(poster)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.4)) { paint = value }
            }
    }
}

extension View {
    /// A card button for Discover's tiles: plain on iPhone, iPad and Mac, the focus plate on Apple TV.
    @ViewBuilder func tmdbCardButton() -> some View {
        #if os(tvOS)
        cardButton()
        #else
        buttonStyle(.plain)
        #endif
    }

    /// A sheet's size on the Mac; a plain sheet elsewhere.
    func discoverSheetSize(width: CGFloat, height: CGFloat) -> some View {
        #if os(macOS)
        frame(minWidth: width * 0.8, idealWidth: width, minHeight: height * 0.8, idealHeight: height)
        #else
        self
        #endif
    }
}
