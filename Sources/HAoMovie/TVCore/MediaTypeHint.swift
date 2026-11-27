import Foundation

/// The MIME type a container's extension implies, for telling AVPlayer what a
/// link is when its name or server says nothing. Also remembers a type a
/// rescue learned for an address, so a second try doesn't ask again.
public enum MediaTypeHint {
    /// `learned` is read and written from player work on several threads, so
    /// it goes through a lock — a plain static var is shared mutable state
    /// and Swift 6 refuses to compile it (Movie build #8). The lock does the
    /// real protection; `nonisolated(unsafe)` is only what the compiler
    /// itself suggests for lock-guarded static state (build #9 still
    /// rejected the bare var, lock or no lock).
    private static let lock = NSLock()
    private nonisolated(unsafe) static var learned: [String: String] = [:]

    public static func mimeType(for url: URL) -> String? {
        lock.lock()
        let known = learned[url.absoluteString]
        lock.unlock()
        if let known { return known }
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
        lock.lock()
        learned[url.absoluteString] = type
        lock.unlock()
    }
}
