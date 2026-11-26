import SwiftUI

/// 设置：播放偏好、直播列表地址、缓存清理、关于。全部只存本机，无账号。
struct SettingsView: View {
    @EnvironmentObject private var player: VideoPlayerService
    @EnvironmentObject private var history: HistoryStore
    @Environment(\.dismiss) private var dismiss

    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                Section("播放") {
                    Picker("默认倍速", selection: Binding(
                        get: { player.settings.defaultSpeed },
                        set: { player.settings.defaultSpeed = $0; saveSettings() }
                    )) {
                        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0], id: \.self) { value in
                            Text(value.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(value))x" : "\(value)x").tag(value)
                        }
                    }
                    Toggle("记住上次倍速", isOn: Binding(
                        get: { player.settings.rememberSpeed },
                        set: { player.settings.rememberSpeed = $0; saveSettings() }
                    ))
                    Toggle("自动连播下一集", isOn: Binding(
                        get: { player.settings.autoNextEpisode },
                        set: { player.settings.autoNextEpisode = $0; saveSettings() }
                    ))
                    Stepper("片头跳过 \(Int(player.settings.skipIntroSeconds)) 秒", value: Binding(
                        get: { player.settings.skipIntroSeconds },
                        set: { player.settings.skipIntroSeconds = $0; saveSettings() }
                    ), in: 0...300, step: 5)
                    Stepper("片尾跳过 \(Int(player.settings.skipOutroSeconds)) 秒", value: Binding(
                        get: { player.settings.skipOutroSeconds },
                        set: { player.settings.skipOutroSeconds = $0; saveSettings() }
                    ), in: 0...300, step: 5)
                }

                Section("直播") {
                    TextField("M3U 列表地址", text: Binding(
                        get: { player.settings.m3uURL },
                        set: { player.settings.m3uURL = $0; saveSettings() }
                    ))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    Text("填入 M3U / M3U8 播放列表地址后，“直播”页即可按分组浏览频道。")
                        .font(.system(size: 12))
                        .foregroundStyle(HaoMovieDesign.textSecondary)
                }

                Section("数据") {
                    Button("清除播放历史", role: .destructive) {
                        history.clearHistory()
                    }
                    Button("清除全部本地数据", role: .destructive) {
                        showClearConfirm = true
                    }
                    .alert("清除全部本地数据？", isPresented: $showClearConfirm) {
                        Button("清除", role: .destructive) {
                            history.clearHistory()
                            LocalStore.remove(key: "hao_movie_subscriptions")
                            LocalStore.remove(key: "hao_movie_sites")
                        }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("订阅、历史与收藏都会删掉，此操作不可恢复。")
                    }
                }

                Section("关于") {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("0.1.0 (1)")
                            .foregroundStyle(HaoMovieDesign.textSecondary)
                    }
                    Text("HAo Movie 参照映匣（GPL-3.0）的功能与交互自研，代码全部重写；不内置任何片源与账号，订阅、历史、收藏只存本机。")
                        .font(.system(size: 12))
                        .foregroundStyle(HaoMovieDesign.textSecondary)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func saveSettings() {
        LocalStore.save(player.settings, key: "hao_movie_settings")
    }
}
