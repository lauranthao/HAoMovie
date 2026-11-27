import SwiftUI

@MainActor @Observable final class Store {
    let searchModel = SearchModel()
    let recommendationModel = RecommendationModel()
    /// The profile whose library is open (#1456). Everything below that is a `private(set) var` is that profile's, and
    /// `openProfile(_:)` replaces it with another's.
    private(set) var profile: Profile
    private(set) var playbackHistory: PlaybackHistory
    private(set) var playbackDefaults: UserDefaults
    private(set) var pinnedSources: PinnedSources
    private(set) var hiddenSources: HiddenSources
    /// Live platforms and playlists the viewer turned off (#601, #837).
    private(set) var hiddenLiveSources: HiddenLiveSources
    private(set) var sourceOrder: SourceOrder
    /// The history entry being resumed; another entry, or leaving the page, replaces or cancels it.
    private(set) var resumingHistoryID: String?
    private var resumeTask: Task<Void, Never>?
    /// Every enabled subscription merged in list order, plus configured cloud drives.
    var subscription: Subscription?
    /// The address being typed in to add a subscription.
    var subscriptionAddress: String
    /// What to call the subscription being added; empty shows where it lives instead.
    var subscriptionName = ""
    /// Every subscription the viewer added, in the order they merge.
    var subscriptions: [SubscriptionEntry] = []
    /// Why a subscription last failed to refresh, by address; its last good copy stays in use.
    var subscriptionErrors: [String: String] = [:]
    /// The last good copy of each subscription, by address.
    private(set) var documents: [String: Subscription] = [:]
    private(set) var favorites: Favorites
    var importing = false
    var error: String?
    /// Why the last subscription import failed. It shows under the address field, not in the app-wide alert: on
    /// iPhone and iPad that alert closed the Add Subscription sheet over it and took the viewer out of the form (#357).
    var importError: String?
    var notice: String?
    var playing: Channel?
    /// The channels the live channel playing was picked from, in order (its playlist, or the favorites): the player's
    /// Previous and Next Channel and its channel list go through them (#1010).
    var liveLineup: LiveLineup?
    /// The program guide of the playlist `liveLineup` is (#802).
    private(set) var liveGuide: LiveGuide?
    /// Plays a live channel picked from `lineup`, with its playlist's guide.
    func watch(_ channel: Channel, in lineup: LiveLineup, guide: LiveGuide? = nil) {
        liveLineup = lineup
        liveGuide = guide
        playing = channel
    }
    /// Plays a favorite live channel with the other favorite channels to switch through, wherever it was picked: the
    /// Live page, Watch Now or the Favorites page (#1172).
    func watchFavorite(_ channel: Channel) {
        watch(channel, in: LiveLineup(title: L10n.text("Favorites"), channels: favorites.liveChannels))
    }
    /// The guide of the list the channel was picked from.
    func guide(for channel: Channel) -> LiveGuide? {
        liveLineup?.channels.contains(where: { $0.id == (channel.replay?.channelID ?? channel.id) }) == true ? liveGuide : nil
    }
    /// The list for the channel panel of a channel that can replay programs (or a replay): even a list of one.
    func replayLineup(for channel: Channel) -> LiveLineup? {
        guard guide(for: channel) != nil, let live = liveChannel(for: channel),
              channel.replay != nil || ProgramCatchup.supports(live) else { return nil }
        return liveLineup
    }
    /// Keeps replay out of channel navigation while allowing an explicit return to its source channel.
    func liveChannel(for channel: Channel) -> Channel? {
        guard let id = channel.replay?.channelID else { return channel }
        return liveLineup?.channels.first { $0.id == id }
    }
    /// Program guide addresses the viewer typed in for live playlists, by playlist address (#802).
    var guideAddresses: [String: String] {
        didSet { if persistsChanges { defaults.set(guideAddresses, forKey: "liveGuideAddresses") } }
    }
    /// The list the channel was picked from, when it holds others to switch to.
    func lineup(for channel: Channel) -> LiveLineup? {
        guard channel.replay == nil, let lineup = liveLineup, lineup.channels.count > 1, lineup.position(of: channel) != nil else { return nil }
        return lineup
    }
    /// The videos whose iPhone watch page is on screen (`PlaybackHistoryContext.id`): their episodes play at the top
    /// of the page instead of in the full-screen player.
    var watchPageScopes: Set<String> = []
    func playsInWatchPage(_ channel: Channel?) -> Bool {
        guard let scope = channel?.historyContext?.id else { return false }
        return watchPageScopes.contains(scope)
    }
    /// The catalog search sheets on screen, the topmost last: a video picked in one plays in that sheet, so the
    /// sheet presents the player itself. The app's own cover is under the sheet, and a second presentation from
    /// there tears the sheet down (#1618).
    var catalogSearchSheets: [UUID] = []
    var playbackCatalog: PlaybackCatalog?
    /// The Cloud Files folder the playing file came from; its next file plays after it.
    var filesFolder: CloudFilesFolder?
    var resolvingEpisode: Episode?
    var episodeError: String?
    var autoPlayNext: Bool {
        didSet { if persistsChanges { defaults.set(autoPlayNext, forKey: "autoPlayNextEpisode") } }
    }
    private var episodeRequest = UUID()
    private var episodeTask: Task<Void, Never>?
    /// The next episode's stream, resolved while a short episode plays (#1021, #900): Next, the end of the episode and
    /// the queue start it without asking the source again, so the cover no longer waits on the source each time.
    @ObservationIgnored private var nextAhead: (episode: Episode, resolved: Channel, at: Date)?
    @ObservationIgnored private var nextAheadTask: (episode: Episode, task: Task<Void, Never>)?
    /// Signed links expire: one resolved longer ago than this is asked for again.
    static let nextAheadLifetime: TimeInterval = 5 * 60
    /// Episodes this long or shorter (short dramas, clips) have the next one resolved while they play. A longer one's
    /// is resolved 30 seconds before its end for the queue, as before.
    static let nextAheadLength: Double = 10 * 60
    var section: AppSection = .home
    /// The Mac sidebar folds away while the manga reader fills the window, and comes back when it closes.
    /// macOS 26 floats the sidebar over the page, so it covered the left part of every comic page.
    var hidesSidebar = false
    /// Whether the open profile itself has an enabled subscription with sources or live playlists.
    private var currentProfileUnlocksExtras: Bool {
        subscriptions.contains { $0.enabled && documents[$0.address].map { !$0.sites.isEmpty || !$0.lives.isEmpty } == true }
    }
    /// Whether another profile on this device has a working subscription, updated when subscriptions or profiles
    /// change so `extrasUnlocked` does no disk work inside view bodies (#1853).
    private var otherProfileUnlocksExtras = false
    /// Unlock additional sections once any profile has an enabled subscription with sources or live playlists.
    var extrasUnlocked: Bool {
        currentProfileUnlocksExtras || otherProfileUnlocksExtras
    }
    /// Sections kept out of the tab bar and sidebar until then. Music, manga and novels are not in this build.
    var hiddenSections: [AppSection] { [] }
    /// The open profile's defaults: the main defaults for the main profile.
    private var defaults: UserDefaults
    /// The main defaults, which QA's switches are read from.
    private let baseDefaults: UserDefaults
    /// Where the open profile keeps its subscription copies; nil for the main profile's usual place.
    private var profileFolder: URL?
    private let http = HTTPClient()
    /// Rebuilt source rows are expensive (every source is classified and copied) and Watch Now reads
    /// them many times while drawing one frame. The stamp is the inputs, so a later frame reuses the row.
    /// Not observed: views fill these while drawing, and a write would draw every reader again.
    @ObservationIgnored private var siteListStamp = ""
    /// Every live source, hidden ones too: the subscription's live playlists.
    var allLiveSources: [LiveSource] { subscription?.lives ?? [] }
    /// Live TV's sources: the ones the viewer hasn't hidden.
    var liveSources: [LiveSource] { allLiveSources.filter { !hiddenLiveSources.contains($0) } }
    /// Playback history whose source is not hidden.
    var visibleHistory: [PlaybackHistoryEntry] { playbackHistory.visibleEntries(hiding: hiddenSources) }
    /// The live playlists among `sources` by the subscription that lists them (#815).
    func livePlaylistGroups(_ sources: [LiveSource]) -> [LivePlaylistGroup] {
        LivePlaylistGroup.make(sources, subscriptions: subscriptions.filter(\.enabled).compactMap { entry in documents[entry.address].map { (entry, $0) } })
    }
    /// The subscription that is just this playlist, which removing the playlist removes.
    func playlistSubscription(_ source: LiveSource) -> SubscriptionEntry? {
        subscriptions.first { entry in documents[entry.address].map { $0.isPlaylistOnly && $0.lives.contains { $0.url == source.url } } == true }
    }
    @ObservationIgnored private var automaticCache: [Site]?
    @ObservationIgnored private var orderedCache: [Site]?
    @ObservationIgnored private var recommendationCache: [Site]?
    @ObservationIgnored private var groupsCache: [Bool: [SourceGroup]] = [:]
    /// What the cached rows were built from: the merged subscription, which subscriptions are on, and the viewer's pins, hides, and order.
    private func currentSiteListStamp() -> String {
        let imported = subscription?.importedAt.timeIntervalSince1970 ?? 0
        let entries = subscriptions.map { "\($0.address)=\($0.enabled)" }.joined(separator: "\n")
        return "\(subscription?.origin.absoluteString ?? "")|\(imported)|\(subscription?.sites.count ?? 0)|\(entries)|\(pinnedSources.revision)|\(hiddenSources.revision)|\(sourceOrder.revision)"
    }
    private var persistsChanges: Bool { !Self.isolated(baseDefaults) }
    /// QA's `-qaIsolatedData` runs, which save nothing of the library.
    private static func isolated(_ defaults: UserDefaults) -> Bool {
        #if DEBUG
        return defaults.bool(forKey: "qaIsolatedData")
        #else
        return false
        #endif
    }
    /// Where a profile's library lives: the main defaults and the shared history for the main profile (QA's isolated
    /// data keeps the player's apart), the profile's own suite and folder for the others.
    private static func library(for profile: Profile, base: UserDefaults)
        -> (defaults: UserDefaults, playback: UserDefaults, history: PlaybackHistory, folder: URL?) {
        if !profile.isMain, let folder = Profiles.shared.folder(for: profile) {
            let defaults = Profiles.shared.defaults(for: profile)
            return (defaults, defaults, PlaybackHistory(file: folder.appending(path: "playback-history-v1.json"), defaults: defaults), folder)
        }
        if isolated(base) {
            let player = UserDefaults(suiteName: "com.tvbox.yingxia.qa.player") ?? base
            return (base, player, PlaybackHistory(file: URL.cachesDirectory.appending(path: "qa-player-history.json"), defaults: player), nil)
        }
        return (base, base, .shared, nil)
    }
    init(defaults: UserDefaults = .standard) {
        #if os(macOS)
        if defaults === UserDefaults.standard { Self.adoptPreviousBundleDefaults(defaults) }
        #endif
        baseDefaults = defaults
        // Tests and QA's isolated data stay in the main profile.
        let profile = defaults === UserDefaults.standard && !Self.isolated(defaults) ? Profiles.shared.current : Profile.main
        self.profile = profile
        let library = Self.library(for: profile, base: defaults)
        self.defaults = library.defaults
        playbackDefaults = library.playback
        playbackHistory = library.history
        profileFolder = library.folder
        pinnedSources = PinnedSources(defaults: library.playback)
        hiddenSources = HiddenSources(defaults: library.playback)
        hiddenLiveSources = HiddenLiveSources(defaults: library.playback)
        sourceOrder = SourceOrder(defaults: library.playback)
        favorites = Favorites(defaults: library.defaults)
        autoPlayNext = library.defaults.object(forKey: "autoPlayNextEpisode") == nil || library.defaults.bool(forKey: "autoPlayNextEpisode")
        guideAddresses = library.defaults.dictionary(forKey: "liveGuideAddresses") as? [String: String] ?? [:]
        subscriptionAddress = ""
        loadSubscriptions(resetting: false)
        searchModel.order = sourceOrder
        DownloadLibrary.shared.resolver = { [weak self] item in
            guard let self else { throw CancellationError() }
            return try await self.resolveDownload(item)
        }
    }
    /// Reads the open profile's subscription list and the saved copy of each, then merges them.
    private func loadSubscriptions(resetting: Bool) {
        let saved = defaults.data(forKey: "subscriptions").flatMap { try? JSONDecoder().decode([SubscriptionEntry].self, from: $0) }
        var entries = saved ?? [], copies: [String: Subscription] = [:]
        for entry in entries {
            if let data = try? Data(contentsOf: file(for: entry)),
               let value = try? JSONDecoder().decode(Subscription.self, from: data) { copies[entry.address] = value }
        }
        // Builds before several subscriptions kept one, in subscription.json, and before that in defaults.
        let legacyAddress = saved == nil && profile.isMain ? defaults.string(forKey: "subscriptionAddress") : nil
        let legacy = legacyAddress == nil ? nil : (try? Data(contentsOf: Self.legacyFile)) ?? defaults.data(forKey: "subscription")
        if let legacyAddress {
            entries = [SubscriptionEntry(address: legacyAddress)]
            copies[legacyAddress] = legacy.flatMap { try? JSONDecoder().decode(Subscription.self, from: $0) }
        }
        subscriptions = entries
        documents = copies
        subscriptionErrors = [:]
        if persistsChanges, let legacyAddress {
            if let legacy, copies[legacyAddress] != nil { try? Self.save(legacy, to: file(for: entries[0])) }
            saveSubscriptionList()
            try? FileManager.default.removeItem(at: Self.legacyFile)
            defaults.removeObject(forKey: "subscription")
        }
        rebuildSubscription(resetting: resetting)
    }
    // MARK: Profiles (#1456)

