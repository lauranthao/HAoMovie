import SwiftUI
import AVKit

#if os(macOS)
import IOKit.pwr_mgt
#endif

@MainActor @Observable final class PlaybackSession: SkipTimesEditing {
    /// A queue, so the next episode can wait behind this one and play straight on.
    let player: AVQueuePlayer
    /// The video player's volume, remembered across launches. Every change goes through the KVO observer below:
    /// AVKit's own slider, the Mac wheel and arrow keys, and the Sleep Timer's fade (which restores its starting level).
    private static func storedVolume() -> Float {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "playerVolume") != nil else { return 1 }
        return Float(min(1, max(0, defaults.double(forKey: "playerVolume"))))
    }

    /// Upscaling and 60 fps smoothing, drawn over AVKit's picture when switched on in Settings.
    let enhancer: VideoEnhancer
    #if os(macOS)
    /// Keeps the Mac from dimming, starting the screen saver and locking while a video plays (#565).
    private let displayAwake = DisplayAwake()
    #endif
    private let sleepFade = PlaybackSleepFade()
    private var sleepFadeRevision: UUID?
    var history = PlaybackHistory.shared
    var skipDefaults = UserDefaults.standard
    @ObservationIgnored var recordCachedPlayback: ((Channel, Double, Double) -> Void)?
    private var historyContext: PlaybackHistoryContext?
    /// This player's last saved position, independent of history imported from another device. A paused player
    /// must not write its old episode back just because iCloud replaced the shared history entry meanwhile.
    @ObservationIgnored private var lastHistoryPosition: Double?
    private var pendingResume: Double?
    /// Where the item was asked to open (`seekAhead`), until it is ready.
    @ObservationIgnored private var soughtAhead: Double?
    private var restoringPosition = false
    private(set) var restoredPosition: Double?
    private(set) var requestedResumePosition: Double?
    private(set) var skipSettings = EpisodeSkipSettings()
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private var skipScope: String?
    /// The title whose speed the player keeps: another title starts at the speed set in Settings › Playback.
    @ObservationIgnored private var speedScope: String?
    private var skipPass = EpisodeSkipPass()
    private var editingSkip = false
    private var resumeAfterEditing = false
    private var seekingSegment = false
    /// The source's opening and ending credits for this episode (the play result's `skips`), and the one playing now,
    /// which the player offers to skip.
    private(set) var sourceSkips: [PlaybackSkip] = []
    private(set) var skipOffer: PlaybackSkip?
    private var skippedSource = Set<PlaybackSkip>()
    /// What the player says about the viewer's intro and outro times (#1003): the intro it just skipped, which Undo
    /// plays after all, or the seconds left before it skips the outro, which Cancel keeps.
    enum SkipNotice: Equatable {
        case introSkipped(from: Double)
        case outroIn(seconds: Int)
    }
    private(set) var skipNotice: SkipNotice?
    private var introNoticeUntil: Date?
    /// How long the intro's notice stays.
    private static let introNoticeLength: TimeInterval = 6
    /// The episode's chapters (Bilibili's 分段章节), for the player's Chapters menu and Apple TV's chapter markers.
    private(set) var chapters: [PlaybackChapter] = []

    /// Skips the source's credits playing now: to their end, or for ending credits that run out the video, to the end.
    func skipSourceSegment() {
        guard let skip = skipOffer, let item, item.status == .readyToPlay else { return }
        skippedSource.insert(skip)
        skipOffer = nil
        let length = item.duration.seconds
        let target = length.isFinite && skip.end >= length - 1 ? max(0, length - 0.05) : skip.end
        Diagnostics.shared.record(.info, "player", "skip source \(skip.kind.rawValue) to=\(Int(target))")
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Plays the intro after all, from where it was skipped.
    func undoIntroSkip() {
        guard case .introSkipped(let from) = skipNotice else { return }
        skipNotice = nil; introNoticeUntil = nil
        Diagnostics.shared.record(.info, "player", "skip intro undone")
        jump(to: from)
    }

    /// Plays this episode's outro rather than skipping it.
    func keepOutro() {
        skipPass.keepOutro()
        skipNotice = nil
        Diagnostics.shared.record(.info, "player", "skip outro kept")
    }

    private func showIntroSkipped(from time: Double) {
        skipNotice = .introSkipped(from: time)
        introNoticeUntil = Date().addingTimeInterval(Self.introNoticeLength)
    }

    /// The intro's notice until it times out, else the outro's countdown; assigned only when it changes.
    private func updateSkipNotice(time: Double, duration: Double) {
        var notice = skipNotice
        if case .introSkipped = notice, (introNoticeUntil ?? .distantPast) <= Date() { notice = nil; introNoticeUntil = nil }
        if case .introSkipped = notice {} else {
            notice = skipPass.outroCountdown(time: time, duration: duration, settings: skipSettings)
                .map { .outroIn(seconds: max(1, Int($0.rounded(.up)))) }
        }
        if notice != skipNotice { skipNotice = notice }
    }

    /// Plays from `seconds`, as a chapter in the Chapters menu does.
    func jump(to seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// The source's credits: skipped by themselves when the viewer has intros and outros skipped and set no times of
    /// their own for this video; otherwise offered while they play.
    private func updateSourceSkip(time: Double) {
        let current = PlaybackSkip.current(sourceSkips, at: time).flatMap { skippedSource.contains($0) ? nil : $0 }
        if current != skipOffer { skipOffer = current }
        guard current != nil, player.rate > 0, skipSettings.enabled, skipSettings.introEnd == 0, skipSettings.outroLength == 0 else { return }
        skipSourceSegment()
    }

    func beginEditingSkip() {
        cancelSleepFade()
        editingSkip = true
        resumeAfterEditing = player.rate > 0
        player.pause()
    }

    func endEditingSkip() {
        editingSkip = false
        if resumeAfterEditing { player.play() }
        resumeAfterEditing = false
    }

    func applySkipSettings(_ settings: EpisodeSkipSettings) {
        guard let skipScope else { return }
        settings.save(scope: skipScope, defaults: skipDefaults)
        skipSettings = settings
        skipPass = EpisodeSkipPass()
    }

    /// Whether this video keeps skip times: one from a source, not a live channel or a lone address.
    var canSkip: Bool { skipScope != nil }
    var skipPosition: Double { position }
    var skipDuration: Double { duration }

    /// The intro ends, or the outro starts, where the picture is now (#808): Apple TV has no keyboard for a time.
    /// A place the rules refuse (an intro past five minutes, say) changes nothing.
    func markSkip(intro: Bool) {
        guard let item = player.currentItem,
              let settings = skipSettings.marking(intro: intro, at: player.currentTime().seconds, duration: item.duration.seconds) else { return }
        applySkipSettings(settings)
    }

    private func updateSkipping(_ item: AVPlayerItem) {
        let time = player.currentTime().seconds
        position = time.isFinite ? max(0, time) : 0
        let length = item.duration.seconds
        duration = length.isFinite ? max(0, length) : 0
        guard skipScope != nil, !editingSkip, !seekingSegment, pendingResume == nil, !restoringPosition,
              item.status == .readyToPlay else { return }
        updateSourceSkip(time: time)
        updateSkipNotice(time: time, duration: length)
        var pass = skipPass
        guard let target = pass.target(time: time, duration: length, playing: player.rate > 0, settings: skipSettings) else {
            skipPass = pass
            return
        }
        guard item.seekableTimeRanges.contains(where: { CMTimeRangeContainsTime($0.timeRangeValue, time: CMTime(seconds: target, preferredTimescale: 600)) }) else { return }
        skipPass = pass
        // The intro skipped says so, with Undo, rather than jump without a word; the outro had its countdown.
        if time < skipSettings.introEnd, target == skipSettings.introEnd { showIntroSkipped(from: time) } else { skipNotice = nil }
        seekingSegment = true
        let activeGeneration = generation
        Diagnostics.shared.record(.info, "player", "skip segment from=\(Int(time)) to=\(Int(target))")
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == activeGeneration else { return }
                self.seekingSegment = false
            }
        }
    }

    var error: String? { didSet { if error != nil { countPlay(.failed) } } }
    /// This play on its way to the first frame, counted for the play success rate (`PlayAttempt`).
    private var attempt: PlayAttempt?
    /// A retry rung is trying to save this play (a short constant such as "line"): if the picture then starts, the
    /// play counts as recovered by it.
    func retrying(via rung: String) { attempt?.retrying(rung) }
    private func countPlay(_ outcome: PlayAttempt.Outcome) {
        attempt?.resolve(outcome, playing: (player.currentItem?.asset as? AVURLAsset)?.url)
    }
    var loading = true
    var looping = false { didSet { if looping { discardUpcoming() } } }
    var buffering = false
    /// Whether the picture has started moving: the waiting screen stays until then, so no black frame shows between.
    private(set) var showsPicture = false
    /// When this episode (or line) began to open: the waiting screen counts from here until the first frame.
    private(set) var openedAt = Date()
    /// The SF Symbol that names the latest failure for the error screen.
    private(set) var errorSymbol = "play.slash.fill"
    /// Bullet comments for the media, when its source has them.
    private var sourceDanmaku: [Danmaku] = []
    var danmaku: [Danmaku] { sourceDanmaku }
    var danmakuOpacity: Double { 1 }
    var danmakuRevision: String { "" }
    var onPlaybackEnded: (() -> Void)?
    /// Plays another line of the same episode when this file can't play here (an MKV original);
    /// returns that line's name, or nil when there is none.
    var onUnplayableFile: (() -> String?)?
    /// The episode after this one, resolved for the queue; nil when there is none.
    var upcomingEpisode: (@MainActor () async -> Channel?)?
    /// Whether playback runs on into the next episode (auto-play can be switched off meanwhile).
    var playsOn: @MainActor () -> Bool = { false }
    /// The queued episode started playing by itself: it is now the episode on screen.
    var onAdvance: (@MainActor (Channel) -> Void)?
    /// The next episode, prepared near the end of this one and queued behind it, so playback runs
    /// straight on instead of stopping to load it.
    private struct Upcoming {
        let channel: Channel
        let item: AVPlayerItem
        let prepared: Prepared
    }
    private var upcoming: Upcoming?
    private var upcomingTask: Task<Void, Never>?
    private var upcomingObservation: NSKeyValueObservation?
    /// Whether this episode has already tried to queue the next one (once each, even when that failed).
    private var upcomingAttempted = false
    /// The queued episode was moved past its intro before it played: it says so once it does.
    private var upcomingSkippedIntro = false
    /// The queue moves past this episode because the next one was asked for, not because it ended.
    private var skipsToUpcoming = false
    /// The episode the queue moved on to, which `start` then finds already playing.
    private var advanced: Channel?
    /// The item of the episode on screen; during a move the queue's current item is already the next one.
    private var item: AVPlayerItem?
    private var queueObservation: NSKeyValueObservation?
    /// How long before an episode's end (or its skipped outro) the next one starts loading.
    static let upcomingLead: Double = 30
    /// Why the player is switching lines, shown while the other line loads.
    private var switchNotice: String?
    /// Qualities the stream can switch between (Bilibili), and the one chosen; nil is automatic.
    private(set) var qualities: [StreamQuality] = []
    /// A live channel's lines (#679), the one playing, and those tried since the channel or the line was chosen. Empty
    /// for a channel of one address.
    private(set) var lines: [Channel] = []
    private(set) var line = 0
    private var triedLines: Set<Int> = []
    /// When the line playing became ready. One that isn't ready after `lineWait` gives way to the next, as one that
    /// fails does: a dead IPTV address can keep AVPlayer waiting a minute before it says so.
    private var lineReadyAt: ContinuousClock.Instant?
    private var lineWatch: Task<Void, Never>?
    static let lineWait: Duration = .seconds(15)
    /// The item has subtitle tracks of its own (shown in AVKit's Subtitles menu, not with the subtitle files).
    var hasOwnSubtitles: Bool { mediaTracks.legible?.options.isEmpty == false }
    /// A live stream: played at the live edge, without scrubbing.
    private(set) var isLive = false
    /// The item is ready and has a finite duration, so there is a timeline to scrub. A live stream that
    /// isn't a platform room (an IPTV channel, say) only shows itself here, as an indefinite duration.
    private(set) var hasTimeline = false
    /// Mirrors the player, for play, mute and volume controls drawn outside AVKit's controls.
    private(set) var paused = false
    private(set) var muted = false
    private(set) var volume: Float = 1
    private(set) var quality: Int?
    private var playing: Channel?
    /// What plays now, its live room or plugin address already resolved: what a TV is sent (#749).
    var castChannel: Channel? { playing }
    /// The episode plays from a download on this device, which no server or connection holds up.
    private var savedDownload = false
    private var automatic: URL?
    /// No drive copies in this build: cloud drives are not included.
    var playsDriveCopy: Bool { false }
    /// The live room playing (at the quality chosen), when it opens again with a fresh address (`LiveReopen`), and
    /// when its stream last became ready.
    private var liveRoom: Channel?
    private var liveReopen = LiveReopen()
    private var liveReadyAt: ContinuousClock.Instant?
    private var liveRetrying = false
    /// The episode was already asked for again after its server ignored AVPlayer's byte range.
    private var rangeRetried = false
    /// Whether the episode's link was read by this device after AVPlayer gave up on it, and how (`rescueLink`).
    private var rescueAttempt = PlaybackRescue.Attempt()
    /// When the loopback server behind the episode last listened again (`recoverLoopback`).
    private var loopbackRecovered: ContinuousClock.Instant?
    /// How often the episode opened again after its connection dropped (`resumeAfterDrop`), and whether it did yet.
    private var dropRecovery = PlaybackDropRecovery()
    private var reopenedAfterDrop = false
    /// Whether AVPlayer shows the picture of the file it just opened is being checked; the saved position waits.
    private var checkingPicture = false
    /// The item whose HLS stream is being watched for sound without a picture (`checkSegmentedPicture`).
    private var checkingSegments: ObjectIdentifier?
    /// A live stream is being moved to its live edge (`catchUpLive`).
    private var catchingUpLive = false
    /// A live room's chat, whose comments join `danmaku` as they are sent.
    private var chat: (any LiveChat)?
    /// Download state while connecting or buffering, sampled once a second from AVFoundation's logs.
    struct Transfer {
        var received: Int64 = 0
        /// Over the last few seconds; nil until two samples exist.
        var bytesPerSecond: Double?
        /// What the playing variant needs to play without stalling.
        var required: Double?
        var host: String?
        /// The latest failure while loading media: an HTTP status, or a network error description.
        var failure: String?
        var httpStatus: Int?
    }
    private(set) var transfer = Transfer()
    /// What the player did for this episode so far, newest last: the wait's small print.
    private(set) var steps: [String] = []
    /// Adds a step to the wait's small print; once the picture shows there is no wait to tell about.
    private func note(_ step: String) {
        guard loading || !showsPicture, steps.last != step else { return }
        steps.append(step)
        if steps.count > 4 { steps.removeFirst() }
        noteKind = nil
    }
    /// A step that counts up: each count replaces the last one of the same `kind`.
    private func note(_ step: String, replacing kind: String) {
        guard loading || !showsPicture else { return }
        if noteKind == kind, !steps.isEmpty { steps[steps.count - 1] = step; return }
        note(step)
        noteKind = kind
    }
    private var noteKind: String?
    private var sampler: Task<Void, Never>?
    private var endObserver: NSObjectProtocol?
    private var timeObservation: NSKeyValueObservation?
    private var muteObservation: NSKeyValueObservation?
    private var volumeObservation: NSKeyValueObservation?

    func togglePlayback() {
        cancelSleepFade()
        if player.timeControlStatus == .paused {
            if let item = player.currentItem, item.duration.seconds.isFinite,
               player.currentTime().seconds >= item.duration.seconds - 0.1 {
                // Stopped at the end by the Sleep Timer with the next episode queued: Play goes on to it.
                if upcoming != nil, player.items().count > 1 { player.advanceToNextItem() } else { player.seek(to: .zero) }
            }
            player.play()
        } else { player.pause() }
        // The button follows the tap at once; the player's status (observed below) confirms it a moment later.
        paused = player.rate == 0
    }

    func skip(_ seconds: Double) {
        guard let item = player.currentItem, item.status == .readyToPlay else { return }
        let current = player.currentTime().seconds
        guard current.isFinite else { return }
        let ranges = item.seekableTimeRanges.map(\.timeRangeValue)
        guard let range = ranges.first(where: { CMTimeRangeContainsTime($0, time: player.currentTime()) }) ?? ranges.last else { return }
        let target = min(max(current + seconds, range.start.seconds), range.end.seconds)
        guard target.isFinite else { return }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    /// Shows a live room's chat as danmaku: each comment enters as it arrives.
    private func listen(_ chat: any LiveChat, generation active: UUID) {
        self.chat = chat
        chat.start { text, color, position in
            Task { @MainActor [weak self] in
                guard let self, self.generation == active else { return }
                let now = self.player.currentTime().seconds
                let time = max(now.isFinite ? now + 0.2 : 0, self.sourceDanmaku.last?.time ?? 0)
                self.sourceDanmaku.append(Danmaku(time: time, position: position, color: color, text: text))
                // Keep the recent chat; dropping the oldest restarts the overlay's layout once.
                if self.sourceDanmaku.count > 4000 { self.sourceDanmaku.removeFirst(1000) }
            }
        }
    }

    /// Plays the stream at `quality` (nil: automatic) from where it is now.
    func choose(quality: Int?) {
        guard let channel = playing, quality != self.quality,
              let url = quality.flatMap({ id in qualities.first { $0.id == id }?.url }) ?? automatic else { return }
        if LiveCatalog.isRoom(url) {
            // A live quality is another stream address, fetched now; live has no position to keep.
            let active = generation
            Task {
                guard let resolved = try? await LiveCatalog.resolve(Channel(name: channel.name, group: channel.group, url: url, logo: channel.logo)),
                      self.generation == active else { return }
                self.detachItem()
                self.quality = resolved.current ?? quality
                self.liveRoom = Channel(name: channel.name, group: channel.group, url: url, logo: channel.logo)
                self.configure(resolved.channel, url: resolved.channel.url, generation: active)
            }
            return
        }
        let time = player.currentTime(), paused = player.rate == 0
        detachItem()
        self.quality = quality
        configure(Channel(name: channel.name, group: channel.group, url: url, logo: channel.logo, headers: channel.headers), url: url, generation: generation)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        if paused { player.pause() }
    }

    /// Stops listening to the current item, before another replaces it in the same playback.
    private func detachItem() {
        cancelSleepFade()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        endObserver = nil; failureObserver = nil
        sampler?.cancel(); sampler = nil
    }

    /// A live room that stopped asks its platform for a fresh address and plays on, instead of waiting for the viewer
    /// to try again: one that played a while each time (Huya refuses an address about two minutes in, #488), one
    /// that hasn't once for a playlist that contradicted itself (`LiveReopen`).
    private func retryLive(after failure: Error?) -> Bool {
        if liveRetrying { return true } // The failed item's other report of the same failure.
        let played = liveReadyAt.map { ContinuousClock.now - $0 }
        guard let room = liveRoom, liveReopen.shouldReopen(after: failure, playedFor: played) else { return false }
        liveRetrying = true; loading = true; retrying(via: "live")
        if failure.map({ ($0 as NSError).domain == "CoreMediaErrorDomain" && ($0 as NSError).code == -12312 }) == true {
            LiveRepair.noteContradiction((player.currentItem?.asset as? AVURLAsset)?.url)
        }
        detachItem(); observation = nil
        let active = generation
        Diagnostics.shared.record(.warning, "player", "live retry room=\(room.url.absoluteString) played=\(played.map { "\(Int($0.components.seconds))s" } ?? "-")")
        note(L10n.text("The connection dropped. Reconnecting"))
        Task {
            do {
                let resolved = try await LiveCatalog.resolve(room)
                guard self.generation == active else { return }
                self.liveRetrying = false
                self.configure(resolved.channel, url: resolved.channel.url, generation: active)
            } catch {
                guard self.generation == active else { return }
                self.liveRetrying = false
                self.error = error.localizedDescription; self.loading = false
            }
        }
        return true
    }

    /// A server that answers the first request for a file with the whole file, ignoring the two bytes
    /// AVPlayer asked for (CoreMedia -12939), can answer properly the next time: 立播's v.vimsec.app does
    /// this for every episode nobody has opened lately. One more try, at once, does what Retry would.
    private func retryRange(after failure: Error?, channel: Channel, url: URL, generation active: UUID) -> Bool {
        guard !rangeRetried, Self.ignoredRange(failure) else { return false }
        rangeRetried = true; retrying(via: "range")
        detachItem(); observation = nil
        Diagnostics.shared.record(.warning, "player", "range retry host=\(url.host() ?? "-") \(failure.map(Self.describe) ?? "-")")
        configure(channel, url: url, generation: active)
        return true
    }

    /// A stream AVPlayer gave up on opens once more another way, once per playback:
    /// - a direct HLS stream it can't get past (`HLSProxy.recovers`: a first playlist that took 20 s, one it can't read)
    ///   through the local proxy, which asks again, waits at most 30 s in all and repairs the playlist and segments;
    /// - a plugin's loopback server that answered 502, 503 or 504 (the plugin's own fetch failed) is asked again.
    /// Not a live room: its platform gives a fresh address sooner (`retryLive`). When the proxy can't get the playlist
    /// either, `giveUp` reports the stream's own failure (with the proxy's reason) and moves on to the next line.
    /// `gatewayOnly`: only the plugin-again rung, asked first in the failure chain (cheapest; nothing else matches 502-504).
    private func retryThroughProxy(after failure: Error?, channel: Channel, url: URL, generation active: UUID, gatewayOnly: Bool = false,
                                   otherwise giveUp: @escaping @MainActor (String?) -> Void) -> Bool {
        guard !rungTried, proxy == nil, liveRoom == nil, ["http", "https"].contains(url.scheme),
              !LocalMediaServer.shared.serves(url) else { return false }
        let loopback = ["127.0.0.1", "localhost"].contains(url.host() ?? "")
        let status = transfer.httpStatus ?? item?.errorLog()?.events.last?.errorStatusCode
        let chosen: String
        if !gatewayOnly, HLSProxy.recovers(failure) { chosen = "hls-proxy" }
        else if loopback, HLSProxy.gatewayFailure(failure) || [502, 503, 504].contains(status ?? 0) { chosen = "plugin-again" }
        else { return false }
        rungTried = true; rung = chosen; retrying(via: chosen)
        detachItem(); observation = nil; loading = true
        Diagnostics.shared.record(.warning, "player", "retry rung=\(chosen) host=\(url.host() ?? "-") \(failure.map(Self.describe) ?? "-")")
        preparation = Task { [weak self] in
            guard chosen == "hls-proxy" else {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.generation == active, !Task.isCancelled else { return }
                self.configure(channel, url: url, generation: active)
                return
            }
            let adapter = HLSProxy(headers: channel.headers)
            let address: URL
            do { address = try await adapter.start(url: url, patience: .retry) }
            catch {
                guard let self, self.generation == active, !Task.isCancelled else { return }
                Diagnostics.shared.record(.warning, "player", "retry rung=hls-proxy gave up host=\(url.host() ?? "-") \(error.localizedDescription)")
                giveUp(error.localizedDescription)
                return
            }
            guard let self, self.generation == active, !Task.isCancelled else { await adapter.stop(); return }
            self.proxy = adapter; self.proxyOrigin = url
            if self.automatic == url { self.automatic = address }
            self.configure(channel, url: address, generation: active)
        }
        return true
    }
    /// The end of a playback that failed for good: the failure line for the reports (the stream's own failure; when the
    /// proxy rung couldn't get past it either, its reason as the upstream one), then a live room's fresh address or
    /// the next line, else the error on screen.
    private func giveUp(_ failure: Error?, item: AVPlayerItem, channel: Channel, url: URL, refused: Bool, network: Bool, proxyReason: String?) {
        rung = nil
        let detail = failure.map(Self.describe) ?? "-"
        // The proxy's own last failure when the once-a-second sample missed it (a lookup that failed at once).
        let upstream = transfer.failure ?? proxy?.stats.snapshot.failure ?? proxyReason
        Diagnostics.shared.record(.error, "player", "failed host=\(transfer.host ?? proxy?.stats.snapshot.host ?? channel.url.host() ?? "-") \(upstream.map { "upstream=\($0) " } ?? "")\(detail) \(failureContext(channel, url: url, item: item))")
        if retryLive(after: failure) { return }
        if tryNextLine(after: failure) { return }
        // A refused link is usually an expired one: say so in plain words rather than the system's.
        let expired = refused || [401, 403, 404, 410].contains(transfer.httpStatus ?? 0)
        loading = false
        errorSymbol = expired ? "clock.badge.exclamationmark" : network ? "wifi.exclamationmark" : "play.slash.fill"
        error = expired ? L10n.text("This episode's link may have expired. Open it again, or try another line.")
            : failure?.localizedDescription ?? L10n.text("This media cannot be played. Try another channel or source.")
    }

    /// The rung that got the stream playing, in the log: which one, and what the proxy repaired.
    private func noteRungRecovered(_ url: URL) {
        guard let rung else { return }
        self.rung = nil
        let proxy = proxy
        Task {
            let repairs = await proxy?.repairs ?? []
            Diagnostics.shared.record(.warning, "player", "recovered rung=\(rung) host=\(proxy?.stats.snapshot.host ?? url.host() ?? "-") repairs=\(repairs.isEmpty ? "-" : repairs.joined(separator: ","))")
        }
    }

    /// A link AVPlayer gave up on at once that this device can still read (`PlaybackRescue`): a server that still
    /// ignores the byte range AVPlayer asks for first after `retryRange`'s one more try (-12939), or a certificate
    /// AVPlayer refuses. Once per episode, before anything of it played, for a failure no other rung reopened yet. A
    /// link that can't be rescued opens as it was, so it fails and is reported exactly as before.
    private func rescueLink(after failure: Error?, channel: Channel, url: URL, generation active: UUID) -> Bool {
        let proxied = proxy?.serves(url) == true
        let found = PlaybackRescue.trouble(failure) ?? (proxied && HLSProxy.certificate(proxy?.stats.snapshot.code) ? .insecure : nil)
        guard !rescueAttempt.tried, !rescueAttempt.ready, !reopenedAfterDrop, loopbackRecovered == nil,
              let trouble = found, trouble == .insecure || rangeRetried, ["http", "https"].contains(url.scheme),
              !LocalMediaServer.shared.serves(url) else { return false }
        // Through the HLS proxy (always on the Mac) a refused certificate reaches AVPlayer as 495: read the proxy's upstream.
        let source = proxied && trouble == .insecure ? proxyOrigin ?? url : url
        rescueAttempt.tried = true
        detachItem(); observation = nil; loading = true
        Diagnostics.shared.record(.warning, "player", "rescue trouble=\(trouble.rawValue) host=\(url.host() ?? "-") \(failure.map(Self.describe) ?? "-")")
        let began = ContinuousClock.now
        preparation = Task { [weak self] in
            var rescued: PlaybackRescue.Rescued?
            do { rescued = try await PlaybackRescue.open(source, headers: channel.headers, trouble: trouble) }
            catch { if !Task.isCancelled { Diagnostics.shared.record(.warning, "player", "rescue declined host=\(source.host() ?? "-") \(Self.describe(error))") } }
            guard let self, self.generation == active, !Task.isCancelled else {
                if let rescued { PlaybackRescue.stop(rescued.url) }
                return
            }
            guard let rescued else { self.retrying(via: "rescue-origin"); return self.configure(channel, url: url, generation: active) }
            self.rescueAttempt.address = rescued.url; self.rescueAttempt.rung = rescued.rung; self.rescueAttempt.origin = url
            self.rescueAttempt.trouble = trouble; self.rescueAttempt.began = began; self.retrying(via: rescued.rung)
            if self.automatic == url { self.automatic = rescued.url }
            self.configure(channel, url: rescued.url, generation: active)
        }
        return true
    }

    /// A rescued address that failed before it played: the link opens as it was, so it fails and is reported exactly
    /// as before. One that played, whose loopback iOS took back (-1004, -1005), or whose file AVPlayer refuses goes on
    /// to the rungs after it instead (`recoverLoopback`, `resumeAfterDrop`, the audio converter), from where it was.
    private func rescueFailed(after failure: Error?, channel: Channel, url: URL, generation active: UUID) -> Bool {
        guard let rung = rescueAttempt.rung, let origin = rescueAttempt.origin, url == rescueAttempt.address, !rescueAttempt.ready else { return false }
        if let code = Self.urlErrorCode(failure), [NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost].contains(code) { return false }
        if Self.unsupportedFormat(failure) || Self.refusedFile(failure) { return false }
        Diagnostics.shared.record(.warning, "player", "rescue failed rung=\(rung) host=\(origin.host() ?? "-") \(failure.map(Self.describe) ?? "-")")
        detachItem(); observation = nil
        stopRescue(); retrying(via: "rescue-origin")
        if automatic == url { automatic = origin }
        configure(channel, url: origin, generation: active)
        return true
    }

    /// AVPlayer can't read the file it was given (AVFoundation -11828, -11829).
    nonisolated static func refusedFile(_ error: Error?) -> Bool {
        var current = error as NSError?
        while let error = current {
            if error.domain == AVFoundationErrorDomain, [-11828, -11829].contains(error.code) { return true }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// Closes what the episode's rescue opened.
    private func stopRescue() {
        if let address = rescueAttempt.address { PlaybackRescue.stop(address) }
        rescueAttempt.address = nil; rescueAttempt.rung = nil
    }

    /// iOS and tvOS take back a suspended app's listening sockets: after a pause in the background, AVPlayer finds
    /// the loopback server behind a repackaged file, a plugin's proxy, the HLS proxy or a saved download refusing
    /// (-1004) and gives up 30 s later.
    /// The server listens again, on a new port, and the episode opens there where it was. At most once a minute, so
    /// a server that stays down shows its error.
    private func recoverLoopback(_ code: Int?, channel: Channel, url: URL, generation active: UUID) -> Bool {
        guard let code, [NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost].contains(code),
              LocalMediaServer.shared.serves(url) || proxy?.serves(url) == true || PlaybackRescue.owns(url),
              loopbackRecovered.map({ $0.duration(to: .now) > .seconds(60) }) ?? true else { return false }
        loopbackRecovered = .now; retrying(via: "loopback")
        let position = player.currentTime().seconds
        detachItem(); observation = nil; loading = true
        Diagnostics.shared.record(.warning, "player", "loopback refused code=\(code) at=\(position.isFinite ? Int(position) : -1)s; listening again")
        let adapter = proxy.flatMap { $0.serves(url) ? $0 : nil }
        preparation = Task { [weak self] in
            var fresh: URL?, failure: Error?
            do {
                if let adapter { fresh = try await adapter.relisten(url) }
                else if LocalMediaServer.shared.serves(url) { fresh = try await LocalMediaServer.shared.relisten(url) }
                else if PlaybackRescue.owns(url) { fresh = try await PlaybackRescue.relisten(url) }
            }
            catch { failure = error }
            guard let self, self.generation == active, !Task.isCancelled else { return }
            guard let fresh else {
                if let failure { Diagnostics.shared.failure("player", "loopback relisten", failure) }
                self.error = failure?.localizedDescription ?? L10n.text("Playback was interrupted."); self.loading = false; return
            }
            if position.isFinite, position > 0 { self.pendingResume = position }
            if self.automatic == url { self.automatic = fresh }
            if self.rescueAttempt.address == url { self.rescueAttempt.address = fresh }
            self.configure(channel, url: fresh, generation: active)
        }
        return true
    }

    /// An on-demand episode whose connection dropped or stalled (NSURL -1005, or Core Media -15628 after "No response
    /// for media file") stops there: AVPlayer doesn't ask again by itself. It opens again where it was, a few times and
    /// a little later each time (`PlaybackDropRecovery`), and so does a reopening that can't connect yet. Live streams
    /// and saved downloads don't, and the error shows once the attempts are used up.
    private func resumeAfterDrop(_ failure: Error?, channel: Channel, url: URL, generation active: UUID) -> Bool {
        guard !isLive, !savedDownload, !url.isFileURL, hasTimeline || reopenedAfterDrop else { return false }
        let current = player.currentTime().seconds
        let position = pendingResume ?? (current.isFinite ? current : 0)
        guard let delay = dropRecovery.delay(after: failure, position: position) else { return false }
        reopenedAfterDrop = true; retrying(via: "drop")
        detachItem(); observation = nil; loading = true
        Diagnostics.shared.record(.warning, "player", "dropped host=\(transfer.host ?? url.host() ?? "-") at=\(Int(position))s attempt=\(dropRecovery.attempts) \(failure.map(Self.describe) ?? "-"); reopening")
        note(L10n.text("The connection dropped. Reconnecting"))
        preparation = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.generation == active, !Task.isCancelled else { return }
            if position > 1 { self.pendingResume = position }
            self.configure(channel, url: url, generation: active)
        }
        return true
    }

    /// The URL error code behind a failure, through its underlying errors.
    nonisolated static func urlErrorCode(_ error: Error?) -> Int? {
        var current = error as NSError?
        while let error = current {
            if error.domain == NSURLErrorDomain { return error.code }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }

    /// The other line could not be resolved either: show why instead of loading forever.
    func lineSwitchFailed(_ message: String) {
        guard switchNotice != nil else { return }
        switchNotice = nil; error = message; loading = false
    }

    func setSpeed(_ speed: Float) {
        clearBoost()
        player.defaultRate = speed
        if player.rate != 0 { player.rate = speed }
    }

    /// Another rate while the picture is held (`SpeedBoost`); nil plays at the chosen speed again. It never becomes
    /// the chosen speed, so the speed menu and a later play keep the one picked there. Pausing ends it.
    /// Up to 4× even where the item says it can't fast-forward: an HLS stream without I-frame playlists says so, yet
    /// plays at 3× and 4× in full, as the menu's speeds do. A connection too slow for it holds it lower
    /// (`SpeedBoost.Throttle`, issue #364); `boostWanted` is then the rate the hold asked for.
    private(set) var boost: Float?
    private(set) var boostWanted: Float?
    @ObservationIgnored private var throttle: SpeedBoost.Throttle?
    func setBoost(_ rate: Float?) {
        guard rate == nil || !paused else { return }
        throttle = rate.map { SpeedBoost.Throttle(wanted: Double($0), after: throttle) }
        applyBoost()
    }
    private func applyBoost() {
        boost = throttle.map { Float($0.rate) }
        boostWanted = throttle.flatMap { $0.limited ? Float($0.wanted) : nil }
        guard player.rate != 0 else { return }
        let rate = boost ?? player.defaultRate
        // With video buffered ahead, straight on at the new speed (#1457): a plain `rate` lets AVPlayer first wait
        // to judge whether the download keeps up at it, which would hold the picture and sound as a hold begins
        // or ends. A buffer that runs out still stops to buffer, and the throttle then steps the speed down.
        if player.timeControlStatus == .playing, (bufferedAhead() ?? 0) >= 1 { player.playImmediately(atRate: rate) }
        else { player.rate = rate }
    }
    /// Seconds of video loaded past the playhead.
    /// Nil when AVPlayer reports no loaded range around the playhead (#2175).
    private func bufferedAhead() -> Double? {
        guard let item = player.currentItem else { return nil }
        let now = player.currentTime().seconds
        let ranges = item.loadedTimeRanges.map { range -> (start: Double, end: Double) in
            let value = range.timeRangeValue
            return (value.start.seconds, CMTimeRangeGetEnd(value).seconds)
        }
        let itemAhead = SpeedBoost.bufferedAhead(ranges: ranges, at: now)
        let cloudAhead = 0
        if let itemAhead { return itemAhead + cloudAhead }
        return cloudAhead > 0 ? cloudAhead : nil
    }
    private func clearBoost() { throttle = nil; boost = nil; boostWanted = nil }
    /// Once a second while a hold plays faster than normal: slower before the buffered video runs out, and faster
    /// again while the download keeps up.
    private func throttleBoost(_ item: AVPlayerItem) {
        guard var throttle, throttle.wanted > 1, player.rate != 0, item.status == .readyToPlay else { return }
        let ahead = bufferedAhead()
        let now = player.currentTime().seconds
        let remaining = item.duration.isNumeric && now.isFinite ? max(0, item.duration.seconds - now) : .infinity
        // Only a buffer that ran out counts: AVPlayer also waits a moment to judge a new speed (#796).
        let stalled = player.timeControlStatus == .waitingToPlayAtSpecifiedRate && player.reasonForWaitingToPlay == .toMinimizeStalls
        throttle.update(ahead: ahead, waiting: stalled, remaining: remaining)
        let changed = throttle.rate != self.throttle?.rate
        self.throttle = throttle
        guard changed else { return }
        Diagnostics.shared.record(.info, "player", "hold speed \(throttle.rate)x of \(throttle.wanted)x ahead=\(ahead.map { "\(Int($0))s" } ?? "-")")
        applyBoost()
    }
    private var generation = UUID()
    init() {
        let player = AVQueuePlayer()
        player.volume = PlaybackSession.storedVolume()
        volume = player.volume
        // An episode ends paused on its last frame; only a queued next episode makes the queue move on.
        player.actionAtItemEnd = .pause
        #if DEBUG
        // `-qaMute 1`: QA runs on a shared Mac play silently.
        if UserDefaults.standard.bool(forKey: "qaMute") { player.isMuted = true }
        #if os(iOS) || os(tvOS)
        // `-qaPauseInBackground 1`: pause when the app leaves the screen and play when it is back, as a viewer
        // who pauses and locks the phone does; a paused app is suspended and loses its listening sockets.
        if UserDefaults.standard.bool(forKey: "qaPauseInBackground") {
            NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                Diagnostics.shared.record(.info, "player", "qa background pause at=\(Int(player.currentTime().seconds))s")
                player.pause()
            }
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                Diagnostics.shared.record(.info, "player", "qa active play at=\(Int(player.currentTime().seconds))s")
                player.play()
            }
        }
        #endif
        // `-qaSubtitleStyle <JSON>` saves that subtitle style, as Settings › Subtitle Style does.
        if let json = UserDefaults.standard.string(forKey: "qaSubtitleStyle"),
           let style = try? JSONDecoder().decode(SubtitleStyle.self, from: Data(json.utf8)) { style.save() }
        #endif
        self.player = player
        enhancer = VideoEnhancer(player: player)
        queueObservation = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // A new item starts its own clock: its start is no jump.
                self.clockMark = nil
                self.subtitles.follow(self.player.currentItem)
                self.queueMoved()
            }
        }
        // A style chosen while a video plays (the Mac shows Settings beside the player) also reaches AVPlayer's own
        // subtitles, drawn in Picture in Picture.
        styleObserver = NotificationCenter.default.addObserver(forName: SubtitleStyle.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let rules = Self.subtitleRules()
                for item in self.player.items() { item.textStyleRules = rules }
            }
        }
        delayObserver = NotificationCenter.default.addObserver(forName: SubtitleDelay.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.followSubtitleDelay() }
        }
        // The Sleep Timer (#1198): the sound fades and the video pauses; End of Episode holds the next episode back.
        sleepObservers = [
            NotificationCenter.default.addObserver(forName: SleepTimer.fired, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sleepTimerFired() }
            },
            NotificationCenter.default.addObserver(forName: SleepTimer.changed, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.followSleepTimer() }
            },
        ]
        // Any jump, from our controls or from AVKit's own scrubber on the Mac and Apple TV (`resumeAfterJump`).
        jumpObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.timeJumpedNotification, object: nil, queue: .main) { [weak self] note in
            let jumped = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let jumped, let item = self.player.currentItem, ObjectIdentifier(item) == jumped else { return }
                let seconds = self.player.currentTime().seconds
                if self.clockMark?.jumped(to: seconds, at: ProcessInfo.processInfo.systemUptime) == true { self.resumeAfterJump() }
                self.markClock()
            }
        }
        #if !os(macOS)
        // Leaving the app pauses the video, and soon after the system suspends the app, which closes its connections and
        // the loopback servers some videos play through: coming back, the video loaded all over again (#1388). The app
        // stays awake for the half minute the system allows, so a quick look at another app comes back to it as it was.
        backgroundObservers = [
            NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.player.currentItem != nil else { return }
                    self.backgroundGrace.hold()
                }
            },
            NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.backgroundGrace.release() }
            },
        ]
        #endif
        // How warm the device gets while something plays, in the log, so a report of heat says what was on (#1428).
        thermalObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordThermalState() }
        }
        externalSubtitles.cues = subtitles
        externalSubtitles.player = player
        externalSubtitles.changed = { [weak self] in self?.followSubtitleDelay() }
        subtitles.mediaSelectionChanged = { [weak self] in self?.mediaTracks.selectionChanged() }
        subtitles.nativeChosen = { [weak self] in self?.externalSubtitles.nativeChosen() }
        subtitles.clockChanged = { [weak self] in self?.followSubtitleDelay() }
        followSubtitleDelay()
    }
    private var styleObserver: NSObjectProtocol?
    private var sleepObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var backgroundObservers: [NSObjectProtocol] = []
    @ObservationIgnored private let backgroundGrace = BackgroundGrace(name: "Video")
    @ObservationIgnored private var thermalObserver: NSObjectProtocol?
    private func recordThermalState() {
        guard player.currentItem != nil else { return }
        let state = switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
        let seconds = player.currentTime().seconds
        Diagnostics.shared.record(.info, "player", "thermal=\(state) at=\(seconds.isFinite ? Int(seconds) : -1)s playing=\(player.timeControlStatus == .playing) "
            + "smoothing=\(enhancer.status.smoothing) upscaling=\(enhancer.status.upscaling) danmaku=\(!danmaku.isEmpty)")
    }
    @ObservationIgnored private var jumpObserver: NSObjectProtocol?
    @ObservationIgnored private var jumpResume: Task<Void, Never>?
    /// Where the clock was at the last jump notice or once-a-second sample: none before the first sample, so the
    /// seek that restores a saved place (which has its own start, `restorePositionIfNeeded`) isn't taken for one.
    @ObservationIgnored private var clockMark: SeekResume.Clock?
    private func markClock() {
        let seconds = player.currentTime().seconds
        clockMark = seconds.isFinite
            ? SeekResume.Clock(seconds: seconds, at: ProcessInfo.processInfo.systemUptime,
                               rate: player.timeControlStatus == .playing ? Double(player.rate) : 0)
            : nil
    }
    /// For a while after a jump (a seek: `SeekResume.Clock` tells a rate change apart), plays as soon as a few seconds
    /// are in, rather than waiting for AVPlayer to predict the download will keep up (`SeekResume`, #1213). It looks
    /// five times a second, only until the player is paused or the time is up; live streams keep to their edge.
    private func resumeAfterJump() {
        jumpResume?.cancel()
        let active = generation
        jumpResume = Task { @MainActor [weak self] in
            let end = Date().addingTimeInterval(SeekResume.window)
            while Date() < end {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self, self.generation == active, let item = self.player.currentItem,
                      self.player.timeControlStatus != .paused else { return }
                let reason = self.player.reasonForWaitingToPlay
                guard self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate, item.status == .readyToPlay,
                      !item.duration.isIndefinite, reason == .toMinimizeStalls || reason == .evaluatingBufferingRate else { continue }
                let now = self.player.currentTime()
                let loaded = item.loadedTimeRanges.lazy.map(\.timeRangeValue).first { CMTimeRangeContainsTime($0, time: now) }
                let ahead = loaded.map { CMTimeRangeGetEnd($0).seconds - now.seconds } ?? 0
                guard SeekResume.shouldPlay(ahead: ahead, remaining: item.duration.seconds - now.seconds) else { continue }
                Diagnostics.shared.record(.info, "player", "jump resume ahead=\(String(format: "%.1f", ahead))s")
                self.player.playImmediately(atRate: self.player.rate)
            }
        }
    }
    @ObservationIgnored private var delayObserver: NSObjectProtocol?
    /// Shows delayed subtitle lines at the player's clock (`SubtitleCues.advance`), only while a delay is set.
    @ObservationIgnored private var subtitleTimeObserver: Any?
    /// Delayed subtitles (#599) reach the screen on a quarter-second clock rather than on the once-a-second sample.
    /// A subtitle file the app shows itself (#576) has a twentieth-of-a-second one, so its lines are on time to a
    /// frame or so. Otherwise the lines go up as AVPlayer hands them over, so no clock runs: it would only wake the
    /// main thread.
    private func followSubtitleDelay() {
        let interval: Double? = subtitles.needsClock ? 0.05 : SubtitleDelay.load() > 0 ? 0.25 : nil
        guard interval != subtitleClockInterval else { return }
        if let observer = subtitleTimeObserver { player.removeTimeObserver(observer); subtitleTimeObserver = nil }
        subtitleClockInterval = interval
        guard let interval else { return }
        subtitleTimeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: interval, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.subtitles.advance(to: time.seconds) }
        }
    }
    @ObservationIgnored private var subtitleClockInterval: Double?
    let mediaTracks = MediaTracks()
    @ObservationIgnored private var subtitleScope: String?

    private static func subtitleScope(for channel: Channel) -> String? {
        if let scope = channel.historyContext?.id ?? channel.skipScope { return scope }
        if channel.url.scheme == DownloadLibrary.scheme, let id = channel.url.host(),
           let download = DownloadLibrary.shared.item(id: id) {
            return "download:" + DownloadShow.key(for: download)
        }
        return nil
    }

    /// A menu action, including one from AVKit's tvOS delegate. Automatic selections never write a preference.
    func chooseSubtitle(_ option: AVMediaSelectionOption?, in group: AVMediaSelectionGroup) {
        guard let item, player.currentItem === item, let tracks = mediaTracks.legible, tracks.group == group else { return }
        let description: TrackLabel.Option?
        if let option {
            guard let index = tracks.options.firstIndex(of: option) else { return }
            description = tracks.descriptions[index]
        } else {
            guard group.allowsEmptySelection else { return }
            description = nil
        }
        if item.currentMediaSelection.selectedMediaOption(in: group) != option { mediaTracks.select(option, in: tracks) }
        externalSubtitles.nativeChosen()
        SubtitleChoice.remember(description, for: subtitleScope)
    }

    /// A missing track may fall back for this episode. Only the viewer can change the remembered choice.
    private func restoreSubtitleChoice(_ item: AVPlayerItem, tracks: MediaTracks.Group?, scope: String?) -> Bool {
        guard let preference = SubtitleChoice.preference(for: scope) else { return false }
        let option: AVMediaSelectionOption?
        switch preference {
        case .off:
            guard let tracks else { return true }
            guard tracks.group.allowsEmptySelection else { return false }
            option = nil
        case .track(let choice):
            guard let tracks, let index = choice.match(tracks.descriptions, in: scope) else { return false }
            option = tracks.options[index]
        }
        if let group = tracks?.group, item.currentMediaSelection.selectedMediaOption(in: group) != option {
            item.select(option, in: group)
        }
        return true
    }

    /// Subtitle files beside the video, or added while it plays, that the app shows itself (#576).
    let externalSubtitles = ExternalSubtitles()
    /// The subtitle lines the player's overlay draws (`SubtitleOverlay`).
    let subtitles = SubtitleCues()
    /// The saved subtitle style as the rule AVPlayer lays over every subtitle cue it draws itself.
    private static func subtitleRules() -> [AVTextStyleRule] {
        AVTextStyleRule(textMarkupAttributes: SubtitleStyle.load().attributes).map { [$0] } ?? []
    }
    private var observation: NSKeyValueObservation?
    private var failureObserver: NSObjectProtocol?
    private var preparation: Task<Void, Never>?
    /// The local HLS proxy the stream plays through: always on the Mac, elsewhere after a direct failure (`retryThroughProxy`).
    private var proxy: HLSProxy?
    /// The retry rung this playback took (`retryThroughProxy`), until it plays or fails.
    private var rung: String?
    /// What `proxy` fetches: the stream's own address, for `rescueLink` when the proxy answered 495 for its certificate.
    private var proxyOrigin: URL?
    private var rungTried = false
    /// The session on screen, which casts from the Bilibili app control.
    static weak var current: PlaybackSession?
    func start(_ channel: Channel) {
        Self.current = self
        // The queue has already moved on to this episode by itself.
        if let advanced, advanced == channel { self.advanced = nil; return }
        lines = channel.alternates.isEmpty ? [] : channel.lines
        line = 0; triedLines = [0]
        open(channel)
    }

    /// Plays line `index` of the live channel, as the viewer chose: the others are there to fall back on again.
    func choose(line index: Int) {
        guard lines.indices.contains(index), index != line else { return }
        Diagnostics.shared.record(.info, "player", "line \(index + 1)/\(lines.count) chosen")
        line = index; triedLines = [index]
        open(lines[index])
    }

    /// The channel's next line not tried since it was chosen, when this one failed or hasn't started (#679); false when
    /// there is none left. A line that played a while before it dropped leaves every line to try again.
    private func tryNextLine(after failure: Error?) -> Bool {
        guard lines.count > 1 else { return false }
        if let readyAt = lineReadyAt, readyAt.duration(to: .now) > .seconds(60) { triedLines = [line] }
        guard let next = (1..<lines.count).map({ (line + $0) % lines.count }).first(where: { !triedLines.contains($0) }) else { return false }
        Diagnostics.shared.record(.warning, "player", "line \(line + 1)/\(lines.count) \(failure.map(Self.describe) ?? "not ready"); trying line \(next + 1)")
        let failed = line
        line = next; triedLines.insert(next)
        // The same play goes on, on another line: one attempt, not one per line.
        let carried = attempt?.outcome == nil ? attempt : nil; attempt = nil
        open(lines[next])
        if let carried { attempt = carried }
        retrying(via: "line")
        note(L10n.text("Line %@ didn't play. Trying line %@.", "\(failed + 1)", "\(next + 1)"))
        return true
    }

    private func open(_ channel: Channel) {
        savedDownload = channel.url.scheme == DownloadLibrary.scheme
        stop(); error = nil; errorSymbol = "play.slash.fill"; loading = true; showsPicture = false; openedAt = .now; sourceDanmaku = []; qualities = []; quality = nil; switchNotice = nil
        let live = channel.replay == nil && (LiveCatalog.isRoom(channel.url) || channel.group == L10n.text("Bilibili Live"))
        begin(channel, live: live)
        isLive = live
        // Live: a live room, or a channel of a live playlist (only on-demand episodes have a history context).
        attempt = PlayAttempt(live: live || channel.historyContext == nil, address: channel.url)
        liveRoom = LiveCatalog.isRoom(channel.url) ? channel : nil; liveReopen = LiveReopen(); liveRetrying = false; rangeRetried = false; rung = nil; rungTried = false
        stopRescue(); rescueAttempt = PlaybackRescue.Attempt()
        loopbackRecovered = nil; dropRecovery = PlaybackDropRecovery(); reopenedAfterDrop = false
        let activeGeneration = generation
        lineReadyAt = nil
        if lines.count > 1 {
            lineWatch = Task { [weak self] in
                try? await Task.sleep(for: Self.lineWait)
                guard let self, !Task.isCancelled, self.generation == activeGeneration, self.lineReadyAt == nil, self.error == nil else { return }
                _ = self.tryNextLine(after: nil)
            }
        }
        Diagnostics.shared.record(.info, "player", "start name=\(channel.name) group=\(channel.group) url=\(channel.url.absoluteString) headers=\(channel.headers.keys.sorted().joined(separator: ","))")
        preparation = Task { [weak self] in
            guard let self else { return }
            // A live room becomes its current stream address now; the address expires.
            var channel = channel
            var liveQualities: [StreamQuality] = [], liveQuality: Int?
            if let (platform, id) = LiveCatalog.room(channel.url), let chat = LiveChats.make(platform, room: id, address: channel.url) { self.listen(chat, generation: activeGeneration) }
            if LiveCatalog.isRoom(channel.url) {
                self.note(L10n.text("Finding the live stream"))
                do { (channel, liveQualities, liveQuality) = try await LiveCatalog.resolve(channel) }
                catch {
                    guard self.generation == activeGeneration, !Task.isCancelled else { return }
                    Diagnostics.shared.failure("player", "live room=\(channel.url.absoluteString)", error)
                    self.error = error.localizedDescription; self.loading = false; return
                }
            } else {
                // A Huya stream a playlist reaches through an FLV relay plays as HLS.
                channel = await LiveCatalog.playable(channel)
            }
            let prepared: Prepared
            do { prepared = try await self.prepare(channel) }
            catch {
                guard self.generation == activeGeneration, !Task.isCancelled else { return }
                if self.tryNextLine(after: error) { return }
                self.error = error.localizedDescription; self.loading = false; return
            }
            guard self.generation == activeGeneration, !Task.isCancelled else { return Self.stopAdapter(prepared) }
            #if os(macOS)
            self.proxy = prepared.adapter; self.proxyOrigin = prepared.adapterOrigin
            #endif
            let address = prepared.url
            self.configure(channel, url: address, generation: activeGeneration)
            self.playing = channel; self.automatic = address
            self.externalSubtitles.begin(channel, playing: address)
            self.qualities = liveQualities
            self.quality = liveQuality
            if DanmakuSource.has(channel.url), let comments = await DanmakuSource.comments(for: channel.url),
               self.generation == activeGeneration { self.sourceDanmaku = comments }
        }
    }
    private func configure(_ channel: Channel, url: URL, generation activeGeneration: UUID) {
        clockMark = nil
        #if !os(macOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Not a reason to stop: the item plays on, its sound once the session can start (AVAudioSession '!pla'
            // when another app holds it). As an error it hid a playing video behind the error screen.
            Diagnostics.shared.failure("player", "audio session", error)
        }
        #endif
        if !url.isFileURL {
            note(L10n.text("Connecting to %@", Self.server(url.host())))
        }
        attach(channel, url: url, generation: activeGeneration)
    }

    private func attach(_ channel: Channel, url: URL, generation activeGeneration: UUID) {
        cancelSleepFade()
        let item = makeItem(channel, url: url)
        watch(item, channel: channel, url: url, generation: activeGeneration)
        // A repackaged file, or a rescued link, is served on this device's loopback, which an AirPlay receiver can't reach.
        player.allowsExternalPlayback = !PlaybackRescue.owns(url)
        player.preventsDisplaySleepDuringVideoPlayback = true
        player.replaceCurrentItem(with: item)
        #if DEBUG
        // `-qaSpeed <rate>` plays at that speed, as picking it in the speed menu does.
        let qaSpeed = UserDefaults.standard.float(forKey: "qaSpeed")
        if qaSpeed > 0 { player.defaultRate = qaSpeed }
        #endif
        if pendingResume == nil { player.play() } else { seekAhead() }
        #if DEBUG
        // `-qaSeek <seconds>` starts playback there, for screenshots.
        let qaSeek = UserDefaults.standard.double(forKey: "qaSeek")
        if qaSeek > 0 { player.seek(to: CMTime(seconds: qaSeek, preferredTimescale: 600)) }
        #endif
    }

    /// Request headers for an asset. iPhone, iPad and Apple TV ignore a `User-Agent` among the header
    /// fields and send their own, which hosts that expect a browser refuse (HTTP 403); the user-agent key
    /// is honoured everywhere.
    static func assetOptions(headers: [String: String]) -> [String: Any] {
        var options: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": headers]
        if let agent = headers.first(where: { $0.key.lowercased() == "user-agent" })?.value, !agent.isEmpty { options[AVURLAssetHTTPUserAgentKey] = agent }
        return options
    }

    /// The item for a prepared stream, with the request headers and buffer its source needs.
    private func makeItem(_ channel: Channel, url: URL) -> AVPlayerItem {
        // Some providers require request headers. AVURLAsset's HTTP-header option is
        // best-effort and is not a guarantee for every redirected HLS segment.
        let asset = LiveRepair.asset(for: url)
            ?? AVURLAsset(url: url, options: Self.assetOptions(headers: channel.headers)
                .merging(MediaTypeHint.mimeType(for: url).map { [AVURLAssetOverrideMIMETypeKey: $0] } ?? [:]) { $1 })
        let item = AVPlayerItem(asset: asset)
        item.textStyleRules = Self.subtitleRules()
        subtitles.attach(item)
        #if DEBUG
        // `-qaSubtitle <n>` turns on the item's nth subtitle track, for screenshots of how subtitles look.
        if let index = UserDefaults.standard.string(forKey: "qaSubtitle").flatMap(Int.init) {
            // Or the system's own choice (subtitles off) replaces it once the item loads.
            player.appliesMediaSelectionCriteriaAutomatically = false
            Task { @MainActor in
                if let group = try? await asset.loadMediaSelectionGroup(for: .legible), group.options.indices.contains(index) {
                    item.select(group.options[index], in: group)
                }
            }
        }
        #endif
        return item
    }

    /// Follows the episode's item (ready, failed, ended), the player's state, and the transfer, for this playback.
    private func watch(_ item: AVPlayerItem, channel: Channel, url: URL, generation activeGeneration: UUID) {
        self.item = item
        liveReadyAt = nil
        mediaTracks.follow(item)
        hasTimeline = item.status == .readyToPlay && item.duration.isNumeric
        observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            let timeline = status == .readyToPlay && item.duration.isNumeric
            let failure = item.error
            let refused = Self.refusedLink(failure, log: item.errorLog())
            let network = Self.networkFailure(failure)
            Task { @MainActor [weak self] in
                guard let self, self.generation == activeGeneration else { return }
                self.hasTimeline = timeline
                if status == .readyToPlay {
                    if self.isLive { self.liveReadyAt = .now }
                    self.lineReadyAt = .now; self.lineWatch?.cancel(); self.lineWatch = nil
                    self.noteRungRecovered(url)
                    Task { [weak self] in
                        guard let self, self.item === item else { return }
                        await self.mediaTracks.load(item)
                        guard self.generation == activeGeneration, self.item === item, !self.externalSubtitles.manuallyChoseFile else { return }
                        if self.restoreSubtitleChoice(item, tracks: self.mediaTracks.legible, scope: self.subtitleScope) {
                            self.externalSubtitles.nativeChosen()
                        }
                    }
                    self.checkingPicture = false
                    self.restorePositionIfNeeded(item)
                    self.loading = self.pendingResume != nil || self.restoringPosition
                    Diagnostics.shared.record(.info, "player", "ready host=\(self.transfer.host ?? channel.url.host() ?? "-")")
                    if !self.rescueAttempt.ready, url == self.rescueAttempt.address, let rung = self.rescueAttempt.rung, let began = self.rescueAttempt.began {
                        Diagnostics.shared.record(.warning, "player", "rescued rung=\(rung) trouble=\(self.rescueAttempt.trouble?.rawValue ?? "-") host=\(self.rescueAttempt.origin?.host() ?? "-") after=\(began.duration(to: .now).components.seconds)s")
                    }
                    self.rescueAttempt.ready = true
                }
                if status == .failed {
                    if self.rescueFailed(after: failure, channel: channel, url: url, generation: activeGeneration) { return }
                    if self.retryThroughProxy(after: failure, channel: channel, url: url, generation: activeGeneration, gatewayOnly: true, otherwise: { _ in }) { return }
                    if self.retryRange(after: failure, channel: channel, url: url, generation: activeGeneration) { return }
                    if self.rescueLink(after: failure, channel: channel, url: url, generation: activeGeneration) { return }
                    let giveUp = { @MainActor [weak self] (reason: String?) -> Void in
                        guard let self else { return }
                        self.giveUp(failure, item: item, channel: channel, url: url, refused: refused, network: network, proxyReason: reason)
                    }
                    // The rest of the chain. One tail: `giveUp`.
                    let rest: @MainActor () -> Void = { [weak self] in
                        guard let self, self.generation == activeGeneration else { return }
                        if self.recoverLoopback(Self.urlErrorCode(failure), channel: channel, url: url, generation: activeGeneration) { return }
                        if self.reopenedAfterDrop, self.resumeAfterDrop(failure, channel: channel, url: url, generation: activeGeneration) { return }
                        if self.retryThroughProxy(after: failure, channel: channel, url: url, generation: activeGeneration, otherwise: giveUp) { return }
                        giveUp(nil)
                    }
                    rest()
                }
            }
        }
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self, weak item] notification in
            let failure = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            let message = failure?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.generation == activeGeneration else { return }
                if self.recoverLoopback(Self.urlErrorCode(failure), channel: channel, url: url, generation: activeGeneration) { return }
                if self.resumeAfterDrop(failure, channel: channel, url: url, generation: activeGeneration) { return }
                Diagnostics.shared.record(.error, "player", "interrupted host=\(self.transfer.host ?? channel.url.host() ?? "-") at=\(Int(self.player.currentTime().seconds.isFinite ? self.player.currentTime().seconds : -1))s \(failure.map(Self.describe) ?? "-") \(self.failureContext(channel, url: url, item: item))")
                if self.retryLive(after: failure) { return }
                if self.tryNextLine(after: failure) { return }
                self.error = message ?? L10n.text("Playback was interrupted."); self.loading = false
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == activeGeneration else { return }
                // Sleep Timer, End of Episode: stop here; a queued next episode waits for Play.
                if SleepTimer.shared.endsWithItem {
                    self.saveHistory(completed: true)
                    _ = SleepTimer.shared.itemEnded()
                    return
                }
                if self.sleepFadeRevision != nil { self.saveHistory(completed: true); return }
                // The queue plays the next episode by itself; `queueMoved` takes over from here.
                if self.upcoming != nil { return }
                self.saveHistory(completed: true)
                if self.looping {
                    self.skipPass = EpisodeSkipPass()
                    self.player.seek(to: .zero); self.player.play()
                } else { self.onPlaybackEnded?() }
            }
        }
        timeObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            let paused = player.timeControlStatus == .paused
            let playing = player.timeControlStatus == .playing
            Task { @MainActor [weak self] in
                guard let self, self.generation == activeGeneration else { return }
                if playing, !self.sleepFade.isActive, self.sleepFadeRevision != nil { self.cancelSleepFade() }
                self.buffering = waiting
                self.paused = paused
                #if os(macOS)
                self.displayAwake.hold(!paused)
                #endif
                if paused { self.clearBoost(); self.saveHistory() }
                // The first frame lands a beat after playback starts; keep the artwork until then, so no black flashes between.
                // A queued episode the queue moved to plays under the picture already on screen.
                if playing, self.showsPicture { self.countPlay(.started) }
                if playing, !self.showsPicture {
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(350))
                        guard let self, self.generation == activeGeneration, self.player.timeControlStatus == .playing, !self.showsPicture else { return }
                        self.showsPicture = true
                        self.countPlay(.started)
                        // How long the viewer waited, and from where it plays: a slow resume shows up in a report (#1455).
                        let seconds = self.player.currentTime().seconds
                        Diagnostics.shared.record(.info, "player", "picture after=\(String(format: "%.2f", Date().timeIntervalSince(self.openedAt) - 0.35))s at=\(seconds.isFinite ? Int(seconds) : -1)s")
                    }
                }
            }
        }
        muteObservation = player.observe(\.isMuted, options: [.initial, .new]) { [weak self] player, _ in
            let muted = player.isMuted
            Task { @MainActor [weak self] in self?.muted = muted }
        }
        // Every way of changing the player's sound goes through this property: AVKit's own slider, the Mac wheel
        // and arrow keys, and the Sleep Timer's fade. Keep the last level for the next launch.
        volumeObservation = player.observe(\.volume, options: [.new]) { [weak self] _, change in
            guard let level = change.newValue else { return }
            UserDefaults.standard.set(Double(level), forKey: "playerVolume")
            Task { @MainActor [weak self] in self?.volume = level }
        }
        sampler = Task { [weak self] in
            var history: [(date: Date, bytes: Int64)] = []
            var tick = 0
            while !Task.isCancelled {
                guard self?.sample(&history, tick: tick, channel: channel, url: url, generation: activeGeneration) == true else { return }
                tick += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    private func sample(_ history: inout [(date: Date, bytes: Int64)], tick: Int, channel: Channel, url: URL, generation activeGeneration: UUID) -> Bool {
        guard generation == activeGeneration else { return false }
        let origin = channel.url.host()
        // Once the queue has moved on, `queueMoved` is about to take over the next episode.
        guard let item, player.currentItem === item else { return true }
        restorePositionIfNeeded(item)
        if pendingResume == nil, !restoringPosition { markClock() }
        updateSkipping(item)
        throttleBoost(item)
        catchUpLive(item)
        queueUpcomingIfDue(item)
        if tick % 5 == 0 { saveHistory() }
        let events = item.accessLog()?.events ?? []
        let now = Date()
        var next = Transfer(received: events.reduce(Int64(0)) { $0 + max(0, $1.numberOfBytesTransferred) })
        // HLS through the local proxy: it sees upstream bytes as they arrive.
        let upstream = proxy?.stats.snapshot
        if let upstream { next.received = max(next.received, upstream.received) }
        history.append((now, next.received))
        history.removeAll { now.timeIntervalSince($0.date) > 5 }
        if let first = history.first, now.timeIntervalSince(first.date) >= 1 {
            next.bytesPerSecond = Double(next.received - first.bytes) / now.timeIntervalSince(first.date)
        }
        // Prefer the decoded media's own bitrate; single-variant playlists declare none. AVFoundation's
        // average counts a half-fetched segment's bytes against finished durations, so it runs high
        // mid-segment and settles at each boundary: keep the lowest value seen.
        if let last = events.last {
            // The access log can report an infinite bitrate (crash d7b70a868820); skip it rather than show it.
            let media = max(0, last.averageVideoBitrate) + max(0, last.averageAudioBitrate)
            let indicated = last.indicatedBitrate
            let current = media > 0 && media.isFinite ? media / 8 : (indicated > 0 && indicated.isFinite ? indicated / 8 : nil)
            next.required = [current, transfer.required].compactMap { $0 }.min()
        }
        // The Mac plays HLS through a local proxy; name the real server instead.
        let segmentHost = events.last?.uri.flatMap { URL(string: $0)?.host() }
        next.host = segmentHost.flatMap { ["127.0.0.1", "localhost"].contains($0) ? nil : $0 } ?? cloud?.host ?? origin
        if let upstream {
            next.host = upstream.host ?? next.host
            next.httpStatus = upstream.status.flatMap { (400..<600).contains($0) ? $0 : nil }
            next.failure = upstream.failure ?? upstream.status.map { "HTTP \($0)" }
        }
        if next.failure == nil, let error = item.errorLog()?.events.last, let date = error.date, now.timeIntervalSince(date) < 30 {
            // The loopback server behind the episode stopped listening: AVPlayer would keep trying it for 30 s.
            if error.errorDomain == NSURLErrorDomain,
               recoverLoopback(error.errorStatusCode, channel: channel, url: url, generation: activeGeneration) { return false }
            if (400..<600).contains(error.errorStatusCode) { next.httpStatus = error.errorStatusCode }
            next.failure = error.errorComment ?? "\(error.errorDomain) \(error.errorStatusCode)"
        }
        if transfer.received == 0, next.received > 0 { note(L10n.text("Receiving video from %@", Self.server(next.host))) }
        if let failure = next.failure, failure != transfer.failure { note(L10n.text("Trouble with %@ (%@), trying again", Self.server(next.host), failure)) }
        transfer = next
        if (loading || buffering) && tick % 5 == 0 {
            Diagnostics.shared.record(.debug, "player", "waiting host=\(next.host ?? "-") received=\(next.received) speed=\(Int(next.bytesPerSecond ?? -1)) required=\(Int(next.required ?? -1)) failure=\(next.failure ?? "-")")
        }
        return true
    }
    /// A live stream playing before everything its playlist still lists shows a frozen picture (`LiveEdge`); it
    /// jumps to the live edge, as a web player does, instead of waiting for someone to open it again.
    private func catchUpLive(_ item: AVPlayerItem) {
        guard !catchingUpLive, item.status == .readyToPlay, item.duration.isIndefinite, player.timeControlStatus == .playing,
              let edge = LiveEdge.target(position: player.currentTime(), seekable: item.seekableTimeRanges.map(\.timeRangeValue)) else { return }
        catchingUpLive = true
        Diagnostics.shared.record(.info, "player", "live catch-up from=\(Int(player.currentTime().seconds))s to=\(Int(edge.seconds))s")
        player.seek(to: edge) { [weak self] _ in
            Task { @MainActor [weak self] in self?.catchingUpLive = false }
        }
    }
    /// Domain and code of the error and its underlying cause: AVFoundation's messages alone
    /// ("The operation could not be completed") don't tell an HTTP 403 from a decoder failure.
    nonisolated static func describe(_ error: Error) -> String { Diagnostics.describe(error) }
    #if DEBUG
    /// The screen's refresh rate now, which on Apple TV follows the display mode.
    private static var screenRate: Int {
        #if os(macOS)
        return NSScreen.main?.maximumFramesPerSecond ?? 0
        #else
        return UIApplication.shared.appWindowScene?.screen.maximumFramesPerSecond ?? 0
        #endif
    }
    #endif
    /// What a failure report needs besides the error: the source, the way the stream reaches AVPlayer,
    /// its format, and AVPlayer's own last network error (often the HTTP status of one segment).
    private func failureContext(_ channel: Channel, url: URL, item: AVPlayerItem?) -> String {
        let scheme = url.scheme ?? "-"
        let via = ["http", "https"].contains(scheme) ? (["127.0.0.1", "localhost"].contains(url.host() ?? "") ? "local-proxy" : "direct") : scheme
        let format = channel.url.pathExtension.isEmpty ? "-" : String(channel.url.pathExtension.lowercased().prefix(5))
        var text = "source=\(channel.historyContext?.sourceKey ?? "-") live=\(isLive) via=\(via) format=\(format)"
        if let event = item?.errorLog()?.events.last {
            text += " log=\(event.errorStatusCode) \(event.errorDomain) \(event.errorComment ?? "-")"
        }
        return text
    }
    func stop() {
        countPlay(.abandoned); attempt = nil
        cancelSleepFade()
        #if os(macOS)
        displayAwake.hold(false)
        #endif
        saveHistory()
        discardUpcoming()
        upcomingAttempted = false; skipsToUpcoming = false; advanced = nil
        upcomingEpisode = nil; onAdvance = nil; playsOn = { false }; clearBoost()
        stopRescue()
        playing = nil
        externalSubtitles.stop()
        subtitles.follow(nil)
        mediaTracks.follow(nil)
        subtitleScope = nil
        historyContext = nil; pendingResume = nil; restoringPosition = false
        requestedResumePosition = nil; restoredPosition = nil
        skipScope = nil; skipSettings = EpisodeSkipSettings(); skipPass = EpisodeSkipPass()
        skipNotice = nil; introNoticeUntil = nil
        position = 0; duration = 0; editingSkip = false; resumeAfterEditing = false; seekingSegment = false
        sourceSkips = []; skipOffer = nil; skippedSource = []; chapters = []
        onPlaybackEnded = nil; onUnplayableFile = nil
        if player.currentItem != nil {
            let seconds = player.currentTime().seconds
            Diagnostics.shared.record(.info, "player", "stop at=\(seconds.isFinite ? Int(seconds) : -1)s")
        }
        generation = UUID()
        chat?.stop(); chat = nil
        preparation?.cancel(); preparation = nil
        lineWatch?.cancel(); lineWatch = nil
        sampler?.cancel(); sampler = nil
        transfer = Transfer(); steps = []
        if let proxy { Task { await proxy.stop() } }; proxy = nil
        observation = nil
        timeObservation = nil
        muteObservation = nil
        volumeObservation = nil
        buffering = false
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
        player.pause(); player.removeAllItems(); item = nil
    }
    /// Records where the episode is; `item` is the episode's own, which the queue may already have moved past.
    func saveHistory(completed: Bool = false, item: AVPlayerItem? = nil) {
        guard let item = item ?? self.item, item.status == .readyToPlay,
              pendingResume == nil, !restoringPosition, !seekingSegment else { return }
        let length = item.duration.seconds
        let time = completed && length.isFinite ? length : item.currentTime().seconds
        guard time.isFinite, time >= 1 else { return }
        if let playing { recordCachedPlayback?(playing, time, length.isFinite ? length : 0) }
        guard let context = historyContext else { return }
        if lastHistoryPosition.map({ abs($0 - time) >= 0.25 }) ?? true {
            lastHistoryPosition = time
            history.record(context, position: time, duration: length.isFinite ? length : 0)
        }
    }

    /// Per-episode state: where its history goes, where it resumes, the intro and outro to skip, its danmaku.
    /// `live` is a live room: it always plays at 1×.
    private func begin(_ channel: Channel, live: Bool) {
        historyContext = channel.historyContext
        lastHistoryPosition = nil
        requestedResumePosition = channel.resumePosition
        pendingResume = channel.resumePosition.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        restoringPosition = false; restoredPosition = nil; checkingPicture = false; soughtAhead = nil
        subtitleScope = Self.subtitleScope(for: channel)
        skipScope = channel.skipScope
        skipSettings = skipScope.map { EpisodeSkipSettings.load(scope: $0, defaults: skipDefaults) } ?? EpisodeSkipSettings()
        // A new title starts at the speed set in Settings › Playback, when one is set. Its next episodes and other
        // lines keep the speed picked in the player (#1015, #1076). Channels without a title (live playlists, a
        // pasted address) keep the speed as before; live rooms play at 1×.
        if live {
            player.defaultRate = 1
        } else if let scope = channel.skipScope, scope != speedScope, let start = PlaybackSpeed.chosen() {
            player.defaultRate = start
        }
        if channel.skipScope != nil { speedScope = channel.skipScope }
        if player.rate != 0, boost == nil, player.rate != player.defaultRate { player.rate = player.defaultRate }
        skipPass = EpisodeSkipPass(); seekingSegment = false
        skipNotice = nil; introNoticeUntil = nil
        sourceSkips = channel.skips; skipOffer = nil; skippedSource = []; chapters = []
        position = 0; duration = 0
        upcomingAttempted = false
    }

    private func restorePositionIfNeeded(_ item: AVPlayerItem) {
        guard let requested = pendingResume, !restoringPosition, !checkingPicture, item.status == .readyToPlay else { return }
        // A live stream (a sports line a source lists as an episode) has no duration, so there is no place to
        // return to. Waiting for one left "loading" on and the player paused for good (#683, #717): play it from its live edge.
        if item.duration.isIndefinite {
            pendingResume = nil; soughtAhead = nil; loading = false
            if !editingSkip { player.play() }
            return
        }
        guard let target = PlaybackHistoryEntry.resumeTarget(requested, duration: item.duration.seconds) else { return }
        let activeGeneration = generation
        // The item opened at the saved place (`seekAhead`) and is there: it plays from where it already loaded.
        let ahead = soughtAhead; soughtAhead = nil
        let landed = player.currentTime().seconds
        if let ahead, abs(ahead - target) < 0.5, landed.isFinite, landed >= target - 10.5, landed <= target + 0.5 {
            pendingResume = nil; loading = false
            restoredPosition = landed
            Diagnostics.shared.record(.info, "player", "history resume requested=\(requested) restored=\(landed) opened there")
            Task { await self.playRestored(item, generation: activeGeneration) }
            return
        }
        restoringPosition = true
        let pattern: Duration.TimeFormatStyle.Pattern = target >= 3600 ? .hourMinuteSecond : .minuteSecond
        note(L10n.text("Jumping to %@", Duration.seconds(Int(target)).formatted(.time(pattern: pattern))))
        // Up to 10 s early, at the keyframe before the saved place: the player shows it without first reading and
        // decoding the frames up to the exact second (half a second and more from a cloud drive).
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: CMTime(seconds: 10, preferredTimescale: 600),
                    toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.generation == activeGeneration else { return }
                self.restoringPosition = false; self.pendingResume = nil; self.loading = false
                guard finished else {
                    self.error = L10n.text("The player could not restore the saved position. Try again.")
                    return
                }
                self.restoredPosition = self.player.currentTime().seconds
                Diagnostics.shared.record(.info, "player", "history resume requested=\(requested) restored=\(self.restoredPosition ?? -1)")
                await self.playRestored(item, generation: activeGeneration)
            }
        }
    }

    /// A saved place is asked for as the item opens (#1455), so AVPlayer's first requests are for the video there.
    /// Seeking only once the item was ready had it load the start first, then throw that away and load the saved place:
    /// two waits where a fresh open has one. `restorePositionIfNeeded` checks it landed, and seeks again if not.
    private func seekAhead() {
        guard let target = pendingResume, target.isFinite, target > 0, !Self.oldResume else { return }
        soughtAhead = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: CMTime(seconds: 10, preferredTimescale: 600),
                    toleranceAfter: .zero)
    }

    /// Plays from the restored place. A drive bringing in several times what the video needs plays now, without
    /// AVPlayer's wait for a cushion first (1–1.5 s); anything else plays once a few seconds are in, as after a jump
    /// (`SeekResume`, #1213), rather than when AVPlayer predicts the whole download will keep up. Both still wait if
    /// the bytes fall behind later.
    private func playRestored(_ item: AVPlayerItem, generation activeGeneration: UUID) async {
        let quick = false
        guard generation == activeGeneration else { return }
        if !editingSkip {
            if quick { player.playImmediately(atRate: player.defaultRate) } else { player.play(); if !Self.oldResume { resumeAfterJump() } }
        }
        saveHistory()
    }

    /// `-qaOldResume 1`: resumes as before #1455 (open at the start, seek once ready, AVPlayer's own wait), to measure.
    private static var oldResume: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "qaOldResume")
        #else
        false
        #endif
    }
}

