import Foundation

/// One of a video's chapters (Bilibili's 分段章节), for the player's Chapters
/// menu and Apple TV's chapter markers. Taken from Yingxia's BilibiliAPI,
/// where it lives beside the player-info call that fills it in.
public struct PlaybackChapter: Hashable, Sendable {
    public let start: Double, end: Double
    public let title: String
    /// A frame from it, when the source has one (Bilibili's `imgUrl`): Apple TV's Chapters tab shows it.
    public let image: URL?
    public init(start: Double, end: Double, title: String, image: URL? = nil) {
        self.start = start; self.end = end; self.title = title; self.image = image
    }
}