    /// Whether this store uses `Profiles.shared` (ordinary app runs, not tests or QA's isolated data).
    private var usesProfiles: Bool { baseDefaults === UserDefaults.standard && !Self.isolated(baseDefaults) }

    /// Whether another profile can open now: not while a subscription loads into this one, nor in tests or QA's
    /// isolated data.
    var switchesProfiles: Bool { !importing && usesProfiles }

    /// Opens another profile's library in place of this one. What plays stops first, so its place is saved to the
    /// profile it belongs to; RootView is rebuilt for the new profile, so no page of the last one stays on screen.
    func openProfile(_ target: Profile) {
        guard target.id != profile.id, switchesProfiles else { return }
        playing = nil
        cancelEpisodeSelection(); cancelResume()
        nextAheadTask?.task.cancel(); nextAheadTask = nil; nextAhead = nil
        liveLineup = nil; liveGuide = nil; playbackCatalog = nil; filesFolder = nil; watchPageScopes = []; episodeError = nil
        Profiles.shared.select(target)
        profile = Profiles.shared.current
        let library = Self.library(for: profile, base: baseDefaults)
        defaults = library.defaults
        playbackDefaults = library.playback
        playbackHistory = library.history
        profileFolder = library.folder
        pinnedSources = PinnedSources(defaults: library.playback)
        hiddenSources = HiddenSources(defaults: library.playback)
        hiddenLiveSources = HiddenLiveSources(defaults: library.playback)
        sourceOrder = SourceOrder(defaults: library.playback)
        favorites = Favorites(defaults: library.defaults)
        searchModel.order = sourceOrder
        autoPlayNext = library.defaults.object(forKey: "autoPlayNextEpisode") == nil || library.defaults.bool(forKey: "autoPlayNextEpisode")
        guideAddresses = library.defaults.dictionary(forKey: "liveGuideAddresses") as? [String: String] ?? [:]
        subscriptionAddress = ""; subscriptionName = ""; error = nil; notice = nil; importError = nil
        // The new lists' revisions can match the old ones', so the cached rows go by hand.
        rememberSiteLists("")
        loadSubscriptions(resetting: true)
        section = .home
        Diagnostics.shared.record(.info, "profile", "opened \(profile.isMain ? "main" : "other") profile")
        Task { await restoreSubscription() }
    }

