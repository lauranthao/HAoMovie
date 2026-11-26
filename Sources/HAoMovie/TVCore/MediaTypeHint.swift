import Foundation

/// The MIME type a container's extension implies, for telling AVPlayer what a
/// link is when its name or server says nothing. Also remembers a type a
/// rescue learned for an address, so a second try doesn't ask again.
public enum MediaTypeHint {
    private static var learned: [String: String] = [:]

    public static func mimeType(for url: URL) -> String? {
        if let known = learned[url.absoluteString] { return known }
        switch url.pathExtension.lowercased() {
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "mpd": return "application/dash+xml"
        case "mp4", "m4v": return "video/mp4"
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        case "mov": return "video/quicktime"
        case "avi": return "video/x-msvideo"
        case "flv": return "video/x-flv"
        case "ts", "m2ts": return "video/mp2t"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "flac": return "audio/flac"
        case "wav": return "audio/wav"
        case "aac": return "audio/aac"
        case "ogg", "oga": return "audio/ogg"
        default: return nil
        }
    }

    public static func set(_ type: String, for url: URL) {
        learned[url.absoluteString] = type
    }
}
