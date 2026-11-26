import AVKit
import MediaPlayer
import SwiftUI

/// 视频播放页：AVPlayerLayer + HAo 自己的控制层。
/// 手势：点按显/隐控制、双击左右 ±10 秒、左侧上下滑调亮度、右侧上下滑调音量
/// （亮度/音量只在播放器里调，不碰系统设置以外的状态）。
/// 横屏：随手机旋转（Info.plist 已声明横屏方向）；退出不自动恢复其他播放。
struct VideoPlayerView: View {
    @EnvironmentObject private var player: VideoPlayerService
    @EnvironmentObject private var history: HistoryStore
    @Environment(\.dismiss) private var dismiss

    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var failureMessage: String?
    @State private var showEpisodes = false
    @State private var showSpeedMenu = false
    @State private var dragStartBrightness: CGFloat = 0
    @State private var dragStartVolume: Float = 0
    @State private var gestureHint: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerLayerView(player: player.player)
                .ignoresSafeArea()
            HiddenVolumeView()
                .frame(width: 0, height: 0)

            if showControls {
                controlsOverlay
            }

            if let failureMessage {
                VStack {
                    Spacer()
                    HStack {
                        Text(failureMessage)
                            .font(.system(size: 13))
                        Spacer()
                        Button("重试") { retryCurrent() }
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .padding(HaoMovieDesign.space12)
                    .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: HaoMovieDesign.chipRadius))
                    .foregroundStyle(.white)
                    .padding(.horizontal, HaoMovieDesign.space16)
                    .padding(.bottom, 90)
                }
            }

            if let gestureHint {
                Text(gestureHint)
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, HaoMovieDesign.space16)
                    .padding(.vertical, HaoMovieDesign.space8)
                    .background(Color.black.opacity(0.7), in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .gesture(doubleTapGesture.exclusively(before: singleTapGesture))
        .gesture(dragGesture)
        .onAppear(perform: wireCallbacks)
        .onDisappear {
            hideTask?.cancel()
            player.pause()
            LocalStore.save(player.settings, key: "hao_movie_settings")
        }
        .sheet(isPresented: $showEpisodes) {
            episodeSheet
        }
        .sheet(isPresented: $showSpeedMenu) {
            speedSheet
        }
    }

    // MARK: - 控制层

    private var controlsOverlay: some View {
        VStack {
            topBar
            Spacer()
            centerPlayButton
            Spacer()
            bottomControls
        }
        .foregroundStyle(.white)
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            Text(player.currentDetail?.item.vodName ?? player.currentLiveChannel?.name ?? "")
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(1)
            Spacer()
            if AVPictureInPictureController.isPictureInPictureSupported() {
                Button { PlayerLayerView.togglePiP() } label: {
                    Image(systemName: "pip.enter")
                        .frame(width: 44, height: 44)
                }
            }
        }
        .padding(.horizontal, HaoMovieDesign.space8)
        .background(
            LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
        )
    }

    private var centerPlayButton: some View {
        Button { player.togglePlay() } label: {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 44))
                .frame(width: 88, height: 88)
                .background(Color.black.opacity(0.45), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private var bottomControls: some View {
        VStack(spacing: HaoMovieDesign.space8) {
            // 进度条
            HStack(spacing: HaoMovieDesign.space8) {
                Text(formatTime(player.position))
                Slider(value: Binding(
                    get: { player.position },
                    set: { player.seek(to: $0) }
                ), in: 0...(player.duration > 0 ? player.duration : 1))
                .tint(HaoMovieDesign.accent)
                Text(formatTime(player.duration))
            }
            .font(.system(size: 12, design: .monospaced))
            HStack(spacing: HaoMovieDesign.space20) {
                if player.currentDetail != nil {
                    Button { player.previousEpisode() } label: {
                        Image(systemName: "backward.end.fill")
                    }
                    .disabled(!player.hasPreviousEpisode)
                    Button { player.togglePlay() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 26))
                    }
                    Button { player.nextEpisode() } label: {
                        Image(systemName: "forward.end.fill")
                    }
                    .disabled(!player.hasNextEpisode)
                } else {
                    Button { player.togglePlay() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 26))
                    }
                }
                Spacer()
                if player.currentDetail != nil {
                    if player.settings.skipIntroSeconds > 0 {
                        Button("跳过片头") { player.seekBy(player.settings.skipIntroSeconds) }
                            .font(.system(size: 13, weight: .semibold))
                    }
                    Button("\(speedLabel)") { showSpeedMenu = true }
                        .font(.system(size: 13, weight: .semibold))
                    Button("选集") { showEpisodes = true }
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .padding(.horizontal, HaoMovieDesign.space4)
        }
        .padding(.horizontal, HaoMovieDesign.space16)
        .padding(.bottom, HaoMovieDesign.space16)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
        )
    }

    private var speedLabel: String {
        let v = player.speed
        return v.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(v))x" : "\(v)x"
    }

    // MARK: - 选集 / 倍速 sheet

    private var episodeSheet: some View {
        NavigationStack {
            Group {
                if let detail = player.currentDetail {
                    List {
                        if detail.playLines.count > 1 {
                            Section("线路") {
                                Picker("线路", selection: Binding(
                                    get: { player.lineIndex },
                                    set: { player.playLine($0) }
                                )) {
                                    ForEach(detail.playLines.indices, id: \.self) { index in
                                        Text(detail.playLines[index].name).tag(index)
                                    }
                                }
                                .pickerStyle(.segmented)
                            }
                        }
                        Section("选集") {
                            if let line = player.currentLine {
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: HaoMovieDesign.space8) {
                                    ForEach(line.episodes.indices, id: \.self) { index in
                                        Button(line.episodes[index].title) {
                                            player.playEpisode(index)
                                        }
                                        .font(.system(size: 13, weight: .semibold))
                                        .padding(.vertical, HaoMovieDesign.space8)
                                        .frame(maxWidth: .infinity)
                                        .background(
                                            player.episodeIndex == index ? HaoMovieDesign.accent : HaoMovieDesign.surface,
                                            in: RoundedRectangle(cornerRadius: HaoMovieDesign.chipRadius)
                                        )
                                        .foregroundStyle(player.episodeIndex == index ? .white : HaoMovieDesign.textPrimary)
                                        .lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("选集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showEpisodes = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var speedSheet: some View {
        NavigationStack {
            List([0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0], id: \.self) { value in
                Button {
                    player.setSpeed(value)
                    showSpeedMenu = false
                } label: {
                    HStack {
                        Text(value.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(value))x" : "\(value)x")
                        Spacer()
                        if player.speed == value {
                            Image(systemName: "checkmark")
                                .foregroundStyle(HaoMovieDesign.accent)
                        }
                    }
                }
            }
            .navigationTitle("倍速")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showSpeedMenu = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - 手势

    /// 单击：显/隐控制层。
    private var singleTapGesture: SpatialTapGesture {
        SpatialTapGesture(count: 1).onEnded { _ in
            showControls.toggle()
            if showControls { scheduleHide() }
        }
    }

    /// 双击：左半屏后退 10 秒，右半屏前进 10 秒。
    /// 与单击用 exclusively 组合，双击优先，单击只在双击失败时触发。
    private var doubleTapGesture: SpatialTapGesture {
        SpatialTapGesture(count: 2).onEnded { value in
            let isLeft = value.location.x < UIScreen.main.bounds.width / 2
            player.seekBy(isLeft ? -10 : 10)
            showHint(isLeft ? "后退 10 秒" : "快进 10 秒")
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                if dragStartBrightness == 0 {
                    dragStartBrightness = UIScreen.main.brightness
                    dragStartVolume = VolumeHelper.currentVolume
                }
                let delta = -value.translation.height / 300
                if value.startLocation.x < UIScreen.main.bounds.width / 2 {
                    let next = min(1, max(0.05, dragStartBrightness + CGFloat(delta)))
                    UIScreen.main.brightness = next
                    showHint("亮度 \(Int(next * 100))%")
                } else {
                    let next = min(1, max(0, dragStartVolume + Float(delta)))
                    VolumeHelper.setVolume(next)
                    showHint("音量 \(Int(next * 100))%")
                }
            }
            .onEnded { _ in
                dragStartBrightness = 0
                hideHintSoon()
            }
    }

    // MARK: - 接线

    private func wireCallbacks() {
        player.onProgress = { [weak history] position, duration in
            guard let history else { return }
            Task { @MainActor in
                guard let detail = player.currentDetail, let site = player.currentSite,
                      let episode = player.currentEpisode else { return }
                history.recordProgress(
                    vodId: detail.item.vodId, siteKey: site.key, siteName: site.name,
                    vodName: detail.item.vodName, poster: detail.item.vodPic,
                    episodeTitle: episode.title, episodeIndex: player.episodeIndex,
                    lineIndex: player.lineIndex, position: position, duration: duration
                )
            }
        }
        player.onFailure = { message in
            failureMessage = message
        }
        scheduleHide()
    }

    private func retryCurrent() {
        failureMessage = nil
        if let detail = player.currentDetail, let site = player.currentSite {
            player.play(detail: detail, site: site, lineIndex: player.lineIndex, episodeIndex: player.episodeIndex, resumePosition: player.position)
        } else if let channel = player.currentLiveChannel {
            player.playLive(channel)
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled {
                await MainActor.run { showControls = false }
            }
        }
    }

    private func showHint(_ text: String) {
        gestureHint = text
        showControls = false
    }

    private func hideHintSoon() {
        Task {
            try? await Task.sleep(for: .seconds(1))
            await MainActor.run { gestureHint = nil }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let minutes = total / 60
        let secs = total % 60
        if minutes >= 60 {
            return String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

/// AVPlayerLayer 的 UIViewRepresentable；同时承载画中画控制器。
struct PlayerLayerView: UIViewRepresentable {
    var player: AVPlayer

    private static var pipController: AVPictureInPictureController?

    static func togglePiP() {
        pipController?.stopPictureInPicture()
        if pipController?.isPictureInPictureActive == false {
            pipController?.startPictureInPicture()
        }
    }

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        if AVPictureInPictureController.isPictureInPictureSupported() {
            let source = AVPictureInPictureController.ContentSource(playerLayer: view.playerLayer)
            Self.pipController = AVPictureInPictureController(contentSource: source)
        }
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        uiView.playerLayer.player = player
    }

    final class PlayerContainerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// 系统音量：MPVolumeView 必须挂在视图层级里才生效，
/// 用一个隐藏的 MPVolumeView 承载 slider，再调它的值（iOS 没有公开的设置接口）。
enum VolumeHelper {
    static var slider: UISlider?

    static var currentVolume: Float {
        AVAudioSession.sharedInstance().outputVolume
    }

    static func setVolume(_ value: Float) {
        slider?.setValue(value, animated: false)
    }
}

/// 隐藏的 MPVolumeView（0 尺寸、不透明度 0），只为拿到系统音量 slider。
struct HiddenVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsVolumeSlider = true
        view.alpha = 0.01
        // 下一 runloop 再取 slider（子视图此时才建好）
        DispatchQueue.main.async {
            VolumeHelper.slider = view.subviews.compactMap { $0 as? UISlider }.first
        }
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