    /// Picks up a new name for the open profile.
    func profileRenamed() {
        if let renamed = Profiles.shared.all.first(where: { $0.id == profile.id }), renamed != profile { profile = renamed }
    }

    /// Re-checks whether another profile still unlocks shared sections after one is deleted (#1853).
    func profileRemoved() {
        refreshOtherProfileExtras()
    }

    /// Updates `otherProfileUnlocksExtras` when the open profile itself has no working subscription.
    private func refreshOtherProfileExtras() {
        let unlocked = usesProfiles && !currentProfileUnlocksExtras
            && Profiles.shared.hasWorkingSubscription(besides: profile, mainDirectory: Self.subscriptionDirectory)
        if otherProfileUnlocksExtras != unlocked { otherProfileUnlocksExtras = unlocked }
    }

    /// Reopen the download’s source with its subscription settings for both episode lists and refreshed media links.
    func downloadClient(for item: DownloadItem) throws -> CatalogClient {
        let config = subscription
        guard let site = config?.sites.first(where: { $0.key == item.source.siteKey }) else {
            throw TVError.unsupported(L10n.text("%@ is no longer in your subscription, so caching can't continue.", item.source.siteName))
        }
        let base = CatalogClient(site: site, origin: config?.origin ?? URL(string: "https://example.invalid/")!, jarURL: config?.spiderURL)
        return config.map { base.applying($0) } ?? base
    }

