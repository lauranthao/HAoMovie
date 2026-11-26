import Foundation

/// 播放器状态。
enum PlaybackState: Equatable {
    case idle
    case loading
    case ready
    case failed(String)
}
