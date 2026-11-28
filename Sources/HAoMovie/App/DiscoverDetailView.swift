import SwiftUI

/// A Douban title's page: its cover tints the page, its name and facts sit under it, and its episodes
/// are found on the viewer's own sources while the page is on screen.
///
/// This is Yingxia's `DiscoverDetailView` with the TMDB half left out: no logo title, no TMDB rating,
/// no cast, crew, studios, genres, stills, trailer, facts or recommendations — those all need the TMDB
/// Worker, which is not deployed. What is here is the shell Yingxia draws around them (painted backdrop,
/// centred identity, 54-point action capsule, source auto-search with Change Source), filled with the
/// Douban title's own facts. The TMDB sections join when the Worker lands; nothing here invents TMDB data.
struct DiscoverDetailView: View {
    @Environment(Store.self) private var store
    @Environment(\.colorScheme) private var appColorScheme
    let item: DoubanCatalog.Item
    @State private var scrollY: CGFloat = 0
    @State private var paint: DiscoverPaint?
    @State private var onScreen = false
    @State private var sources: DiscoverSources?
    @State private var seasonNumber: Int?
    private var dark: Bool { paint?.isDark ?? true }

    var body: some View {
        page
            .onAppear { onScreen = true; startSources() }
            .onDisappear { onScreen = false; stopSources() }
            .onChange(of: store.subscription?.importedAt) { _, _ in startSources() }
            // A video playing over the page (the player covers it without the page going away) pauses the search for the
            // title's other sources until it closes: their plugins ran flat out under the video and warmed the phone.
            .onChange(of: store.playing == nil) { _, idle in if idle { startSources() } else { stopSources() } }
            .task(id: item.id) {
                guard paint == nil, let cover = item.cover else { return }
                paint = await DiscoverPainter.shared.paint(cover)
            }
    }

