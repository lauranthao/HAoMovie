import AVFoundation
import Combine
import Foundation

/// AVPlayer 播放器：点播（选集 + 线路）与直播（单地址）共用。
/// 播放规则照映匣的来：断点续播、自动连播下一集、播放失败不丢历史
/// （失败时不回写进度，旧进度保留）、0.5x–4x 倍速。
@MainActor
final class VideoPlayerService: ObservableObject {
    @Published private(set) var state: PlaybackState = .idle
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var speed: Double = 1.0 {
        didSet { applySpeed() }
    }

    /// 当前点播影片（直播时为 nil）
    @Published private(set) var currentDetail: VodDetail?
    @Published private(set) var currentSite: TVBoxSite?
    @Published private(set) var lineIndex = 0
    @Published private(set) var episodeIndex = 0
    /// 当前直播频道（点播时为 nil）
    @Published private(set) var currentLiveChannel: LiveChannel?

    let player = AVPlayer()
    /// 播放进度回调（由 App 接到 HistoryStore；失败时不调用）
    var onProgress: ((Double, Double) -> Void)?
    /// 播放失败回调（用于提示，不回写进度）
    var onFailure: ((String) -> Void)?

    /// 播放偏好（设置页直接改这份，改完即存本机）。
    @Published var settings: MovieSettings

    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var pendingResumePosition: Double = 0
    private var hasResumed = false

    var currentLine: VodPlayLine? {
        guard let detail = currentDetail, lineIndex < detail.playLines.count else { return nil }
        return detail.playLines[lineIndex]
    }

    var currentEpisode: VodEpisode? {
        guard let line = currentLine, episodeIndex < line.episodes.count else { return nil }
        return line.episodes[episodeIndex]
    }

    var hasNextEpisode: Bool {
        guard let line = currentLine else { return false }
        return episodeIndex + 1 < line.episodes.count
    }

    var hasPreviousEpisode: Bool { episodeIndex > 0 }

    init(settings: MovieSettings = MovieSettings()) {
        self.settings = settings
        self.speed = settings.rememberSpeed ? settings.defaultSpeed : 1.0
        addTimeObserver()
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.didReachEnd() }
        }
        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "播放失败"
                self?.didFail(message)
            }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        statusObserver?.invalidate()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
    }

    // MARK: - 点播

    func play(detail: VodDetail, site: TVBoxSite, lineIndex: Int = 0, episodeIndex: Int = 0, resumePosition: Double = 0) {
        currentDetail = detail
        currentSite = site
        currentLiveChannel = nil
        self.lineIndex = min(lineIndex, max(0, detail.playLines.count - 1))
        self.episodeIndex = episodeIndex
        pendingResumePosition = resumePosition
        hasResumed = false
        loadCurrentEpisode()
    }

    func playEpisode(_ index: Int) {
        guard let line = currentLine, index >= 0, index < line.episodes.count else { return }
        episodeIndex = index
        pendingResumePosition = 0
        hasResumed = false
        loadCurrentEpisode()
    }

    func playLine(_ index: Int) {
        guard let detail = currentDetail, index >= 0, index < detail.playLines.count else { return }
        lineIndex = index
        // 换线路后尽量保持同一集序号
        episodeIndex = min(episodeIndex, max(0, detail.playLines[index].episodes.count - 1))
        pendingResumePosition = 0
        hasResumed = false
        loadCurrentEpisode()
    }

    func nextEpisode() {
        guard hasNextEpisode else { return }
        playEpisode(episodeIndex + 1)
    }

    func previousEpisode() {
        guard hasPreviousEpisode else { return }
        playEpisode(episodeIndex - 1)
    }

    // MARK: - 直播

    func playLive(_ channel: LiveChannel) {
        currentDetail = nil
        currentSite = nil
        currentLiveChannel = channel
        pendingResumePosition = 0
        hasResumed = true
        state = .loading
        guard let url = URL(string: channel.url) else {
            didFail("直播地址无效")
            return
        }
        replaceItem(url: url)
    }

    // MARK: - 控制

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        player.play()
        player.rate = Float(speed)
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
        reportProgress()
    }

    func seek(to seconds: Double) {
        guard duration > 0 else { return }
        let clamped = min(max(0, seconds), duration)
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        position = clamped
    }

    func seekBy(_ delta: Double) {
        seek(to: position + delta)
    }

    func setSpeed(_ value: Double) {
        speed = min(4, max(0.5, value))
        if settings.rememberSpeed { settings.defaultSpeed = speed }
    }

    func stop() {
        pause()
        player.replaceCurrentItem(with: nil)
        state = .idle
        currentDetail = nil
        currentLiveChannel = nil
        position = 0
        duration = 0
    }

    // MARK: - 内部

    private func loadCurrentEpisode() {
        guard let episode = currentEpisode, let url = URL(string: episode.url) else {
            didFail("没有可播放的地址")
            return
        }
        state = .loading
        replaceItem(url: url)
    }

    private func replaceItem(url: URL) {
        let item = AVPlayerItem(url: url)
        statusObserver?.invalidate()
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.state = .ready
                    self.duration = item.duration.seconds.isFinite ? item.duration.seconds : 0
                    if !self.hasResumed, self.pendingResumePosition > 10, self.duration > 0,
                       self.pendingResumePosition < self.duration * 0.95 {
                        self.player.seek(to: CMTime(seconds: self.pendingResumePosition, preferredTimescale: 600))
                        self.position = self.pendingResumePosition
                    }
                    self.hasResumed = true
                    self.play()
                case .failed:
                    self.didFail(item.error?.localizedDescription ?? "播放失败")
                default:
                    break
                }
            }
        }
        player.replaceCurrentItem(with: item)
    }

    private func applySpeed() {
        if isPlaying { player.rate = Float(speed) }
    }

    private func didReachEnd() {
        reportProgress()
        if currentDetail != nil, settings.autoNextEpisode, hasNextEpisode {
            nextEpisode()
        } else {
            isPlaying = false
        }
    }

    /// 播放失败：只报状态与回调，绝不回写进度（旧进度保留）。
    private func didFail(_ message: String) {
        state = .failed(message)
        isPlaying = false
        onFailure?(message)
    }

    private func addTimeObserver() {
        let interval = CMTime(seconds: 1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                self.position = time.seconds.isFinite ? time.seconds : 0
                if let duration = self.player.currentItem?.duration.seconds, duration.isFinite {
                    self.duration = duration
                }
                self.reportProgress()
            }
        }
    }

    private func reportProgress() {
        guard state == .ready, duration > 0 else { return }
        onProgress?(position, duration)
    }
}