    private func resolveDownload(_ item: DownloadItem) async throws -> Channel {
        let client = try downloadClient(for: item)
        let plan = try await client.preparePlayback(item.source.episode, forDownload: true)
        return try await client.resolvePlayback(plan, choice: plan.choices[0])
    }
    /// Large subscriptions run to megabytes, past the defaults size limit that aborts tvOS apps,
    /// so each parsed subscription lives in a file. tvOS only offers Caches, which the system may purge;
    /// `restoreSubscription()` refetches what is gone from the saved addresses.
    private static var subscriptionDirectory: URL {
        #if os(tvOS)
        return URL.cachesDirectory
        #else
        return URL.applicationSupportDirectory
        #endif
    }
    private static var legacyFile: URL { subscriptionDirectory.appending(path: "subscription.json") }
    private func file(for entry: SubscriptionEntry) -> URL {
        (profileFolder ?? Self.subscriptionDirectory).appending(path: "subscriptions").appending(path: entry.cacheName)
    }
    private static func save(_ data: Data, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
    /// Refetches enabled subscriptions whose cached copy is gone.
    func restoreSubscription() async {
        let missing = subscriptions.filter { $0.enabled && documents[$0.address] == nil }
        guard !missing.isEmpty, !importing else { return }
        importing = true
        defer { importing = false }
        await fetch(missing)
    }
    /// Adds the typed address, or refreshes it when it is already in the list. A directory (多仓)
    /// adds every subscription it lists, switched off, for the viewer to choose from.
    /// `address` is one typed in Settings, or one a link or a file handed over; `name` labels it the way a
    /// typed name does, and stays empty for a file.
    func importSubscription(address: String? = nil, name: String? = nil) async {
        guard !importing else { return }
        importing = true; importError = nil; notice = nil
        defer { importing = false }
        var typed = (address ?? subscriptionAddress).trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let url = try WebAddress.resolve(typed: typed)
            switch try await http.subscriptionImport(url, fresh: true) {
            case .subscription(let value):
                let title = (address == nil ? subscriptionName : (name ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)
                let entry = SubscriptionEntry(address: url.absoluteString, name: title)
                if let index = subscriptions.firstIndex(where: { $0.address == entry.address }) {
                    subscriptions[index].enabled = true
                    if !title.isEmpty { subscriptions[index].name = title }
                } else { subscriptions.append(entry) }
                keep(value, for: entry)
                if persistsChanges { defaults.set(url.absoluteString, forKey: "subscriptionAddress") }
                notice = L10n.text("Imported sources: %lld · Live playlists: %lld", value.sites.count, value.lives.count)
            case .directory(let entries):
                let added = entries.filter { entry in !subscriptions.contains { $0.address == entry.address } }
                subscriptions += added
                notice = L10n.text("This address lists %lld subscriptions. They were added switched off; turn on the ones you want.", added.count)
            }
            if address == nil { subscriptionAddress = ""; subscriptionName = "" }
            saveSubscriptionList()
            rebuildSubscription()
        } catch {
            Diagnostics.shared.failure("subscription", "import host=\((try? WebAddress.resolve(typed: typed))?.host() ?? "-")", error)
            importError = L10n.text("Import failed: %@", error.localizedDescription)
        }
    }
    /// Fetches every enabled subscription again; one that fails keeps its last good copy.
    func refreshSubscriptions() async {
        guard !importing else { return }
        importing = true; importError = nil; notice = nil
        defer { importing = false }
        await fetch(subscriptions.filter(\.enabled))
        let failed = subscriptions.filter { $0.enabled && subscriptionErrors[$0.address] != nil }.count
        if failed > 0 { notice = L10n.text("%lld subscriptions could not be refreshed; their last copies stay in use.", failed) }
    }
    func setSubscription(_ entry: SubscriptionEntry, enabled: Bool) async {
        guard let index = subscriptions.firstIndex(where: { $0.address == entry.address }) else { return }
        subscriptions[index].enabled = enabled
        saveSubscriptionList()
        if enabled, documents[entry.address] == nil { await restoreSubscription() } else { rebuildSubscription() }
    }
    /// Names a subscription in Settings and Sources; an empty name shows where it lives again.
    func renameSubscription(_ entry: SubscriptionEntry, to name: String) {
        guard let index = subscriptions.firstIndex(where: { $0.address == entry.address }), subscriptions[index].name != name else { return }
        subscriptions[index].name = name
        saveSubscriptionList()
    }
    /// Points a subscription at another address: a mirror, or where it moved (#982). The new address must answer with a
    /// subscription. The entry keeps its name, place and switch, and what was saved against its sources (pins, hides,
    /// the source order, source health, Continue Watching, favorites, intro and outro times) follows it. Nil when it
    /// worked, else why not; nothing changes then.
    func changeSubscriptionAddress(_ entry: SubscriptionEntry, to typed: String) async -> String? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != entry.address, !importing else { return nil }
        importing = true
        defer { importing = false }
        let url: URL, value: Subscription
        do {
            url = try WebAddress.resolve(typed: text)
            guard url.absoluteString != entry.address else { return nil }
            guard !subscriptions.contains(where: { $0.address == url.absoluteString }) else {
                return L10n.text("Another subscription already uses this address.")
            }
            guard case .subscription(let fetched) = try await http.subscriptionImport(url, fresh: true) else {
                return L10n.text("This address doesn't hold a subscription. Add it as a new one instead.")
            }
            value = fetched
        } catch {
            Diagnostics.shared.failure("subscription", "change address host=\((try? WebAddress.resolve(typed: text))?.host() ?? "-")", error)
            return L10n.text("Couldn't load this address: %@", error.localizedDescription)
        }
        // The list may have changed while the address loaded.
        guard let index = subscriptions.firstIndex(where: { $0.address == entry.address }) else { return nil }
        guard !subscriptions.contains(where: { $0.address == url.absoluteString }) else {
            return L10n.text("Another subscription already uses this address.")
        }
        let old = documents[entry.address]?.origin ?? URL(string: entry.address)
        var moved = subscriptions[index]
        moved.address = url.absoluteString
        subscriptions[index] = moved
        documents[entry.address] = nil; subscriptionErrors[entry.address] = nil
        if persistsChanges { try? FileManager.default.removeItem(at: file(for: entry)) }
        keep(value, for: moved)
        // Another subscription answering from the same place keeps what was saved there.
        if let old, old.absoluteString != value.origin.absoluteString,
           !documents.values.contains(where: { $0.origin.absoluteString == old.absoluteString }) {
            moveSavedState(from: old, to: value.origin)
        }
        saveSubscriptionList()
        rebuildSubscription()
        return nil
    }
    private func moveSavedState(from old: URL, to new: URL) {
        pinnedSources.moveOrigin(from: old, to: new)
        hiddenSources.moveOrigin(from: old, to: new)
        sourceOrder.moveOrigin(from: old, to: new)
        SourceHealth.shared.moveOrigin(from: old, to: new)
        playbackHistory.moveOrigin(from: old, to: new)
        favorites.moveOrigin(from: old, to: new)
        EpisodeSkipSettings.moveOrigin(from: old, to: new, defaults: playbackDefaults)
    }
    func removeSubscription(_ entry: SubscriptionEntry) { removeSubscriptions([entry.address]) }
    /// Removes several subscriptions and their saved copies, then merges what is left once.
    func removeSubscriptions(_ addresses: Set<String>) {
        let removed = subscriptions.filter { addresses.contains($0.address) }
        guard !removed.isEmpty else { return }
        subscriptions.removeAll { addresses.contains($0.address) }
        for entry in removed {
            documents[entry.address] = nil; subscriptionErrors[entry.address] = nil
            if persistsChanges { try? FileManager.default.removeItem(at: file(for: entry)) }
        }
        saveSubscriptionList()
        rebuildSubscription()
    }
    /// Moves subscriptions to another place, as a drag in Arrange Subscriptions does (#1184).
    func moveSubscriptions(fromOffsets source: IndexSet, toOffset destination: Int) {
        let before = subscriptions.map(\.address)
        subscriptions.move(fromOffsets: source, toOffset: destination)
        guard subscriptions.map(\.address) != before else { return }
        saveSubscriptionList()
        rebuildSubscription()
    }
    /// Moves a subscription to the top or the bottom of the list.
    func moveSubscription(_ entry: SubscriptionEntry, toTop: Bool) {
        guard let index = subscriptions.firstIndex(where: { $0.address == entry.address }) else { return }
        moveSubscriptions(fromOffsets: IndexSet(integer: index), toOffset: toTop ? 0 : subscriptions.count)
    }
    /// Moves a subscription one place up (-1) or down (1); earlier subscriptions win duplicate sources.
    func moveSubscription(_ entry: SubscriptionEntry, by offset: Int) {
        guard let index = subscriptions.firstIndex(where: { $0.address == entry.address }),
              subscriptions.indices.contains(index + offset) else { return }
        subscriptions.swapAt(index, index + offset)
        saveSubscriptionList()
        rebuildSubscription()
    }
    func moveSourceGroup(_ address: String, onto target: String, includeHidden: Bool) {
        let shown = sourceGroups(includeHidden: includeHidden).compactMap { group -> String? in
            guard case .subscription(let value) = group.kind else { return nil }
            return value
        }
        let next = SubscriptionOrder.moving(address, onto: target, in: shown)
        guard next != shown else { return }
        subscriptions = SubscriptionOrder.applying(displayed: next, to: subscriptions)
        saveSubscriptionList()
        rebuildSubscription()
    }

