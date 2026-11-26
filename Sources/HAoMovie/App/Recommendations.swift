// Restored from Yingxia (jo32/tvbox-silicon, GPL-3.0) — shared helpers the kept
// files still use. Adapted for HAo Movie where noted (no TMDB, no JavaScript
// runtime, no libass/TVMedia); see the notes on each type.

import SwiftUI

struct RecommendationsView: View {
    @Environment(Store.self) private var store
    @Environment(\.openRoute) private var openRoute
    let config: Subscription
    var fixedSite: Site? = nil
    /// Apple TV's Watch Now: the picks as a row of covers, then a row for each of the source's first categories.
    var rails = false
    @AppStorage("recommendationSource") private var sourceKey = ""
    @State private var revision = 0
    @State private var forceRefresh = false
    @State private var choosingSource = false
    /// A source's page opened from its long-press menu, outside a stack that takes `openRoute`.
    @State private var openedSource: Route?
    #if os(tvOS)
    @FocusState private var focusedSource: String?
    /// The long-press action chosen in the source picker, run once its sheet has closed.
    @State private var afterPicker: (() -> Void)?
    #endif
    /// The source category shown instead of its recommendations; nil shows the recommendations.
    @State private var category: String?
    /// The open category's filter choices (key to value), set with `category`.
    @State private var categoryFilters: [String: String] = [:]
    /// The source `category` belongs to. A source change clears it inside the load task, which is the last writer.
    @State private var categorySite: String?
    @State private var browser = CatalogBrowser()
    private var model: RecommendationModel { store.recommendationModel }
    private var sites: [Site] { fixedSite.map { [$0] } ?? store.recommendationSites(config) }
    /// Until the user picks a source, default to the first in strategy order, so opening the app
    /// does not start the JVM when a standard API or script source is available. A source paused for
    /// failing (`SourceHealth.paused`) is passed over unless it is the viewer's pick.
    private var site: Site? {
        sites.first(where: { $0.key == sourceKey })
            ?? sites.first(where: { !SourceHealth.shared.paused($0, origin: config.origin) }) ?? sites.first
    }
    /// `model.resets`: the store resets the model when it rebuilds the subscription, which drops a load in flight.
    private var requestID: String { "\(config.origin)|\(config.importedAt)|\(site?.key ?? "")|\(revision)|\(model.resets)" }

    private var recommendationControls: some View {
        HStack(spacing: 12) {
            if let site {
                if fixedSite == nil {
                #if os(tvOS)
                // The name opens the source, as on the Sources page; the switch beside it chooses another.
                Button { openSite(site) } label: {
                    Label(site.name, systemImage: "chevron.right")
                        .lineLimit(1)
                }
                .glassPill()
                .contextMenu { sourceActions(site) }
                .accessibilityIdentifier("recommendations.open")
                Button {
                    // The sheet only where nothing can be pushed.
                    if openRoute != nil { pickSource(site) } else { choosingSource = true }
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .glassPill()
                .accessibilityLabel(L10n.text("Recommendation Source"))
                .accessibilityIdentifier("recommendations.switch")
                .sheet(isPresented: $choosingSource, onDismiss: { afterPicker?(); afterPicker = nil }) {
                    NavigationStack {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 4) {
                                    ForEach(sites) { candidate in
                                        Button { choose(candidate); choosingSource = false } label: {
                                            HStack {
                                                Text(candidate.name).lineLimit(1)
                                                Spacer()
                                                if candidate.key == site.key { Image(systemName: "checkmark").foregroundStyle(Brand.accent) }
                                            }
                                            .frame(maxWidth: .infinity)
                                        }
                                        .glassRow()
                                        .contextMenu { sourceActions(candidate) { afterPicker = $0; choosingSource = false } }
                                        .focused($focusedSource, equals: candidate.key)
                                        .id(candidate.key)
                                    }
                                }
                                .glassRowInsets()
                            }
                            // Open on the current source rather than the top of a long list.
                            .defaultFocus($focusedSource, site.key)
                            .onAppear { proxy.scrollTo(site.key, anchor: .center) }
                        }
                        .screenTitle(L10n.text("Recommendation Source"))
                        .screenBackdrop()
                    }
                    .frame(width: 1000, height: 700)
                    .onExitCommand { choosingSource = false }
                }
                #endif
                }
                Spacer(minLength: 0)
                #if os(tvOS)
                Button { forceRefresh = true; revision += 1 } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .glassPill()
                .disabled(model.busy).accessibilityLabel(L10n.text("Refresh"))
                #else
                Button { forceRefresh = true; revision += 1 } label: {
                    ZStack {
                        if model.busy {
                            ProgressView().appControlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: SourceStrip.controlSize, height: SourceStrip.controlSize)
                    // Liquid Glass where the system draws it, as the source and switch buttons beside it.
                    .glassOrFill(.regular.interactive(), Color.primary.opacity(0.06), in: Circle())
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(model.busy)
                .accessibilityLabel(L10n.text(model.busy ? "Loading…" : "Refresh"))
                .help(L10n.text("Refresh"))
                #endif
            }
        }
    }