    @ViewBuilder private var page: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let coverHeight = width < 600 ? width * 1.5 : min(760, width * 0.7)
            ZStack(alignment: .top) {
                DiscoverDetailBackdrop(paint: paint, width: width, heroHeight: coverHeight, scrollY: scrollY)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 32) {
                        identity(width: width)
                        discoverEpisodes
                    }.padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
                .modifier(DiscoverScrollObserver(offset: $scrollY))
            }
        }
        .foregroundStyle(dark ? Color.white : Color.black)
        .environment(\.colorScheme, dark ? .dark : .light)
        .ignoresSafeArea(edges: .top)
        .navigationTitle("")
        #if os(macOS)
        .artUnderToolbar(dark ? .dark : .light)
        #else
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(dark ? .dark : .light, for: .navigationBar)
        #endif
    }

    private func identity(width: CGFloat) -> some View {
        VStack(spacing: 16) {
            Color.clear.frame(height: width < 600 ? width * 0.95 : width * 0.25)
            Text(item.title).font(.system(size: 38, weight: .semibold))
                .multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.6)
                .frame(minHeight: 70)
            Text(metadata).font(.system(size: 13)).multilineTextAlignment(.center).opacity(0.88)
            HStack(spacing: 12) {
                sourceButton
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 0)
        #if os(macOS)
        .frame(maxWidth: 640)
        #endif
        .frame(maxWidth: .infinity)
    }

    private var metadata: String {
        var values: [String] = []
        if let year = item.year { values.append(String(year)) }
        // Douban's subtitle reads "2026 / 中国大陆 / 剧情 / <director> / <cast>": country, then genre.
        var parts = item.subtitle.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        if let year = item.year, parts.first == String(year) { parts.removeFirst() }
        values += parts.prefix(2)
        // No TMDB badge to carry the score: the Douban score rides in the facts line.
        if let rating = item.rating {
            values.append(L10n.text("Douban") + " " + rating.formatted(.number.precision(.fractionLength(1))))
        }
        return values.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The most recent unfinished watch for this title, if any. Continue Playing takes the place of Search Sources,
    /// which the page already does on its own, and carries on where the viewer stopped. iPhone only.
    #if os(iOS)
    private var resumeEntry: PlaybackHistoryEntry? {
        let names = [item.title, DoubanCatalog.searchTitle(item)].map { $0.trimmingCharacters(in: .whitespaces) }
        return store.playbackHistory.entries
            .filter { !$0.completed }
            // The same name only: a name inside another ("家" in "一家人", a first season in its sequel's "… 第二季") would
            // carry on with a different title. Without one, Search Sources finds it.
            .filter { entry in
                names.contains { name in
                    entry.context.videoName.trimmingCharacters(in: .whitespaces)
                        .compare(name, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame
                }
            }
            .max(by: { $0.updatedAt < $1.updatedAt })
    }

    private func continueButton(_ entry: PlaybackHistoryEntry) -> some View {
        Button {
            store.resume(entry)
        } label: {
            VStack(spacing: 3) {
                Label(L10n.text("Continue Playing"), systemImage: "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                Text(HistoryFormat.status(entry)).font(.system(size: 12)).opacity(0.8)
            }
            .frame(maxWidth: .infinity).frame(height: 54)
            .foregroundStyle(dark ? Color.black : Color.white)
            .background(dark ? Color.white : Color.black, in: Capsule())
        }
        .buttonStyle(.plain).accessibilityIdentifier("discover.continuePlaying")
    }
    #endif

    @ViewBuilder private var sourceButton: some View {
        #if os(iOS)
        if let entry = resumeEntry { continueButton(entry) } else { searchButton }
        #else
        searchButton
        #endif
    }

    private var searchButton: some View {
        Button {
            if store.subscription == nil { store.section = .settings }
            else { store.searchVideos(DoubanCatalog.searchTitle(item)) }
        } label: {
            Label(L10n.text(store.subscription == nil ? "Add Subscription" : "Search Sources"), systemImage: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 54)
                .foregroundStyle(dark ? Color.black : Color.white)
                .background(dark ? Color.white : Color.black, in: Capsule())
        }.buttonStyle(.plain).accessibilityIdentifier("discover.findSources")
    }

    /// The title's sources start searching when the page shows, with a subscription to search, and pause when it goes
    /// or a video plays over it.
    private func startSources() {
        guard onScreen, store.playing == nil else { return }
        guard store.subscription != nil else {
            stopSources()
            sources = nil
            return
        }
        let model = sources ?? DiscoverSources.of(item)
        if sources == nil { sources = model }
        model.start(store)
    }
    private func stopSources() {
        sources?.stop()
    }

    @ViewBuilder private var discoverEpisodes: some View {
        if let sources {
            DiscoverSourceEpisodes(sources: sources, item: item, appColorScheme: appColorScheme, selectedSeason: $seasonNumber,
                                   seasonControl: { _ in nil }) { _ in EmptyView() }
        } else {
            // No subscription: the title still shows, and the page says what it needs.
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("Episodes")).font(.system(size: DiscoverLayout.heading, weight: .semibold))
                Text(L10n.text("Add a subscription to search your sources for this title."))
                    .font(.subheadline).foregroundStyle(.secondary)
                Button { store.section = .settings } label: {
                    Label(L10n.text("Add Subscription"), systemImage: "magnifyingglass")
                }
                #if os(tvOS)
                .glassPill()
                #else
                .controlButton()
                #endif
                .accessibilityIdentifier("discover.sources.search")
            }
            .padding(.horizontal, 16)
        }
    }
}

/// The title's sources; the last dozen titles opened keep theirs.
@MainActor @Observable final class DiscoverSources {
    let search = SearchModel()
    /// The results that are the title, best first (`SourceTitleMatch.ranked`).
    private(set) var matches: [SourceTitleMatch.Candidate] = []
    /// The one whose episodes show: the best match, or the one chosen under Change Source.
    private(set) var chosen: SourceTitleMatch.Candidate?
    /// Every source asked has answered.
    private(set) var finished = false
    @ObservationIgnored private let keyword: String
    @ObservationIgnored private let wanted: SourceTitleMatch.Wanted
    @ObservationIgnored private var found: [SourceTitleMatch.Candidate] = []
    /// The Watch Now row's order, by source key: the best match comes from the source highest in it.
    @ObservationIgnored private var order: [String: Int] = [:]
    @ObservationIgnored private var subscription: String?
    /// Answers still being matched off the main thread.
    @ObservationIgnored private var pending = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var grace: Task<Void, Never>?

    private static var kept: [String: DiscoverSources] = [:]
    private static var recent: [String] = []