    /// Fetches subscriptions side by side, keeps what arrives, and shows the merged result. A
    /// subscription that turns out to be a directory is replaced by the ones it lists, switched off.
    private func fetch(_ entries: [SubscriptionEntry]) async {
        let http = http
        let results = await withTaskGroup(of: (SubscriptionEntry, Result<SubscriptionImport, any Error>).self) { group in
            for entry in entries {
                group.addTask {
                    do { return (entry, .success(try await http.subscriptionImport(WebAddress.resolve(entry.address)))) }
                    catch { return (entry, .failure(error)) }
                }
            }
            var all: [(SubscriptionEntry, Result<SubscriptionImport, any Error>)] = []
            for await result in group { all.append(result) }
            return all
        }
        for (entry, result) in results {
            switch result {
            case .success(.subscription(let value)): keep(value, for: entry)
            case .success(.directory(let listed)):
                guard let index = subscriptions.firstIndex(where: { $0.address == entry.address }) else { continue }
                let known = Set(subscriptions.map(\.address))
                subscriptions.replaceSubrange(index...index, with: listed.filter { !known.contains($0.address) })
            case .failure(let error):
                Diagnostics.shared.failure("subscription", "refresh host=\(URL(string: entry.address)?.host() ?? "-")", error)
                subscriptionErrors[entry.address] = error.localizedDescription
            }
        }
        saveSubscriptionList()
        rebuildSubscription()
    }
    private func keep(_ value: Subscription, for entry: SubscriptionEntry) {
        documents[entry.address] = value
        subscriptionErrors[entry.address] = nil
        if persistsChanges, let data = try? JSONEncoder().encode(value) { try? Self.save(data, to: file(for: entry)) }
    }
    private func saveSubscriptionList() {
        guard persistsChanges else { return }
        defaults.set(try? JSONEncoder().encode(subscriptions), forKey: "subscriptions")
    }
    /// Shows every enabled subscription that has a copy, merged in list order.
    private func rebuildSubscription(resetting: Bool = true) {
        if resetting { searchModel.reset(); recommendationModel.reset() }
        let enabled = subscriptions.filter(\.enabled).compactMap { documents[$0.address] }
        subscription = Subscription.merge(enabled)
        refreshOtherProfileExtras()
        if let subscription {
            // Older downloads only had the last episode in Continue Watching. Keep that position before the
            // viewer moves on to another episode and the show-level entry is replaced.
            for item in DownloadLibrary.shared.items where item.status == .completed && item.watchProgress?[profile.id] == nil {
                if let progress = cachedProgress(item) {
                    DownloadLibrary.shared.recordPlayback(id: item.id, profile: profile.id, position: progress.position,
                                                          duration: progress.duration, now: progress.updatedAt)
                }
            }
            hiddenSources.restoreBuiltIns(subscription.sites, origin: subscription.origin)
            hiddenSources.restoreAutoHidden(subscription.sites, origin: subscription.origin, health: .shared)
        }
    }
    func searchVideos(_ title: String) {
        guard let config = subscription else { return }
        let keyword = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        let old = defaults.data(forKey: "videoSearchHistory").flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        defaults.set(try? JSONEncoder().encode(Array(([keyword] + old.filter { $0 != keyword }).prefix(20))), forKey: "videoSearchHistory")
        searchModel.search(keyword, config: config) { [hiddenSources] site in
            hiddenSources.contains(site, origin: config.origin)
        }
        section = .search
    }
    func toggleFavorite(_ channel: Channel) { favorites.toggle(.live(channel)) }
    func isFavorite(_ channel: Channel) -> Bool { favorites.contains(.live(channel)) }