extension PlaybackSession {
    /// A catalog stream made ready for AVPlayer: a saved download, or on the Mac through the local HLS adapter,
    /// which stops with the episode.
    fileprivate struct Prepared {
        var url: URL
        #if os(macOS)
        var adapter: HLSProxy?
        /// The address `adapter` fetches.
        var adapterOrigin: URL?
        #endif
    }

    fileprivate func prepare(_ channel: Channel) async throws -> Prepared {
        var address = channel.url
        var prepared = Prepared(url: address)
        // A downloaded episode plays from disk: its file, or its HLS through a loopback server.
        if address.scheme == DownloadLibrary.scheme {
            note(L10n.text("Opening the cached video"))
            do {
                address = try await DownloadLibrary.shared.playbackAddress(for: address) { fraction in
                    Task { @MainActor [weak self] in
                        self?.note(L10n.text("Preparing the cached video for this device · %lld%%", Int(fraction * 100)), replacing: "rewrap")
                    }
                }
            }
            catch {
                if !Task.isCancelled { Diagnostics.shared.failure("player", "saved download", error) }
                throw error
            }
            prepared.url = address
        }
        #if os(macOS)
        if address.pathExtension.lowercased() == "m3u8", ["http", "https"].contains(address.scheme), channel.url.scheme != DownloadLibrary.scheme {
            let adapter = HLSProxy(headers: channel.headers)
            do { prepared.url = try await adapter.start(url: address); prepared.adapter = adapter; prepared.adapterOrigin = address }
            catch let failure as HLSProxy.Failure {
                // Not a playlist (an .m3u8 address that sends MPEG-TS, say): AVPlayer gets it as it is, as on iPhone.
                Diagnostics.shared.record(.info, "player", "hls proxy skipped host=\(channel.url.host() ?? "-") \(failure.localizedDescription)")
            }
            catch {
                if !Task.isCancelled { Diagnostics.shared.record(.error, "player", "proxy failed host=\(channel.url.host() ?? "-") \(Self.describe(error))") }
                throw error
            }
        }
        #else
        // A video whose playlist carries spliced-in ads opens through the loader that cuts them (#567); any other plays as it is.
        if prepared.url == address, address.pathExtension.lowercased() == "m3u8", ["http", "https"].contains(address.scheme),
           channel.url.scheme != DownloadLibrary.scheme,
           let routed = await AdSkip.route(address, headers: channel.headers) {
            prepared.url = routed
        }
        #endif
        return prepared
    }