    static func of(_ item: DoubanCatalog.Item) -> DiscoverSources {
        recent.removeAll { $0 == item.id }
        recent.append(item.id)
        if let sources = kept[item.id] { return sources }
        let sources = DiscoverSources(item)
        kept[item.id] = sources
        if recent.count > 12 { kept[recent.removeFirst()] = nil }
        return sources
    }

    private init(_ item: DoubanCatalog.Item) {
        keyword = DoubanCatalog.searchTitle(item)
        wanted = SourceTitleMatch.Wanted(names: [item.title], year: item.year)
    }

    /// The page is on screen: the first time it searches; later it carries on a search the page left unfinished.
    func start(_ store: Store) {
        guard let config = store.subscription else { return }
        let identity = "\(config.origin)|\(config.importedAt.timeIntervalSince1970)"
        if subscription != identity {
            subscription = identity
            generation += 1; pending = 0
            grace?.cancel(); grace = nil
            found = []; matches = []; chosen = nil; finished = false
            search.reset()
        }
        order = Dictionary(store.recommendationSites(config).enumerated().map { ($1.key, $0) }) { first, _ in first }
        search.order = store.sourceOrder
        search.onResult = { [weak self] in self?.absorb($0) }
        if search.keyword.isEmpty {
            let hidden = store.hiddenSources
            // A title is a film or a series. A listening source's album or chapter with the same name is not
            // it, and its episodes open in the music player, so those sources are not asked.
            search.search(keyword, config: config) { site in
                hidden.contains(site, origin: config.origin) || Self.isAudioSource(site)
            }
            // Answered from the model's own cache, the results are in already.
            search.results.forEach(absorb)
        } else if search.suspended {
            search.resumeSuspended(config: config)
        }
        settle()
    }

    /// The page left: the search pauses (the sources that answered keep their results), and so does the wait to choose.
    func stop() {
        search.suspend()
        grace?.cancel(); grace = nil
    }

    func choose(_ candidate: SourceTitleMatch.Candidate) {
        grace?.cancel(); grace = nil
        chosen = candidate
    }

    /// Whether a source serves listening rather than watching (audiobooks, radio, music): its episodes open in
    /// the music player, so the title page does not ask it. Yingxia's `AudioSources.isCandidate`, kept here
    /// because this tree has no `AudioSources` type (the rest of it — queues, verdicts — lives with the music
    /// player, which was not ported).
    private static func isAudioSource(_ site: Site) -> Bool {
        isAudioSource(name: site.name, api: site.api)
    }

    private static func isAudioSource(name: String, api: String) -> Bool {
        /// Words in a source's name that mean listening. Not 儿歌: those sources mostly serve cartoon videos (BabyBus, Beva).
        let audioWords = ["听书", "有声", "音乐", "电台", "广播", "相声", "评书", "播客", "舞曲", "听歌", "FM", "Radio", "Podcast"]
        /// Words that mean video even beside one of those: dance lessons (跳舞┃教学), opera (戏曲), karaoke (KTV┃音乐), MVs.
        let videoWords = ["跳舞", "舞蹈", "教学", "戏曲", "视频", "MV", "KTV", "直播", "影视", "电影", "短剧", "动漫", "4K"]
        /// Spider classes that only serve audio, whatever the source is called.
        let audioClasses = ["tingshu", "audiobook", "ximalaya", "podcast", "radio"]
        if videoWords.contains(where: { name.localizedCaseInsensitiveContains($0) }) { return false }
        if audioWords.contains(where: { name.contains($0) }) { return true }
        let spider = api.lowercased()
        return audioClasses.contains { spider.contains($0) }
    }

    private func absorb(_ result: SearchSourceResult) {
        guard let videos = result.page?.videos, !videos.isEmpty else { settle(); return }
        let site = result.site, wanted = wanted, generation = generation
        pending += 1
        Task {
            // Normalizing titles (traditional to simplified, widths) runs off the main thread, once per answer.
            let more = await Task.detached(priority: .userInitiated) { SourceTitleMatch.candidates(videos, site: site, wanted: wanted) }.value
            guard generation == self.generation else { return }
            pending -= 1
            if !more.isEmpty {
                found += more
                matches = SourceTitleMatch.ranked(found, sourceOrder: order)
            }
            settle()
        }
    }