    func catalogClient(for video: FavoriteVideo) -> CatalogClient? {
        guard let config = subscription,
              let site = config.sites.first(where: { $0.origin(or: config.origin) == video.origin && $0.sourceKey == video.sourceKey }) else { return nil }
        return CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL)
    }
    func reportMissingFavoriteSource() {
        error = L10n.text("This favorite's source is no longer in the current subscription. Restore that subscription to open it.")
    }

    func play(_ episode: FavoriteEpisode) {
        guard catalogClient(for: episode.video) != nil else { reportMissingFavoriteSource(); return }
        let position = episode.resumePosition(in: playbackHistory.entries)
        resume(PlaybackHistoryEntry(context: episode.historyContext(), position: position, duration: 0, updatedAt: Date()))
    }

    /// The Watch Now source row: pinned, then built-in, then the sources page's subscription order.
    func recommendationSites(_ config: Subscription) -> [Site] {
        let stamp = currentSiteListStamp()
        if stamp == siteListStamp, let cached = recommendationCache { return cached }
        let leading = automaticSites(config)
        let pinned = leading.filter { pinnedSources.contains($0, origin: config.origin) }
        let builtIn = leading.filter { $0.isBuiltIn && !pinnedSources.contains($0, origin: config.origin) }
        let groups = sourceGroups(includeHidden: false)
        let result = SourceGroups.homeRow(pinned: pinned, builtIn: builtIn, groups: groups)
        rememberSiteLists(stamp)
        recommendationCache = result
        return result
    }

    /// The sources to show, in the viewer's own order while it is on.
    func orderedSites(_ config: Subscription) -> [Site] {
        let stamp = currentSiteListStamp()
        if stamp == siteListStamp, let cached = orderedCache { return cached }
        let sites = automaticSites(config)
        let arranged = sourceOrder.enabled ? sourceOrder.arrange(sites, origin: config.origin) : sites
        rememberSiteLists(stamp)
        orderedCache = arranged
        return arranged
    }

    /// The order the app picks: built-in sources, then `SourceStrategy`'s, with pinned sources first. Hidden sources stay out.
    func automaticSites(_ config: Subscription) -> [Site] {
        let stamp = currentSiteListStamp()
        if stamp == siteListStamp, let cached = automaticCache { return cached }
        let sites = SourceLists.browsable(config.sites, jarURL: config.spiderURL) { hiddenSources.contains($0, origin: config.origin) }
        let arranged = pinnedSources.arrange(sites.filter(\.isBuiltIn) + sites.filter { !$0.isBuiltIn }, origin: config.origin)
        rememberSiteLists(stamp)
        automaticCache = arranged
        return arranged
    }

    /// Drops cached rows when their inputs changed. Each list fills itself, so a caller that only needs one does not build the others.
    private func rememberSiteLists(_ stamp: String) {
        guard stamp != siteListStamp else { return }
        siteListStamp = stamp
        automaticCache = nil
        orderedCache = nil
        recommendationCache = nil
        groupsCache = [:]
    }

    /// Turns the viewer's own source order on or off. The first time, it starts from the order on
    /// screen, so nothing jumps.
    func setCustomSourceOrder(_ enabled: Bool) {
        if enabled, sourceOrder.isEmpty, let config = subscription { sourceOrder.save(automaticSites(config), origin: config.origin) }
        sourceOrder.enabled = enabled
    }

    /// Moves a source within the viewer's order; `offset` is a position in `orderedSites`, as `move(fromOffsets:toOffset:)` takes it.
    func moveSource(_ site: Site, to offset: Int) {
        guard let config = subscription else { return }
        var sites = orderedSites(config)
        guard let index = sites.firstIndex(where: { $0.id == site.id }) else { return }
        sites.move(fromOffsets: [index], toOffset: max(0, min(offset, sites.count)))
        sourceOrder.save(sites, origin: config.origin)
    }

    /// The sources page's sections: pinned, built-in, then one per subscription.
    func sourceGroups(includeHidden: Bool) -> [SourceGroup] {
        let stamp = currentSiteListStamp()
        if stamp == siteListStamp, let cached = groupsCache[includeHidden] { return cached }
        guard let config = subscription else { return [] }
        let pins = pinnedSources.arrange(config.sites, origin: config.origin).filter { pinnedSources.contains($0, origin: config.origin) }
        var groups = SourceGroups.make(entries: subscriptions, documents: documents, builtIns: config.sites.filter(\.isBuiltIn), builtInOrigin: config.origin, mergedSites: config.sites, pinOrder: pins, userHidden: { hiddenSources.contains($0, origin: config.origin) }, includeHidden: includeHidden, jarURL: config.spiderURL)
        // The viewer's own order, while it is on, orders the sources inside each group too.
        if sourceOrder.enabled { groups = sourceOrder.arrange(groups, origin: config.origin) }
        rememberSiteLists(stamp)
        groupsCache[includeHidden] = groups
        return groups
    }

    func catalogChannel(_ resolved: Channel, video: Video, episode: Episode, client: CatalogClient,
                        resumePosition: Double? = nil) -> Channel {
        let saved = DownloadLibrary.shared.item(for: DownloadSource(site: client.site, videoID: video.id, episode: episode))
        let position = resumePosition ?? saved.flatMap { cachedProgress($0)?.resumePosition }
        let channel = episodeChannel(resolved, video: video, episode: episode, client: client, resumePosition: position)
        remember(video, client: client, for: channel)
        return channel
    }

    /// The channel that plays `episode`, without making its video the one playing.
    private func episodeChannel(_ resolved: Channel, video: Video, episode: Episode, client: CatalogClient,
                                resumePosition: Double? = nil) -> Channel {
        let context = PlaybackHistoryContext(origin: client.origin, site: client.site, video: video, episode: episode)
        return Channel(name: context.displayName, group: resolved.group, url: resolved.url,
                       logo: resolved.logo, headers: resolved.headers, skipScope: context.id,
                       historyContext: context, resumePosition: resumePosition, subtitles: resolved.subtitles, skips: resolved.skips)
    }

    /// The video and its episode list, for the player's episode buttons and the next episode.
    private func remember(_ video: Video, client: CatalogClient, for channel: Channel) {
        guard let context = channel.historyContext else { return }
        if let data = try? JSONEncoder().encode(video) {
            MediaCache.shared.store(data, for: "detail", kind: .catalog, scope: context.id, ttl: 6 * 3600, ticket: MediaCache.shared.ticket())
        }
        // The Episodes menu's short labels (#318): kept from the episode before on the same video, else worked out off the
        // main thread.
        let kept = playbackCatalog.flatMap { $0.video == video ? $0 : nil }
        playbackCatalog = PlaybackCatalog(video: video, client: client, scope: context.id, labels: kept?.labels ?? [:], details: kept?.details ?? [:])
        guard kept == nil else { return }
        let episodes = video.episodes
        Task { [weak self] in
            let (labels, details) = await Task.detached(priority: .utility) {
                let labels = EpisodeLabels.labels(episodes)
                return (labels, EpisodeFileInfo.details(episodes, labels: labels))
            }.value
            // Still this video, though maybe the next episode by now.
            guard let self, !labels.isEmpty || !details.isEmpty, self.playbackCatalog?.video == video else { return }
            self.playbackCatalog?.labels = labels
            self.playbackCatalog?.details = details
        }
    }

    /// The next episode's stream, resolved ahead so the player can queue it behind this one; nil when
    /// auto-play is off, there is no next episode, or the source can't resolve it now.
    func upcomingEpisode(after channel: Channel) async -> Channel? {
        await upcomingEpisode(after: channel) { [weak self] in self?.playing == $0 }
    }

    /// `isCurrent` says whether `channel` still plays: a video floating in Picture in Picture plays with no `playing`.
    func upcomingEpisode(after channel: Channel, isCurrent: (Channel) -> Bool) async -> Channel? {
        // Only while `channel` still plays: once the queue moves on, this was asked about the one before.
        if CloudFiles.isFile(channel.url) || channel.url.scheme == DownloadLibrary.scheme {
            return autoPlayNext && isCurrent(channel) ? nextFile(after: channel) : nil
        }
        guard autoPlayNext, let catalog = catalog(for: channel), let next = nextEpisode(after: channel) else { return nil }
        do {
            let resolved: Channel
            if let ahead = await nextAhead(for: next) { resolved = ahead } else { resolved = try await catalog.client.playback(next) }
            guard !Task.isCancelled, isCurrent(channel) else { return nil }
            return episodeChannel(resolved, video: catalog.video, episode: next, client: catalog.client)
        } catch {
            if !(error is CancellationError) { Diagnostics.shared.failure("catalog", "upcoming episode \(catalog.client.reportContext) flag=\(next.flag)", error) }
            return nil
        }
    }

    /// The episode `channel` plays, resolved again by its source: a fresh link for one that expired while it played
    /// (`LinkRenewal`). Nil for anything but a catalog episode, or when the source answers nothing.
    func renewedChannel(for channel: Channel) async -> Channel? {
        guard let context = channel.historyContext, let catalog = catalog(for: channel),
              let episode = catalog.video.episodes.first(where: { $0.id == context.episodeID && $0.flag == context.episodeFlag })
                ?? catalog.video.episodes.first(where: { $0.id == context.episodeID }) else { return nil }
        do { return try await catalog.client.playback(episode) }
        catch {
            if !(error is CancellationError) { Diagnostics.shared.failure("catalog", "renew episode \(catalog.client.reportContext) flag=\(episode.flag)", error) }
            return nil
        }
    }

    /// Resolves the episode after `channel` while it plays, when it lasts `nextAheadLength` or less, once per episode.
    func resolveNextAhead(after channel: Channel, duration: Double) {
        guard duration > 0, duration <= Self.nextAheadLength, playing == channel,
              let catalog = catalog(for: channel), let next = nextEpisode(after: channel) else { return }
        if nextAheadTask?.episode == next { return }
        if let ahead = nextAhead, ahead.episode == next, Date().timeIntervalSince(ahead.at) < Self.nextAheadLifetime { return }
        nextAheadTask?.task.cancel()
        let task = Task { [weak self] in
            do {
                let resolved = try await catalog.client.playback(next)
                guard !Task.isCancelled, let self else { return }
                self.nextAhead = (next, resolved, Date())
                Diagnostics.shared.record(.info, "catalog", "next episode resolved ahead flag=\(next.flag)")
            } catch {
                if !(error is CancellationError) {
                    Diagnostics.shared.record(.warning, "catalog", "next episode not resolved ahead \(Diagnostics.describe(error))")
                }
            }
            if self?.nextAheadTask?.episode == next { self?.nextAheadTask = nil }
        }
        nextAheadTask = (next, task)
    }

    /// The stream resolved ahead for `episode`, waiting for one still on its way; nil when there is none, or it is too
    /// old to trust. It is handed out once: when its address then fails (a video server refusing it with HTTP 403),
    /// the end of the episode, Next or the episode list asks the source again instead of getting the same address (#1413).
    private func nextAhead(for episode: Episode) async -> Channel? {
        if let pending = nextAheadTask, pending.episode == episode { await pending.task.value }
        guard let ahead = nextAhead, ahead.episode == episode, Date().timeIntervalSince(ahead.at) < Self.nextAheadLifetime else { return nil }
        nextAhead = nil
        return ahead.resolved
    }

    /// The queued episode started playing by itself: it becomes the one playing, as if it had been chosen.
    func advance(to next: Channel, from channel: Channel) {
        if CloudFiles.isFile(next.url) || next.url.scheme == DownloadLibrary.scheme, playing == channel { playing = next; return }
        guard playing == channel, let catalog = catalog(for: channel) else { return }
        cancelEpisodeSelection()
        remember(catalog.video, client: catalog.client, for: next)
        playing = next
    }

    /// The queue moved a video floating in Picture in Picture on to its next episode: the episode list follows, so the
    /// one after can be queued too, and nothing opens over the app (#1719).
    func followFloating(to next: Channel, from channel: Channel) {
        guard let catalog = catalog(for: channel) else { return }
        remember(catalog.video, client: catalog.client, for: next)
    }

    func catalog(for channel: Channel) -> PlaybackCatalog? {
        guard let catalog = playbackCatalog, catalog.scope == channel.historyContext?.id else { return nil }
        return catalog
    }

    func nextEpisode(after channel: Channel) -> Episode? {
        guard let context = channel.historyContext else { return nil }
        return catalog(for: channel)?.playlist.next(after: context)
    }

    func previousEpisode(before channel: Channel) -> Episode? {
        guard let context = channel.historyContext else { return nil }
        return catalog(for: channel)?.playlist.previous(before: context)
    }

    /// The same episode on a transcoded line (FTY's 智 lines are the drive's own HLS) when the
    /// playing original can't play here. The same drive's line comes first: 夸父原1 → 夸父智1.
    func transcodedLine(for channel: Channel) -> Episode? {
        guard let context = channel.historyContext, let catalog = catalog(for: channel) else { return nil }
        let current = context.episodeFlag
        let candidates = catalog.video.episodes.filter {
            $0.name == context.episodeName && $0.flag != current && $0.flag.contains("智")
        }
        let sameDrive = current.replacingOccurrences(of: "原", with: "智").replacingOccurrences(of: "无限", with: "智")
        return candidates.first { $0.flag == sameDrive } ?? candidates.first
    }

    func selectEpisode(_ episode: Episode, from channel: Channel, failed: ((String) -> Void)? = nil) {
        guard playing == channel, let catalog = catalog(for: channel),
              catalog.video.episodes.contains(episode) else { return }
        cancelEpisodeSelection()
        let request = episodeRequest
        resolvingEpisode = episode; episodeError = nil
        // The episode playing, on another line (one too slow to watch, say): it goes on from here, not from the start (#1300).
        PlaybackSession.current?.saveHistory()
        let resume = channel.historyContext.flatMap { context in playbackHistory.entries.first { $0.id == context.id } }
            .flatMap { $0.context.episodeID == channel.historyContext?.episodeID ? $0.resumePosition(for: episode, among: catalog.video.episodes) : nil }
        episodeTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.episodeRequest == request { self.resolvingEpisode = nil; self.episodeTask = nil } }
            do {
                // Resolved ahead while a short episode played, Next starts it at once.
                let resolved: Channel
                if let ahead = await self.nextAhead(for: episode) { resolved = ahead } else { resolved = try await catalog.client.playback(episode) }
                guard !Task.isCancelled, self.episodeRequest == request, self.playing == channel else { return }
                self.playing = self.catalogChannel(resolved, video: catalog.video, episode: episode, client: catalog.client, resumePosition: resume)
            } catch {
                guard !Task.isCancelled, self.episodeRequest == request, self.playing == channel else { return }
                Diagnostics.shared.failure("catalog", "episode \(catalog.client.reportContext) flag=\(episode.flag)", error)
                self.episodeError = error.localizedDescription
                failed?(error.localizedDescription)
            }
        }
    }

    func cancelEpisodeSelection() {
        episodeRequest = UUID()
        episodeTask?.cancel(); episodeTask = nil; resolvingEpisode = nil
    }

    /// Resumes a watched title. Choosing another title while one is still being prepared switches
    /// to it: the earlier request is cancelled, which also stops its plugin call.
    func resume(_ entry: PlaybackHistoryEntry) {
        guard resumingHistoryID != entry.id else { return }
        resumeTask?.cancel()
        resumingHistoryID = entry.id
        resumeTask = Task { await resumeHistory(entry) }
    }

    func cancelResume() {
        resumeTask?.cancel(); resumeTask = nil
        resumingHistoryID = nil
    }

    /// The source a watched title came from. Any enabled subscription can hold it: it is found by its own origin
    /// and original key. Nil for Cloud Files, and once the source is gone.
    func historyClient(_ entry: PlaybackHistoryEntry) -> CatalogClient? {
        guard let config = subscription,
              let site = config.sites.first(where: { $0.origin(or: config.origin) == entry.context.origin && $0.sourceKey == entry.context.sourceKey }) else { return nil }
        return CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL).applying(config)
    }

    func resumeHistory(_ entry: PlaybackHistoryEntry) async {
        resumingHistoryID = entry.id
        defer { if resumingHistoryID == entry.id, !Task.isCancelled { resumingHistoryID = nil } }
        if entry.context.sourceKey == CloudFiles.sourceKey { return resumeFile(entry) }
        guard let config = subscription, let client = historyClient(entry) else {
            error = L10n.text("This history source is no longer in the current subscription. Restore that subscription to continue.")
            return
        }
        let site = client.site
        // An episode saved on this device plays from it, where it stopped, with no request to the source (#960).
        let savedEpisode = Episode(id: entry.context.episodeID, name: entry.context.episodeName, address: "", flag: entry.context.episodeFlag)
        if !entry.completed, let saved = DownloadLibrary.shared.item(for: DownloadSource(site: site, videoID: entry.context.videoID, episode: savedEpisode)),
           saved.status == .completed {
            playing = savedChannel(saved)
            return
        }
        let previousPlayback = playing
        do {
            // Plugin/API sources resolve an episode again. Direct-file APIs must refresh
            // their detail first so an expiring media address never becomes a resume shortcut.
            let useCache = site.type == 3 || site.type == 4
            var video = try await client.detail(entry.context.videoID, cached: useCache)
            var matched = entry.context.episode(in: video.episodes)
            if matched == nil, useCache {
                // A six-hour detail snapshot can hold an episode list the source has since changed.
                // A fresh search finds it, so ask the source again before giving up.
                try Task.checkCancellation()
                video = try await client.detail(entry.context.videoID)
                matched = entry.context.episode(in: video.episodes)
            }
            guard var episode = matched else {
                throw TVError.unsupported(L10n.text("The saved episode is no longer available from this source. Choose an episode again."))
            }
            let channel: Channel
            do { channel = try await client.playback(episode) }
            catch {
                try Task.checkCancellation()
                video = try await client.detail(entry.context.videoID)
                guard let refreshed = entry.context.episode(in: video.episodes) else { throw error }
                episode = refreshed
                channel = try await client.playback(refreshed)
            }
            guard !Task.isCancelled, playing == previousPlayback, subscription?.origin == config.origin else { return }
            // A source whose details carry no poster keeps the one saved with the entry.
            playing = catalogChannel(channel, video: video.keepingPoster(entry.context.poster, headers: entry.context.posterHeaders),
                                     episode: episode, client: client, resumePosition: entry.resumePosition)
        } catch {
            guard !(error is CancellationError), !Task.isCancelled else { return }
            Diagnostics.shared.failure("catalog", "resume source=\(entry.context.sourceKey)", error)
            self.error = L10n.text("Unable to resume playback: %@", error.localizedDescription)
        }
    }
}