    /// The local HLS adapter, or repackager, of a stream that won't play after all.
    fileprivate static func stopAdapter(_ prepared: Prepared) {
        #if os(macOS)
        if let adapter = prepared.adapter { Task { await adapter.stop() } }
        #endif
    }
}

extension PlaybackSession {
    /// Near the end of an episode, resolves the next one and queues it behind this one, where it loads
    /// while this one finishes; the queue then plays it straight on. When it can't be queued (no next
    /// episode, a plugin-proxied stream or an original that won't play, a failure), the episode ends and
    /// switches as before.
    fileprivate func queueUpcomingIfDue(_ item: AVPlayerItem) {
        if upcoming != nil, looping || !playsOn() { return discardUpcoming() }
        guard !upcomingAttempted, !looping, !isLive, playsOn(), let upcomingEpisode, item.status == .readyToPlay,
              pendingResume == nil, !restoringPosition else { return }
        let length = item.duration.seconds, time = item.currentTime().seconds
        guard length.isFinite, length > 0, time.isFinite else { return }
        let end = skipSettings.enabled && skipSettings.outroLength > 0 ? length - skipSettings.outroLength : length
        guard end - time <= Self.upcomingLead else { return }
        upcomingAttempted = true
        let activeGeneration = generation
        upcomingTask = Task { [weak self] in
            guard let next = await upcomingEpisode(), let self, self.generation == activeGeneration, !Task.isCancelled else { return }
            let prepared: Prepared
            do { prepared = try await self.prepare(next) }
            catch {
                Diagnostics.shared.record(.warning, "player", "upcoming not prepared \(Self.describe(error))")
                return
            }
            guard self.generation == activeGeneration, !Task.isCancelled, !self.looping, self.playsOn(),
                  self.player.currentItem === item else {
                return Self.release(next, prepared)
            }
            let queued = self.makeItem(next, url: prepared.url)
            guard self.player.canInsert(queued, after: item) else { return Self.release(next, prepared) }
            self.player.insert(queued, after: item)
            self.player.actionAtItemEnd = SleepTimer.shared.endsWithItem || self.sleepFadeRevision != nil ? .pause : .advance
            self.upcoming = Upcoming(channel: next, item: queued, prepared: prepared)
            Diagnostics.shared.record(.info, "player", "upcoming queued name=\(next.name) left=\(Int(length - item.currentTime().seconds))s")
            // The next episode starts past its intro when that is skipped, rather than jumping there once it plays.
            let intro = next.skipScope.map { EpisodeSkipSettings.load(scope: $0, defaults: self.skipDefaults) }
            self.upcomingObservation = queued.observe(\.status, options: [.initial, .new]) { [weak self] queued, _ in
                let status = queued.status, failure = queued.error
                Task { @MainActor [weak self] in
                    guard let self, self.upcoming?.item === queued else { return }
                    if status == .failed {
                        Diagnostics.shared.record(.warning, "player", "upcoming failed \(failure.map(Self.describe) ?? "-")")
                        self.discardUpcoming()
                    } else if status == .readyToPlay {
                        Task { [weak self] in
                            let tracks = await MediaTracks.subtitleGroup(queued)
                            guard let self, self.upcoming?.item === queued else { return }
                            _ = self.restoreSubtitleChoice(queued, tracks: tracks, scope: Self.subtitleScope(for: next))
                        }
                        if let intro, intro.enabled, intro.introEnd > 0,
                           intro.validationError(duration: queued.duration.seconds) == nil, queued.currentTime().seconds < intro.introEnd {
                            queued.seek(to: CMTime(seconds: intro.introEnd, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
                            self.upcomingSkippedIntro = true
                        }
                    }
                }
            }
        }
    }

    /// Takes the queued episode out again: auto-play went off, looping came on, or its stream failed.
    /// The episode then ends paused and switches the ordinary way.
    fileprivate func discardUpcoming() {
        upcomingTask?.cancel(); upcomingTask = nil
        upcomingObservation = nil; upcomingSkippedIntro = false
        player.actionAtItemEnd = .pause
        guard let upcoming else { return }
        self.upcoming = nil
        player.remove(upcoming.item)
        Self.release(upcoming.channel, upcoming.prepared)
    }

    /// Stops the streams a prepared episode opened.
    fileprivate static func release(_ channel: Channel, _ prepared: Prepared) {
        stopAdapter(prepared)
    }

    /// The Sleep Timer ran out: the sound fades away and the video pauses.
    private func sleepTimerFired() {
        guard sleepFadeRevision != SleepTimer.shared.revision else { return }
        sleepFadeRevision = SleepTimer.shared.revision
        player.actionAtItemEnd = .pause
        sleepFade.start(player) { [weak self] in self?.player.pause() }
    }

    private func cancelSleepFade() {
        sleepFade.cancel(); sleepFadeRevision = nil
        followSleepTimer()
    }

    /// With End of Episode set, the player pauses at the end instead of moving on to the queued episode.
    private func followSleepTimer() {
        if let revision = sleepFadeRevision, revision != SleepTimer.shared.revision {
            sleepFade.cancel(); sleepFadeRevision = nil
        }
        guard upcoming != nil else { return }
        player.actionAtItemEnd = SleepTimer.shared.endsWithItem || sleepFadeRevision != nil ? .pause : .advance
    }

    /// Plays the queued next episode now (the Next Episode button); false when none is queued yet.
    func playUpcoming() -> Bool {
        guard let upcoming, upcoming.item.status != .failed, player.currentItem === item else { return false }
        cancelSleepFade()
        skipsToUpcoming = true
        player.advanceToNextItem()
        player.play()
        return true
    }

    /// The queue moved on to the episode it held: that episode takes over the session, its item already
    /// playing, without the wait a new start would show.
    fileprivate func queueMoved() {
        guard let upcoming, player.currentItem === upcoming.item else { return }
        saveHistory(completed: !skipsToUpcoming, item: item)
        skipsToUpcoming = false
        let channel = upcoming.channel
        Diagnostics.shared.record(.info, "player", "advance name=\(channel.name) ready=\(upcoming.item.status == .readyToPlay)")
        // Let go of the finished episode's stream; the queued one's becomes the session's.
        stopRescue(); rescueAttempt = PlaybackRescue.Attempt()
        rescueAttempt.ready = upcoming.item.status == .readyToPlay
        if let proxy { Task { await proxy.stop() } }
        #if os(macOS)
        proxy = upcoming.prepared.adapter; proxyOrigin = upcoming.prepared.adapterOrigin
        #else
        proxy = nil
        #endif
        detachItem(); observation = nil
        upcomingObservation = nil; upcomingTask = nil; self.upcoming = nil
        player.actionAtItemEnd = .pause
        generation = UUID()
        let activeGeneration = generation
        transfer = Transfer(); steps = []
        sourceDanmaku = []
        error = nil; switchNotice = nil; quality = nil
        // A queued next episode is a point video, never live. It is a play of its own, counted here: it never opens.
        begin(channel, live: false)
        attempt = PlayAttempt(live: false, address: channel.url)
        if upcoming.item.status == .readyToPlay, player.timeControlStatus == .playing { countPlay(.started) }
        loading = upcoming.item.status != .readyToPlay
        playing = channel; automatic = upcoming.prepared.url
        externalSubtitles.begin(channel, playing: upcoming.prepared.url)
        player.allowsExternalPlayback = true
        qualities = []
        watch(upcoming.item, channel: channel, url: upcoming.prepared.url, generation: activeGeneration)
        if DanmakuSource.has(channel.url) {
            Task { [weak self] in
                guard let comments = await DanmakuSource.comments(for: channel.url), let self, self.generation == activeGeneration else { return }
                self.sourceDanmaku = comments
            }
        }
        if upcomingSkippedIntro { showIntroSkipped(from: 0) }
        upcomingSkippedIntro = false
        advanced = channel
        onAdvance?(channel)
    }
}

extension PlaybackSession {
    /// The player's wait, with download speed against what the video needs.
    var loadingProgress: LoadingProgress {
        let transfer = transfer
        // AVPlayer counts the first segment only once it finishes, so zero bytes means "not yet", not "stalled".
        let speed = transfer.received > 0 ? transfer.bytesPerSecond.map(Self.rate) : nil
        var progress = LoadingProgress(title: L10n.text(loading ? "Connecting…" : "Buffering…"))
        if loading || !showsPicture { progress.steps = steps }
        if let switchNotice {
            progress.reason = switchNotice
            return progress
        }
        if let speed {
            progress.detail = transfer.required.map { L10n.text("%@ · needs %@", speed, Self.rate($0)) }
                ?? L10n.text("Downloading at %@", speed)
        } else if let host = transfer.host {
            progress.detail = L10n.text("Waiting for %@", host)
        }
        let server = transfer.host ?? L10n.text("The video server")
        if let status = transfer.httpStatus {
            progress.reason = L10n.text("%@ returned an error (%@). The link may have expired: go back and play the episode again, or choose another line.", server, "HTTP \(status)")
        } else if let failure = transfer.failure {
            progress.reason = L10n.text("Couldn't load video from %@ (%@). Check the connection, or choose another line.", server, failure)
        } else if transfer.received == 0 {
            progress.reason = L10n.text("%@ hasn't delivered the first part of the video yet. The server may be slow or down; try another line.", server)
        } else if let bytes = transfer.bytesPerSecond, let required = transfer.required, bytes < required {
            progress.reason = L10n.text("%@ sends %@, but this video needs about %@. Try another line, or wait without skipping.", server, Self.rate(bytes), Self.rate(required))
        } else {
            progress.reason = L10n.text("The player is filling its buffer before playback continues.")
        }
        return progress
    }
    /// A server's name for the wait's small print; this device's own proxies stand for the source's server.
    static func server(_ host: String?) -> String {
        guard let host, !host.isEmpty, !["127.0.0.1", "localhost"].contains(host) else { return L10n.text("the video server") }
        return host
    }
    private static func rate(_ bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false // "0 KB", not "Zero KB"
        // Int64(_:) traps on infinity, NaN and anything past Int64.max.
        let bytes = bytesPerSecond.isFinite ? Int64(min(max(0, bytesPerSecond), 1e15)) : 0
        return L10n.text("%@/s", formatter.string(fromByteCount: bytes))
    }
}

extension PlaybackSession {
    /// Whether the server refused the link (HTTP 401, 403, 404 or 410), which for a catalog episode usually means it expired.
    /// AVFoundation reports these as URL or Core Media errors more often than as a status in the error log.
    nonisolated static func refusedLink(_ error: Error?, log: AVPlayerItemErrorLog?) -> Bool {
        if [401, 403, 404, 410].contains(log?.events.last?.errorStatusCode ?? 0) { return true }
        var current = error as NSError?
        while let error = current {
            if error.domain == NSURLErrorDomain,
               [NSURLErrorNoPermissionsToReadFile, NSURLErrorFileDoesNotExist, NSURLErrorUserAuthenticationRequired].contains(error.code) { return true }
            // Core Media's codes for HTTP 403 and 404.
            if error.domain == "CoreMediaErrorDomain", [-12660, -12938].contains(error.code) { return true }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// The server sent a different length than the byte range AVPlayer asked for (CoreMedia -12939,
    /// "byte range length mismatch"; an OSStatus on older systems).
    nonisolated static func ignoredRange(_ error: Error?) -> Bool {
        var current = error as NSError?
        while let error = current {
            if ["CoreMediaErrorDomain", NSOSStatusErrorDomain].contains(error.domain), error.code == -12939 { return true }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// AVPlayer can't decode what the stream carries: CoreMedia's 'fmt?' (1718449215), as for MP2 sound in MPEG-TS.
    nonisolated static func unsupportedFormat(_ error: Error?) -> Bool {
        var current = error as NSError?
        while let error = current {
            if error.domain == "CoreMediaErrorDomain", error.code == 1718449215 { return true }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// A failure to reach the server at all: offline, timed out, or the host could not be found.
    nonisolated static func networkFailure(_ error: Error?) -> Bool {
        var current = error as NSError?
        while let error = current {
            if error.domain == NSURLErrorDomain, [NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut, NSURLErrorCannotFindHost,
                                                   NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost].contains(error.code) { return true }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}

extension PlaybackSession {
    /// The waiting screen's words: the facts `loadingProgress` reports, said calmly. Past
    /// `PlaybackWait.detailsAfter` the small print joins them: how the download goes, and what the player did to get here.
    func wait(elapsed: TimeInterval, resume: Double?, linesHint: Bool) -> PlaybackWait {
        var wait = message(elapsed: elapsed, resume: resume, linesHint: linesHint)
        if elapsed >= PlaybackWait.detailsAfter {
            wait.detail = downloadLine
            if loading || !showsPicture { wait.steps = steps }
        }
        return wait
    }

    /// How the download goes: its speed (against what the video needs, once known) and how much has arrived;
    /// before the first bytes, the server it waits on.
    private var downloadLine: String? {
        guard transfer.received > 0 else { return transfer.host.map { L10n.text("Waiting for %@", Self.server($0)) } }
        let received = L10n.text("%@ received", ByteCountFormatter.string(fromByteCount: transfer.received, countStyle: .file))
        guard let bytes = transfer.bytesPerSecond else { return received }
        let speed = transfer.required.map { L10n.text("%@ · needs %@", Self.rate(bytes), Self.rate($0)) } ?? Self.rate(bytes)
        return speed + " · " + received
    }

    /// The one calm line, and a second one suggesting another line only once the wait has run long.
    private func message(elapsed: TimeInterval, resume: Double?, linesHint: Bool) -> PlaybackWait {
        if let switchNotice { return PlaybackWait(message: Self.preparing(resume), caption: switchNotice) }
        // A saved download waits only on this device (making its MP4, say): no server, line or connection to blame.
        if savedDownload { return PlaybackWait(message: loading ? Self.preparing(resume) : L10n.text("Buffering…")) }
        // AVFoundation retries a failed request by itself; give it a moment before saying so.
        if elapsed >= 4, transfer.httpStatus != nil || transfer.failure != nil {
            return PlaybackWait(message: L10n.text("This line isn't answering right now."), suggestsLines: linesHint)
        }
        if elapsed >= LoadingCard.patience {
            if transfer.received == 0 {
                return PlaybackWait(message: L10n.text("The server hasn't answered yet. Still trying…"), suggestsLines: linesHint)
            }
            if let bytes = transfer.bytesPerSecond, let required = transfer.required, bytes < required {
                return PlaybackWait(message: L10n.text("The connection is a little slow. Still loading…"), suggestsLines: linesHint)
            }
        }
        return PlaybackWait(message: loading ? Self.preparing(resume) : L10n.text("Buffering…"))
    }

    /// "Getting it ready", with the place playback picks up from when there is one.
    static func preparing(_ resume: Double?) -> String {
        guard let resume, resume.isFinite, resume >= 5 else { return L10n.text("Getting it ready") }
        let pattern: Duration.TimeFormatStyle.Pattern = resume >= 3600 ? .hourMinuteSecond : .minuteSecond
        return L10n.text("Getting it ready · from %@", Duration.seconds(Int(resume)).formatted(.time(pattern: pattern)))
    }
}

#if os(macOS)
/// Our own hold on the Mac's display while a video plays. AVPlayer's `preventsDisplaySleepDuringVideoPlayback`
/// leaves it to Core Media, which holds the display only while it counts the picture as on screen, so a Mac
/// could still dim, start the screen saver and lock mid-film (#565). IINA and VLC hold one of their own too.
final class DisplayAwake {
    private var assertion: IOPMAssertionID?

    func hold(_ on: Bool) {
        if on, assertion == nil {
            var id = IOPMAssertionID(0)
            let made = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                   IOPMAssertionLevel(kIOPMAssertionLevelOn), "HAo Movie is playing a video" as CFString, &id)
            if made == kIOReturnSuccess { assertion = id }
        } else if !on, let id = assertion {
            IOPMAssertionRelease(id)
            assertion = nil
        }
    }

    deinit { if let assertion { IOPMAssertionRelease(assertion) } }
}
#endif