    /// The best match shows once nothing can beat it (the title itself, from its year), once every source answered, or
    /// four seconds after the first match, so a slow source doesn't hold the page up. Then it stays: a better match
    /// that comes later goes under Change Source rather than swapping the episodes under the viewer.
    private func settle() {
        let done = pending == 0 && !search.suspended && search.completed >= search.total
        if finished != done { finished = done }
        guard chosen == nil, let best = matches.first else { return }
        if done || best.decisive { choose(best); return }
        guard grace == nil else { return }
        grace = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self, self.chosen == nil, let best = self.matches.first else { return }
            self.choose(best)
        }
    }
}

/// One episode section uses source playback when available and catalog episodes while it searches.
/// There are no catalog episodes here (they are TMDB seasons): the fallback is empty until the Worker lands.
private struct DiscoverSourceEpisodes<CatalogEpisodes: View>: View {
    @Environment(Store.self) private var store
    let sources: DiscoverSources
    let item: DoubanCatalog.Item
    let appColorScheme: ColorScheme
    @Binding var selectedSeason: Int?
    let seasonControl: (Int) -> AnyView?
    @ViewBuilder let catalogEpisodes: (Int?) -> CatalogEpisodes
    @State private var changing = false

    private var currentMatch: SourceTitleMatch.Candidate? {
        guard let selectedSeason else { return sources.chosen }
        if let chosen = sources.chosen, Self.season(of: chosen) == selectedSeason { return chosen }
        return sources.finished ? sources.matches.first { Self.season(of: $0) == selectedSeason } : nil
    }

    private static func season(of match: SourceTitleMatch.Candidate) -> Int {
        SeasonTitles.parse(match.video.name).season ?? 1
    }