#if os(macOS)
extension Store {
    /// The Developer ID app uses `com.jo32.yingxia.macos`. Adopt settings from the previous Mac
    /// domains once, newest first, keeping any values already set in this domain. The app isn't
    /// sandboxed, so it can read the old domains. Application Support and Caches keep their
    /// `com.tvbox.yingxia` folder and need nothing.
    static func adoptPreviousBundleDefaults(_ defaults: UserDefaults) {
        for previous in ["com.jo32.yingxia.mac", "com.tvbox.yingxia.mac"] {
            let done = "adoptedDefaults." + previous
            guard Bundle.main.bundleIdentifier != previous, !defaults.bool(forKey: done) else { continue }
            for (key, value) in defaults.persistentDomain(forName: previous) ?? [:] where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
            defaults.set(true, forKey: done)
        }
    }
}
#endif

/// How this build reaches people. App Store and TestFlight builds are archived with
/// `SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) APPSTORE'`; direct downloads and sideloaded
/// builds leave it out. `-qaAppStore 1` makes a debug build act as one.
enum Distribution {
    static var isAppStore: Bool {
        #if APPSTORE
        return true
        #elseif DEBUG
        return UserDefaults.standard.bool(forKey: "qaAppStore")
        #else
        return false
        #endif
    }

    /// An App Store build installed from TestFlight, which leaves a sandbox receipt. A build promoted to the
    /// App Store gets a production receipt, so it stops sending people to TestFlight. `-qaTestFlight 1` in debug builds.
    static let isTestFlight: Bool = {
        #if APPSTORE
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #elseif DEBUG
        return UserDefaults.standard.bool(forKey: "qaTestFlight")
        #else
        return false
        #endif
    }()
}