    /// Opens the Sources page to choose the source from, as on every platform; choosing comes back here.
    private func pickSource(_ current: Site) {
        let sites = sites, key = current.key
        openRoute?(Route { AnyView(SitesView(pick: { choose($0) }, pickable: sites, picked: key)) })
    }

    #if !os(tvOS)
    /// The chosen source as a capsule that opens it, and a switch beside it that opens the Sources page to choose another.
    private func sourcePickerButton(_ site: Site) -> some View {
        HStack(spacing: 8) {
            sourceNameButton(site)
            Button { pickSource(site) } label: {
                Image(systemName: "arrow.left.arrow.right").font(.subheadline.weight(.semibold))
                    .frame(width: SourceStrip.controlSize, height: SourceStrip.controlSize)
                    .glassOrFill(.regular.interactive(), Color.primary.opacity(0.06), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Recommendation Source"))
            .accessibilityIdentifier("recommendations.switch")
            #if os(macOS)
            .help(L10n.text("Recommendation Source"))
            #endif
        }
    }

    private func sourceNameButton(_ site: Site) -> some View {
        Button { openSite(site) } label: {
            HStack(spacing: 6) {
                Text(site.name).lineLimit(1)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14).frame(height: SourceStrip.controlSize)
            .glassOrFill(.regular.interactive(), Color.primary.opacity(0.06), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu { sourceActions(site) }
        .accessibilityIdentifier("recommendations.open")
    }
    #endif

    /// The source's own page, as choosing it on the Sources page opens.
    private func openSite(_ site: Site) {
        let route = sitePage(site)
        if let openRoute { openRoute(route) } else { openedSource = route }
    }

    /// The source's page, opening on the picks already shown here; it refreshes them and swaps in a different answer.
    /// With `category`, it opens on that category instead, as a category row's heading asks (#1267).
    private func sitePage(_ site: Site, category: Category? = nil) -> Route {
        let config = config
        var preview: (videos: [Video], categories: [Category], hasRecommendations: Bool)?
        if model.site?.key == site.key, !model.busy {
            let videos = model.items.compactMap { item -> Video? in if case .detail(let video) = item.destination { video } else { nil } }
            if category != nil { preview = ([], model.categories, !model.items.isEmpty) }
            else if !videos.isEmpty, videos.count == model.items.count { preview = (videos, model.categories, true) }
        }
        return Route { AnyView(SiteView(site: site, origin: config.origin, jarURL: config.spiderURL, preview: preview, category: category)) }
    }

    /// Leaving this source drops its open category before the new home loads.
    private func choose(_ candidate: Site) {
        category = nil
        sourceKey = candidate.key
        revision = 0
        forceRefresh = false
    }

    /// The source's picks in a grid, under its categories as chips.
    private var grid: some View {
        VStack(alignment: .leading, spacing: 16) {
            #if os(tvOS)
            recommendationControls.tvFocusSection()
            #else
            if fixedSite == nil, let site, sites.count > 1, openRoute != nil {
                HStack(spacing: 10) {
                    sourcePickerButton(site)
                    Spacer(minLength: 0)
                    recommendationControls.fixedSize()
                }
            } else if fixedSite == nil, let site, sites.count > 1 {
                HStack(spacing: 10) {
                    SourceStrip(items: sites.map { .init(id: $0.key, name: $0.name) }, selection: site.key) { key in
                        // Clear before the key changes. The load task opens a category-only home after it returns;
                        // an onChange that also clears would run after a cached load and wipe that category.
                        if key != sourceKey { category = nil }
                        sourceKey = key; revision = 0; forceRefresh = false
                    } actions: { key in
                        AnyView(sites.first(where: { $0.key == key }).map { sourceActions($0) })
                    }
                    recommendationControls.fixedSize()
                }
            } else {
                HStack(spacing: 16) {
                    Text(L10n.text("Recommendations")).font(.title3.weight(.bold))
                    Spacer()
                    recommendationControls.fixedSize()
                }
            }
            #endif
            if model.busy, let site {
                LoadingCard { .source(site, origin: config.origin, title: L10n.text("Loading recommendations…")) }
            }
            if model.busy && model.items.isEmpty { PosterSkeletonGrid() }
            if let error = model.error {
                Text(error).foregroundStyle(.secondary)
                Button(L10n.text("Retry")) { forceRefresh = true; revision += 1 }
            }
            if let loadedSite = model.site, !model.categories.isEmpty {
                categoryChips(loadedSite).tvFocusSection()
            }
            if let category, let current = model.categories.first(where: { $0.id == category }), !current.filters.isEmpty {
                CategoryFilterBar(filters: current.filters, choices: categoryFilters) { categoryFilters = $0 }.tvFocusSection()
            }
            if category != nil, let loadedSite = model.site {
                categoryContent(loadedSite)
            } else if !model.busy && model.error == nil && model.items.isEmpty {
                Text(L10n.text("This source has no recommendations. Choose another source or use Global Search."))
                    .foregroundStyle(.secondary)
            }
            if category == nil, !model.items.isEmpty, let loadedSite = model.site {
                if (loadedSite.raw["indexs"]?.int ?? 0) == 1 {
                    Text(L10n.text("Choose a title to find it across your sources.")).font(.subheadline).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: Layout.posterColumns, spacing: Layout.gridRowSpacing) {
                    ForEach(model.items) { item in
                        switch item.destination {
                        case .search(let keyword):
                            Button { store.searchVideos(keyword) } label: { PosterCard(recommendation: item) }.cardButton()
                        case .detail(let video):
                            RouteLink {
                                CatalogDestination(video: video, client: CatalogClient(site: loadedSite, origin: config.origin, jarURL: config.spiderURL))
                            } label: { PosterCard(recommendation: item) }.cardButton()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .tvFocusSection()
            }
        }
    }

    var body: some View {
        Group {
            #if os(tvOS)
            if rails { tvRails } else { grid }
            #else
            if rails { phoneRails } else { grid }
            #endif
        }
        .task(id: requestID) {
            #if DEBUG && os(tvOS)
            // `-qaSourcePicker 1` opens the recommendation source picker, for screenshots.
            if UserDefaults.standard.bool(forKey: "qaSourcePicker"), fixedSite == nil { choosingSource = true }
            #endif
            let requested = site?.key
            guard let site else { model.reset(); return }
            // Reset here, while this task is the last writer. A later onChange would clear the category
            // a cached home opens below: that home has no posters, so the page would say it has none.
            if categorySite != requested { category = nil; categorySite = requested }
            let refresh = forceRefresh; forceRefresh = false
            await model.load(client: CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL), subscriptionDate: config.importedAt, force: refresh)
            guard !Task.isCancelled, site.key == requested else { return }
            // A source whose home names only categories (list sites) opens its first one.
            if category == nil, !model.busy, model.error == nil, model.items.isEmpty, let first = model.categories.first {
                category = first.id; categoryFilters = CategoryFilter.initialChoices(first.filters)
            }
        }
        .task(id: "\(requestID)|\(category ?? "")|" + categoryFilters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")) {
            // The rows load their own categories.
            guard !rails, let category, let loadedSite = model.site, loadedSite.key == site?.key else { return }
            await browser.load(.list(category: category, query: "", page: 1, filters: categoryFilters),
                               client: CatalogClient(site: loadedSite, origin: config.origin, jarURL: config.spiderURL))
        }
        .onDisappear { browser.cancel() }
        .navigationDestination(item: $openedSource) { route in
            #if os(macOS)
            route.build().musicBar()
            #else
            route.build()
            #endif
        }
    }

    #if os(tvOS)
    /// The picks as a row of covers, then a row for each of the source's first four categories, each loaded when it
    /// comes on screen. See All opens the source's page.
    private var tvRails: some View {
        LazyVStack(alignment: .leading, spacing: 30) {
            HStack(spacing: 24) {
                Text(L10n.text("Recommendations")).font(.system(size: DiscoverLayout.heading, weight: .semibold)).lineLimit(1)
                recommendationControls
            }
            .padding(.horizontal, DiscoverLayout.gutter)
            .tvFocusSection()
            // Every category row starts loading with the heading, not when it scrolls on screen: a row that filled in
            // under the remote moved the page.
            .task(id: "\(model.site?.key ?? "")|" + model.categories.prefix(4).map(\.id).joined(separator: ",")) {
                guard let loadedSite = model.site else { return }
                let client = CatalogClient(site: loadedSite, origin: config.origin, jarURL: config.spiderURL)
                for item in model.categories.prefix(4) { WatchNowRows.shared.load(category: item.id, client: client) }
            }
            if let error = model.error {
                HStack(spacing: 24) {
                    Text(error).foregroundStyle(.secondary)
                    Button(L10n.text("Retry")) { forceRefresh = true; revision += 1 }.controlButton()
                }
                .padding(.horizontal, DiscoverLayout.gutter)
            }
            if let loadedSite = model.site, !model.busy || !model.items.isEmpty {
                let client = CatalogClient(site: loadedSite, origin: config.origin, jarURL: config.spiderURL)
                let page = sitePage(loadedSite)
                if !model.items.isEmpty {
                    WatchNowTVRow(seeAll: WatchNowTVSeeAll(height: WatchNowTVCover.height, route: page)) {
                            ForEach(model.items) { item in
                                let cover = WatchNowTVCover(title: item.name, detail: item.remarks, poster: item.poster?.url, headers: item.poster?.headers ?? [:])
                                switch item.destination {
                                case .search(let keyword):
                                    Button { store.searchVideos(keyword) } label: { cover }.cardButton()
                                case .detail(let video):
                                    RouteLink { CatalogDestination(video: video, client: client) } label: { cover }.cardButton()
                                }
                            }
                    }
                } else if !model.busy, model.error == nil, model.categories.isEmpty {
                    Text(L10n.text("This source has no recommendations. Choose another source or use Global Search."))
                        .foregroundStyle(.secondary).padding(.horizontal, DiscoverLayout.gutter)
                }
                ForEach(model.categories.prefix(4)) { item in
                    WatchNowTVCategoryRail(title: item.name, category: item.id, client: client, seeAll: sitePage(loadedSite, category: item))
                }

            } else if model.busy {
                HStack(spacing: DiscoverLayout.spacing) {
                    ForEach(0..<7, id: \.self) { _ in
                        SkeletonBlock(cornerRadius: 12).frame(width: WatchNowTVCover.width, height: WatchNowTVCover.height)
                            .frame(height: WatchNowTVCover.height + DiscoverLayout.captionHeight, alignment: .top)
                    }
                }
                .padding(.horizontal, DiscoverLayout.gutter).padding(.vertical, 24)
                .accessibilityLabel(L10n.text("Loading…"))
            }
        }
    }
    #endif

    #if !os(tvOS)
    /// Watch Now on iPhone and the Mac: the picks as a row of covers under the source, then a row for each of its first four
    /// categories, as on Apple TV. A category's heading opens that category on the source's page.
    private var phoneRails: some View {
        VStack(alignment: .leading, spacing: 30) {
            // One line: the source and its switch stand in for the heading (#997), with Refresh at the end.
            HStack(spacing: 8) {
                if fixedSite == nil, let site, sites.count > 1, openRoute != nil {
                    sourcePickerButton(site)
                } else {
                    Text(L10n.text("Recommendations")).font(.system(size: DiscoverLayout.heading, weight: .semibold)).lineLimit(1)
                }
                Spacer(minLength: 8)
                recommendationControls.fixedSize()
            }
            .padding(.horizontal, DiscoverLayout.gutter)
            // Every category row starts loading with the heading, not when it scrolls on screen.
            .task(id: "\(model.site?.key ?? "")|" + model.categories.prefix(4).map(\.id).joined(separator: ",")) {
                guard let loadedSite = model.site else { return }
                let client = CatalogClient(site: loadedSite, origin: config.origin, jarURL: config.spiderURL)
                for item in model.categories.prefix(4) { WatchNowRows.shared.load(category: item.id, client: client) }
            }
            if let error = model.error {
                VStack(alignment: .leading, spacing: 10) {
                    Text(error).font(.subheadline).foregroundStyle(.secondary)
                    Button(L10n.text("Retry")) { forceRefresh = true; revision += 1 }.controlButton()
                }
                .padding(.horizontal, DiscoverLayout.gutter)
            }
            if let loadedSite = model.site, !model.busy || !model.items.isEmpty {
                let client = CatalogClient(site: loadedSite, origin: config.origin, jarURL: config.spiderURL)
                let page = sitePage(loadedSite)
                if !model.items.isEmpty {
                    WatchNowPhoneRow {
                        ForEach(model.items) { item in
                            let cover = WatchNowPhoneCover(title: item.name, detail: item.remarks, poster: item.poster?.url, headers: item.poster?.headers ?? [:])
                            switch item.destination {
                            case .search(let keyword):
                                Button { store.searchVideos(keyword) } label: { cover }.buttonStyle(.plain)
                            case .detail(let video):
                                RouteLink { CatalogDestination(video: video, client: client) } label: { cover }.buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.top, -16)
                } else if !model.busy, model.error == nil, model.categories.isEmpty {
                    Text(L10n.text("This source has no recommendations. Choose another source or use Global Search."))
                        .font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, DiscoverLayout.gutter)
                }
                ForEach(model.categories.prefix(4)) { item in
                    WatchNowPhoneCategoryRail(title: item.name, category: item.id, client: client, seeAll: sitePage(loadedSite, category: item))
                }
            } else if model.busy {
                WatchNowPhoneSkeletonRow().padding(.top, -16)
            }
        }
    }
    #endif

    /// A long press on a source (a right click on Mac): hide it, open its page to search only that source, as the
    /// Sources page does, or go to the Sources page to manage them all. `leave` runs the two that leave Watch Now;
    /// the tvOS picker passes one that closes its sheet first.
    @ViewBuilder private func sourceActions(_ candidate: Site, leave: @escaping (@escaping () -> Void) -> Void = { $0() }) -> some View {
        HideSourceButton(site: candidate, origin: config.origin)
        Button {
            leave {
                let route = Route { AnyView(SiteView(site: candidate, origin: config.origin, jarURL: config.spiderURL)) }
                if let openRoute { openRoute(route) } else { openedSource = route }
            }
        } label: { Label(L10n.text("Search This Source"), systemImage: "magnifyingglass") }
            .accessibilityIdentifier("source.search." + candidate.key)
        Button { leave { store.section = .sites } } label: { Label(L10n.text("Manage Sources"), systemImage: AppSection.sites.icon) }
    }

    private func categoryChips(_ loadedSite: Site) -> some View {
        ChipRow {
            HStack(spacing: 8) {
                if !model.items.isEmpty {
                    Chip(title: L10n.text("Recommendations"), selected: category == nil) { category = nil }
                }
                // The source's own "推荐" category: the chip above shows the home's recommendations, so the source's
                // copy would be a second chip with the same name (#2209). Without the home's recommendations the
                // chip above is not there, and the source's category stays, so its content is still reachable.
                ForEach(model.categories.filter { !($0.isRecommendations && !model.items.isEmpty) }) { item in
                    Chip(title: item.name, selected: category == item.id) {
                        category = item.id; categoryFilters = CategoryFilter.initialChoices(item.filters)
                    }
                }
            }.padding(.vertical, 4)
        }
    }

    @ViewBuilder private func categoryContent(_ loadedSite: Site) -> some View {
        let client = CatalogClient(site: loadedSite, origin: config.origin, jarURL: config.spiderURL)
        let isIndex = (loadedSite.raw["indexs"]?.int ?? 0) == 1
        if browser.busy && browser.videos.isEmpty { PosterSkeletonGrid() }
        if let error = browser.error {
            Text(error).foregroundStyle(.secondary)
            Button(L10n.text("Retry")) { Task { await browser.load(browser.request, client: client) } }
        }
        if !browser.videos.isEmpty {
            if isIndex {
                Text(L10n.text("Choose a title to find it across your sources.")).font(.subheadline).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Layout.posterColumns, spacing: Layout.gridRowSpacing) {
                ForEach(browser.videos) { video in
                    Group {
                        if isIndex {
                            Button { store.searchVideos(video.name) } label: { PosterCard(video: video) }.cardButton()
                        } else {
                            RouteLink { CatalogDestination(video: video, client: client) } label: { PosterCard(video: video) }.cardButton()
                        }
                    }
                    .onAppear {
                        // The last cover coming on screen appends the next page, so scrolling never stops
                        // at a page boundary. A failed page waits for the footer's Retry instead.
                        guard browser.moreError == nil, video.id == browser.videos.last?.id else { return }
                        Task { await browser.loadMore(client: client) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(browser.busy ? 0.55 : 1)
            .tvFocusSection()
            // A focus section, so moving down from a cover in any column reaches Load More or Try Again.
            Group {
                if let message = browser.moreError {
                    VStack(spacing: 12) {
                        Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button(L10n.text("Try Again")) { Task { await browser.loadMore(client: client) } }
                            .controlButton()
                            .accessibilityIdentifier("recommendations.loadMore.retry")
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                } else if browser.loadingMore {
                    ProgressView().appControlSize(.large)
                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                        .accessibilityLabel(L10n.text("Loading…"))
                } else if browser.hasMore {
                    Button(L10n.text("Load More")) { Task { await browser.loadMore(client: client) } }
                        .controlButton()
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .accessibilityIdentifier("recommendations.loadMore")
                }
            }
            .tvFocusSection()
        }
    }
}

private struct ScrollStripMetrics: Equatable { var offset: CGFloat, viewport: CGFloat, maximum: CGFloat }

struct ScrollStrip<Content: View>: View {
    let scrollTo: String?
    let leftLabel: String
    let rightLabel: String
    /// Floats the arrows over the strip's ends instead of beside it, for strips that run edge to edge,
    /// centred this far from the strip's top (the middle of its artwork), or on the strip when nil.
    var overlayArrows = false
    var arrowCenter: CGFloat?
    let content: Content
    #if os(macOS)
    @State private var position = ScrollPosition(idType: String.self)
    #endif
    @State private var edges = Edges()
    /// Live geometry and drag state. A plain reference, so updating it never invalidates the view.
    @State private var tracking = Tracking()

    init(scrollTo: String? = nil, leftLabel: String = "Scroll left", rightLabel: String = "Scroll right",
         overlayArrows: Bool = false, arrowCenter: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.scrollTo = scrollTo
        self.leftLabel = leftLabel
        self.rightLabel = rightLabel
        self.overlayArrows = overlayArrows
        self.arrowCenter = arrowCenter
        self.content = content()
    }

    private struct Edges: Equatable { var leading = false, trailing = false }
    private typealias Metrics = ScrollStripMetrics
    @MainActor private final class Tracking {
        var metrics = Metrics(offset: 0, viewport: 0, maximum: 0)
        var dragOrigin: CGFloat?
        let drag = StripDrag()
        func clamp(_ x: CGFloat) -> CGFloat { min(metrics.maximum, max(0, x)) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 8) {
                measured(
                    ScrollView(.horizontal, showsIndicators: false) {
                        measuredContent
                    }
                    #if os(macOS)
                    .scrollPosition($position)
                    #endif
                )
                .mask {
                    HStack(spacing: 0) {
                        LinearGradient(colors: [edges.leading ? .clear : .black, .black], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 20)
                        Rectangle()
                        LinearGradient(colors: [.black, edges.trailing ? .clear : .black], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 28)
                    }
                }
                .environment(\.stripDrag, tracking.drag)
                #if os(macOS)
                .simultaneousGesture(dragToScroll)
                .overlay(alignment: arrowCenter == nil ? .center : .top) {
                    if overlayArrows {
                        HStack {
                            if edges.leading { arrow(forward: false) }
                            Spacer(minLength: 0)
                            if edges.trailing { arrow(forward: true) }
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, arrowCenter.map { max(0, $0 - 17) } ?? 0)
                    }
                }
                #endif
                #if os(macOS)
                if !overlayArrows, edges.leading || edges.trailing {
                    HStack(spacing: 4) { arrow(forward: false); arrow(forward: true) }
                }
                #endif
            }
            .onAppear {
                guard let scrollTo else { return }
                #if os(macOS)
                position.scrollTo(id: scrollTo, anchor: .center)
                #else
                proxy.scrollTo(scrollTo, anchor: .center)
                #endif
            }
            #if os(iOS)
            // A choice made away from the strip (swiping the Sources page, #1052) brings its chip into view; one
            // already in view stays put.
            .onChange(of: scrollTo) { _, id in
                guard let id else { return }
                withAnimation(.snappy(duration: 0.3)) { proxy.scrollTo(id) }
            }
            #endif
        }
    }

    private func update(_ metrics: Metrics) {
        tracking.metrics = metrics
        let next = Edges(leading: metrics.offset > 1, trailing: metrics.offset < metrics.maximum - 1)
        if next != edges { edges = next }
    }

    @ViewBuilder private func measured(_ scrollView: some View) -> some View {
        if #available(iOS 18, *) {
            scrollView.onScrollGeometryChange(for: Metrics.self) { geometry in
                Metrics(offset: geometry.contentOffset.x + geometry.contentInsets.leading,
                        viewport: geometry.containerSize.width,
                        maximum: max(0, geometry.contentSize.width + geometry.contentInsets.leading
                            + geometry.contentInsets.trailing - geometry.containerSize.width))
            } action: { _, metrics in update(metrics) }
        } else {
            scrollView
        }
    }

    /// Before iOS 18 the scroll view cannot report its geometry, so the content measures the part of
    /// itself that is on screen.
    @ViewBuilder private var measuredContent: some View {
        if #available(iOS 18, *) {
            content
        } else {
            content.onGeometryChange(for: Metrics.self) { geometry in
                let visible = geometry.bounds(of: .scrollView(axis: .horizontal)) ?? .zero
                return Metrics(offset: visible.minX, viewport: visible.width, maximum: max(0, geometry.size.width - visible.width))
            } action: { update($0) }
        }
    }

    #if os(macOS)
    /// Mouse users can grab the strip like a trackpad swipe, with momentum on release.
    private var dragToScroll: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let origin = tracking.dragOrigin ?? tracking.metrics.offset
                tracking.dragOrigin = origin
                tracking.drag.active = true
                position.scrollTo(x: tracking.clamp(origin - value.translation.width))
            }
            .onEnded { value in
                let origin = tracking.dragOrigin ?? tracking.metrics.offset
                tracking.dragOrigin = nil
                withAnimation(.smooth(duration: 0.45)) {
                    position.scrollTo(x: tracking.clamp(origin - value.predictedEndTranslation.width))
                }
                let drag = tracking.drag
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(120))
                    drag.active = false
                }
            }
    }

    private func arrow(forward: Bool) -> some View {
        let enabled = forward ? edges.trailing : edges.leading
        let label = L10n.text(forward ? rightLabel : leftLabel)
        return Button {
            let step = max(1, tracking.metrics.viewport * 0.8)
            withAnimation(.smooth(duration: 0.3)) {
                position.scrollTo(x: tracking.clamp(tracking.metrics.offset + (forward ? step : -step)))
            }
        } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.system(size: overlayArrows ? 14 : 11, weight: .bold))
                .frame(width: overlayArrows ? 34 : 26, height: overlayArrows ? 34 : 26)
                .background(Color.primary.opacity(0.07), in: Circle())
                .glassSurface(overlayArrows ? .regular.interactive() : .identity, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .primary : .tertiary)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .help(label)
    }
    #endif
}