    var body: some View {
        Group {
            if let chosen = currentMatch, let config = store.subscription {
                let number = Self.season(of: chosen)
                VideoDetailView(video: chosen.video, client: CatalogClient(site: chosen.site, origin: config.origin, jarURL: config.spiderURL),
                                embed: DetailEmbed(season: number, seasonControl: seasonControl(number),
                                                   catalogFallback: { AnyView(catalogEpisodes(number)) },
                                                   changeSource: { changing = true }, appColorScheme: appColorScheme))
                    .id(chosen.id)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 12) {
                        heading
                        if sources.finished {
                            Text(L10n.text(selectedSeason == nil ? "None of your sources has this title." : "None of your sources has this season."))
                                .font(.subheadline).foregroundStyle(.secondary)
                            Button {
                                if sources.matches.isEmpty { store.searchVideos(DoubanCatalog.searchTitle(item)) } else { changing = true }
                            } label: {
                                Label(L10n.text(sources.matches.isEmpty ? "Search Sources" : "Change Source"), systemImage: "magnifyingglass")
                            }
                            #if os(tvOS)
                            .glassPill()
                            #else
                            .controlButton()
                            #endif
                            .accessibilityIdentifier("discover.sources.search")
                        } else {
                            searchProgress.accessibilityIdentifier("discover.sources.searching")
                        }
                    }
                    .padding(.horizontal, horizontalInset)
                    catalogEpisodes(nil)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(tvOS)
        .fullScreenCover(isPresented: $changing) { picker.task { sources.start(store) } }
        #else
        .sheet(isPresented: $changing) {
            // Passed on by hand: an iPad app on a Mac lost the store in sheets (#1163).
            // The page draws in its art's look (white text, dark scheme) and the sheet inherits both, while its
            // background follows the app: on iOS 17 and 18 the sources were white on white (#1355, #1356).
            // `Color.primary`, not `.primary`: that is the inherited style's first level, the page's white.
            picker.foregroundStyle(Color.primary).environment(\.colorScheme, appColorScheme).preferredColorScheme(appColorScheme)
        }
        #endif
    }

    private var picker: some View {
        DiscoverSourcePicker(sources: sources, selected: currentMatch) { match in
            sources.choose(match)
            selectedSeason = Self.season(of: match)
        }
        .environment(store)
    }

    private var horizontalInset: CGFloat {
        #if os(tvOS)
        DiscoverLayout.gutter
        #else
        16
        #endif
    }

    private var heading: some View {
        Text(L10n.text("Episodes")).font(.system(size: DiscoverLayout.heading, weight: .semibold))
    }

    @ViewBuilder private var searchProgress: some View {
        let search = sources.search
        if search.total > 0 {
            ProgressView(value: Double(search.completed), total: Double(search.total)) {
                Text(L10n.text("Searching for sources…")).font(.subheadline)
            } currentValueLabel: {
                Text(L10n.text("Searched %lld of %lld sources", search.completed, search.total))
                    .font(.footnote).monospacedDigit()
            }
            .progressViewStyle(.linear)
            if !search.activeSources.isEmpty {
                let names = search.activeSources.map { SourceLabel($0.site.name).text }.joined(separator: " · ")
                Text(L10n.text("Searching %@…", names))
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
        } else {
            HStack(spacing: 10) {
                ProgressView().appControlSize(.small)
                Text(L10n.text("Searching for sources…")).font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
        }
    }
}

/// Change Source: the results that are the title, as they arrive, the one showing checked. As a book's source picker.
private struct DiscoverSourcePicker: View {
    let sources: DiscoverSources
    let selected: SourceTitleMatch.Candidate?
    let choose: (SourceTitleMatch.Candidate) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(tvOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text(L10n.text("Change Source")).font(.title2.bold())
                    Spacer()
                    Button(L10n.text("Done")) { dismiss() }.glassPill()
                }
                LazyVStack(spacing: 14) { options }
            }
            .padding(.horizontal, DiscoverLayout.gutter).padding(.vertical, 48)
        }
        .background { Color.black.ignoresSafeArea() }
        .preferredColorScheme(.dark)
        #else
        NavigationStack {
            List { options }
            .navigationTitle(L10n.text("Change Source"))
            #if os(iOS)
            .listStyle(.insetGrouped)
            .navigationBarTitleDisplayMode(.inline)
            #else
            .listStyle(.inset)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { dismiss() } } }
        }
        .foregroundStyle(.primary)
        .tint(.accentColor)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
        #else
        .frame(minWidth: 460, minHeight: 420)
        #endif
        #endif
    }

    @ViewBuilder private var options: some View {
        ForEach(sources.matches) { match in
            let checked = match.id == selected?.id
            Button { choose(match); dismiss() } label: {
                NovelRow(symbol: checked ? "checkmark.circle.fill" : "circle", title: SourceLabel(match.site.name).text,
                         detail: match.video.remarks.isEmpty ? match.video.year ?? "" : match.video.remarks, note: match.video.name)
            }
            #if os(tvOS)
            .glassRow()
            #else
            .buttonStyle(.plain)
            #endif
            .accessibilityAddTraits(checked ? .isSelected : [])
            .accessibilityIdentifier("discover.sources.option")
        }
        if !sources.finished {
            HStack(spacing: 10) {
                ProgressView().appControlSize(.small)
                Text(L10n.text("Searched %lld of %lld sources", sources.search.completed, sources.search.total))
                    .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
            }
        } else if sources.matches.isEmpty {
            Text(L10n.text("None of your sources has this title.")).foregroundStyle(.secondary)
        }
    }
}

/// The title's cover behind the page, in the cover's own colour, fading into the app's background below it.
/// `DiscoverBackdrop`'s still half, without its trailer: the trailer half joins when the TMDB Worker serves trailers.
private struct DiscoverDetailBackdrop: View {
    let paint: DiscoverPaint?
    let width: CGFloat
    let heroHeight: CGFloat
    let scrollY: CGFloat
    var body: some View {
        ZStack(alignment: .top) {
            (paint?.color ?? Color(white: 0.06))
            if let paint {
                Image(decorative: paint.image, scale: 1).resizable().scaledToFill()
                    .frame(width: width, height: heroHeight)
                    .scaleEffect(1.2 + max(0, -scrollY) / max(heroHeight, 1), anchor: .center)
                    .offset(y: -scrollY * 0.78)
                    .opacity(max(0, 1 - max(0, scrollY - heroHeight * 0.45) / (heroHeight * 0.55)))
                    .frame(width: width, height: heroHeight, alignment: .top).clipped()
                    .mask {
                        LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.72),
                                               .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
                    }
            }
        }
        .discoverFullBleed()
        .accessibilityHidden(true)
    }
}
