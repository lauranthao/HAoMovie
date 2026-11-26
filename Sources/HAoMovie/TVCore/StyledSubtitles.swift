// Restored from Yingxia (jo32/tvbox-silicon, GPL-3.0) — shared helpers the kept
// files still use. Adapted for HAo Movie where noted (no TMDB, no JavaScript
// runtime, no libass/TVMedia); see the notes on each type.

import CoreGraphics
import Foundation

public struct StyledSubtitleFrame: @unchecked Sendable, Equatable {
    public let image: CGImage?
    /// Pixels of the frame the image covers.
    public let rect: CGRect
    /// The frame it was drawn for, in pixels.
    public let size: CGSize

    /// PGS pictures are authored in square pixels, including the space around both lines of a bilingual cue.
    public let fitsCanvas: Bool

    public init(image: CGImage?, rect: CGRect, size: CGSize, fitsCanvas: Bool = false) {
        self.image = image; self.rect = rect; self.size = size; self.fitsCanvas = fitsCanvas
    }

    /// The layer for the whole subtitle canvas. Keep the entire PGS canvas inside the visible video, even in zoom.
    public func canvasRect(in picture: CGRect, visible: CGRect) -> CGRect {
        guard fitsCanvas, size.width > 0, size.height > 0 else { return picture }
        let area = picture.intersection(visible)
        guard !area.isEmpty else { return .zero }
        let scale = min(area.width / size.width, area.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
    }
    public static func == (lhs: StyledSubtitleFrame, rhs: StyledSubtitleFrame) -> Bool {
        lhs.image === rhs.image && lhs.rect == rhs.rect && lhs.size == rhs.size && lhs.fitsCanvas == rhs.fitsCanvas
    }
}

/// Subtitles the app draws as pictures rather than lines of text: ASS/SSA through libass, and bitmap subtitles.
public protocol StyledSubtitleSource: AnyObject, Sendable {
    /// What shows at `time` (microseconds of the subtitle's clock) on a frame `size` pixels big that shows a picture
    /// `video` pixels big. Nil when it is the same as what the last call returned, so nothing needs drawing again.
    func render(at time: Int64, size: CGSize, video: CGSize) -> StyledSubtitleFrame?
}

/// A font a Matroska file carries for its subtitles.
public struct StyledSubtitleFont: Sendable, Equatable {
    public let name: String
    public let data: Data
    public init(name: String, data: Data) { self.name = name; self.data = data }

    /// Whether an attachment (its codec, file name and MIME type) is a font.
    static func isFont(codec: String, name: String, mime: String) -> Bool {
        if ["ttf", "otf"].contains(codec) { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        if ["ttf", "otf", "ttc", "otc"].contains(ext) { return true }
        let mime = mime.lowercased()
        return mime.hasPrefix("font/") || mime.contains("truetype") || mime.contains("opentype") || mime.contains("font-sfnt")
    }
}

/// A Matroska file's ASS/SSA track as the repackager reads it: its header, the file's fonts, and its events, which
/// arrive segment by segment ahead of the picture (`RemuxSession`). Times are microseconds of the player item's clock.
public final class StyledSubtitleEvents: @unchecked Sendable {
    public struct Event: Sendable, Equatable {
        /// The Matroska event: ReadOrder, Layer, Style, Name, MarginL, MarginR, MarginV, Effect, Text.
        public let data: Data
        public let start: Int64, end: Int64
    }
    /// The track's name in the master playlist, which AVPlayer's subtitle option shows as its `displayName`.
    public let name: String
    /// Its place among the stream's subtitle renditions, in the master playlist's order.
    public let position: Int
    public let header: Data
    public let fonts: [StyledSubtitleFont]
    /// Kept events stop growing past this many bytes (a film's are a few hundred KB; karaoke-heavy ones a few MB).
    static let budget = 24 << 20
    private let lock = NSLock()
    private var events: [Event] = []
    private var seen: Set<Int> = []
    private var bytes = 0

    public init(name: String, position: Int = 0, header: Data, fonts: [StyledSubtitleFont]) {
        self.name = name; self.position = position; self.header = header; self.fonts = fonts
    }

    /// An event, unless the same ReadOrder came already (a segment made again after a seek repeats its events).
    func add(_ data: Data, start: Int64, end: Int64) {
        let order = Self.readOrder(data)
        lock.withLock {
            guard bytes + data.count <= Self.budget else { return }
            if let order { guard seen.insert(order).inserted else { return } }
            events.append(Event(data: data, start: start, end: end))
            bytes += data.count
        }
    }

    public var count: Int { lock.withLock { events.count } }

    /// The events after the first `index`.
    public func events(from index: Int) -> [Event] {
        lock.withLock { index < events.count ? Array(events[index...]) : [] }
    }

    static func readOrder(_ data: Data) -> Int? {
        guard let comma = data.firstIndex(of: UInt8(ascii: ",")) else { return nil }
        return Int(String(decoding: data[data.startIndex..<comma], as: UTF8.self).trimmingCharacters(in: .whitespaces))
    }
}

/// ASS/SSA drawn by libass (FreeType, HarfBuzz, FriBidi; the system's fonts through CoreText and a file's own): its
/// fonts, positions, outlines, shadows, rotations, drawings and karaoke. Safe to use from any thread; draws one
/// frame at a time.

/// ASS/SSA drawn by libass. HAo Movie ships no libass (TVMedia), so styled subtitles
/// render as plain lines: `isAvailable` is false and both initialisers fail, which is
/// the fallback the callers already implement.
public final class ASSRenderer: StyledSubtitleSource, @unchecked Sendable {
    /// libass is not bundled with HAo Movie; ASS shows as plain lines.
    public static let isAvailable: Bool = false

    public init?(script: String, fonts: [StyledSubtitleFont] = []) { return nil }

    public init?(track: StyledSubtitleEvents) { return nil }

    public var eventCount: Int { 0 }

    public func render(at time: Int64, size: CGSize, video: CGSize) -> StyledSubtitleFrame? { nil }
}

extension SubtitleDocument {
    /// An ASS/SSA file's whole text, for libass; nil for other formats.
    public var styledScript: String? {
        guard format.isStyled else { return nil }
        return SubtitleFile.text(data, encoding: encoding)
    }
}