// MARK: Downloads

extension Store {

    /// Use an exact episode match, including its source and line. Another episode's newer history belongs to that episode.
    func cachedProgress(_ item: DownloadItem) -> DownloadWatchProgress? {
        let local = item.watchProgress?[profile.id]
        guard let context = item.historyContext(in: subscription),
              let entry = playbackHistory.entries.first(where: { $0.id == context.id }),
              entry.context.episodeID == item.source.episodeID, entry.context.episodeFlag == item.source.flag,
              local.map({ $0.updatedAt < entry.updatedAt }) ?? true else { return local }
        return DownloadWatchProgress(position: entry.position, duration: entry.duration, updatedAt: entry.updatedAt)
    }

    func recordCachedPlayback(_ channel: Channel, position: Double, duration: Double) {
        let library = DownloadLibrary.shared
        guard !library.items.isEmpty else { return }
        let id: String?
        if channel.url.scheme == DownloadLibrary.scheme {
            id = channel.url.host()
        } else if let context = channel.historyContext, let config = subscription,
                  let site = config.sites.first(where: { $0.sourceKey == context.sourceKey && $0.origin(or: config.origin) == context.origin }) {
            let episode = Episode(id: context.episodeID, name: context.episodeName, address: "", flag: context.episodeFlag)
            id = library.item(for: DownloadSource(site: site, videoID: context.videoID, episode: episode))?.id
        } else { return }
        if let id { library.recordPlayback(id: id, profile: profile.id, position: position, duration: duration) }
    }

    func savedChannel(_ item: DownloadItem) -> Channel {
        let resume = cachedProgress(item)?.resumePosition
        guard var context = item.historyContext(in: subscription) else { return DownloadLibrary.shared.channel(for: item, resumePosition: resume) }
        let entry = playbackHistory.entries.first { $0.id == context.id }
        if context.year == nil { context.year = entry?.context.year }
        return DownloadLibrary.shared.channel(for: item, context: context, resumePosition: resume)
    }

    func nextFile(after channel: Channel) -> Channel? { file(1, from: channel) }
    func previousFile(before channel: Channel) -> Channel? { file(-1, from: channel) }

    /// The file `offset` places from the playing one in its folder, for the player's Previous and Next. A saved
    /// episode steps through the others saved from its show (#835, #820).
    private func file(_ offset: Int, from channel: Channel) -> Channel? {
        if channel.url.scheme == DownloadLibrary.scheme {
            return DownloadLibrary.shared.neighbor(of: channel.url, offset: offset).map(savedChannel)
        }
        guard let context = channel.historyContext, context.sourceKey == CloudFiles.sourceKey, let folder = filesFolder,
              folder.drive.key == context.episodeFlag, folder.id == context.videoID,
              let index = folder.files.firstIndex(where: { $0.id == context.episodeID }),
              folder.files.indices.contains(index + offset) else { return nil }
        return CloudFiles.channel(folder.files[index + offset], in: folder.drive, folder: folder.id, folderName: folder.name, subtitles: folder.subtitles)
    }

}

// MARK: Cloud Files

/// A Cloud Files folder being played through: its files of the kind chosen, in order.
struct CloudFilesFolder {
    let drive: CloudFilesDrive
    let id: String
    let name: String
    let files: [CloudFile]
    /// The folder's subtitle files and archives, offered beside each of its videos.
    var subtitles: [ExternalSubtitle] = []
}

extension Store {
    /// Plays a file from Cloud Files, where it was left if it was being watched; the folder's other
    /// files follow it.
    func playFile(_ file: CloudFile, in folder: CloudFilesFolder) {
        let channel = CloudFiles.channel(file, in: folder.drive, folder: folder.id, folderName: folder.name, subtitles: folder.subtitles)
        let saved = playbackHistory.entries.first { $0.id == channel.historyContext?.id && $0.context.episodeID == file.id && !$0.completed }
        filesFolder = folder
        playing = saved.map { CloudFiles.channel(file, in: folder.drive, folder: folder.id, folderName: folder.name, resumePosition: $0.resumePosition,
                                                 subtitles: folder.subtitles) } ?? channel
    }

    /// Plays a saved cloud file: its folder is just that file, so nothing follows it.
    func play(_ file: FavoriteCloudFile) {
        guard let drive = CloudFiles.drive(key: file.driveKey) else {
            error = L10n.text("This file's drive is no longer in Cloud Files.")
            return
        }
        let cloud = CloudFile(id: file.fileID, name: file.fileName, isFolder: false, size: file.size)
        playFile(cloud, in: CloudFilesFolder(drive: drive, id: file.folderID, name: file.folderName, files: [cloud]))
    }

    /// Continue Watching on a Cloud Files folder: the file plays at once, and the folder is listed
    /// again meanwhile so the files after it still follow.
    fileprivate func resumeFile(_ entry: PlaybackHistoryEntry) {
        let context = entry.context
        guard let drive = CloudFiles.drive(key: context.episodeFlag) else {
            error = L10n.text("This file's drive is no longer in Cloud Files.")
            return
        }
        filesFolder = nil
        let channel = CloudFiles.channel(context, resumePosition: entry.resumePosition)
        playing = channel
        Task { [weak self] in
            guard let files = try? await CloudFiles.list(drive, folder: context.videoID), let self, self.playing == channel else { return }
            let kind = CloudFile.kind(of: context.episodeName)
            self.filesFolder = CloudFilesFolder(drive: drive, id: context.videoID, name: context.videoName,
                                                files: files.filter { $0.kind == kind && drive.plays($0) },
                                                subtitles: CloudFiles.subtitles(files, in: drive))
        }
    }
}

struct PlaybackCatalog {
    let video: Video
    let client: CatalogClient
    let scope: String
    /// Short labels (第1集) for lines whose episode names are file names, by episode id.
    var labels: [Episode.ID: String] = [:]
    /// Resolution and size read from file names (4K · 5.2G, #620), shown under the episodes, by episode id.
    var details: [Episode.ID: String] = [:]
    var playlist: EpisodePlaylist { EpisodePlaylist(video.episodes) }
}

