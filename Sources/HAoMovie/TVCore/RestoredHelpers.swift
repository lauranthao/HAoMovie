// Restored from Yingxia (jo32/tvbox-silicon, GPL-3.0) — shared helpers the kept
// files still use. Adapted for HAo Movie where noted (no TMDB, no JavaScript
// runtime, no libass/TVMedia); see the notes on each type.

import Foundation

public struct PlaybackSkip: Hashable, Sendable {
    public enum Kind: String, Sendable { case intro, outro }
    public let start: Double, end: Double
    public let kind: Kind
    public init(start: Double, end: Double, kind: Kind) { self.start = start; self.end = end; self.kind = kind }

    /// `[{"start", "end", "type": "intro"|"outro"}]`, in seconds; anything else is left out.
    static func parse(_ value: JSONValue?) -> [PlaybackSkip] {
        (value?.array ?? []).compactMap(\.object).compactMap { item in
            guard let start = item["start"]?.double, let end = item["end"]?.double, start >= 0, end > start,
                  let kind = item["type"]?.string.flatMap(Kind.init) else { return nil }
            return PlaybackSkip(start: start, end: end, kind: kind)
        }
    }

    /// The stretch playing at `time` that a viewer could skip now: not in its last second.
    public static func current(_ skips: [PlaybackSkip], at time: Double) -> PlaybackSkip? {
        skips.first { time >= $0.start && time < $0.end - 1 }
    }
}

public enum ImportedFiles {
    static let host = "files.haomovie.invalid"
    static var directory: URL {
        #if os(tvOS)
        URL.cachesDirectory.appending(path: "ImportedFiles", directoryHint: .isDirectory)
        #else
        URL.applicationSupportDirectory.appending(path: "ImportedFiles", directoryHint: .isDirectory)
        #endif
    }

    /// Copies a picked file in, replacing an earlier copy of the same name, and returns its address.
    public static func add(_ file: URL) throws -> URL {
        let name = file.lastPathComponent.replacingOccurrences(of: "/", with: "_").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !name.isEmpty else { throw TVError.invalidURL }
        let data = try read(file)
        guard data.count <= 20_000_000 else { throw TVError.unsupported(L10n.text("The playlist exceeds 20 MB. Use a smaller subscription.")) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appending(path: name), options: .atomic)
        return address(name)
    }

    /// Reads a picked or opened file through a file coordinator, which first downloads an iCloud Drive file
    /// that is only a placeholder on this device; a plain read fails on those.
    public static func read(_ file: URL) throws -> Data {
        var coordination: NSError?
        var result: Result<Data, Error> = .failure(TVError.invalidURL)
        NSFileCoordinator().coordinate(readingItemAt: file, options: .withoutChanges, error: &coordination) { url in
            result = Result { try Data(contentsOf: url) }
        }
        if let coordination { throw coordination }
        return try result.get()
    }

    /// Deletes the copy behind an address on the reserved host; any other address is left alone.
    public static func remove(_ address: String) {
        guard let url = URL(string: address), let file = file(for: url) else { return }
        try? FileManager.default.removeItem(at: file)
    }

    public static func isImported(_ address: String) -> Bool { URL(string: address)?.host()?.lowercased() == host }

    static func address(_ name: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"; components.host = host; components.path = "/" + name
        return components.url!
    }

    /// The copy behind an address on the reserved host: one file, straight in the folder.
    static func file(for url: URL) -> URL? {
        guard url.host()?.lowercased() == host else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 1, let name = parts.first, !name.hasPrefix(".") else { return directory.appending(path: ".missing") }
        return directory.appending(path: name)
    }

    /// What an address on the reserved host holds; nil for every other address, which loads as usual.
    static func data(at url: URL) throws -> Data? {
        guard let file = file(for: url) else { return nil }
        guard let data = try? Data(contentsOf: file) else {
            // A config added as a file can name files beside it (`./py/x.py`), and only the config itself was added.
            // That isn't a file from another device, so it says what is missing instead.
            guard url.pathComponents.filter({ $0 != "/" }).count > 1 else { throw TVError.unsupported(missingMessage) }
            throw TVError.unsupported(L10n.text("This source needs %@, a file next to its config. Only the config file itself was added, so add the config by its web address instead.", "." + url.path(percentEncoded: false)))
        }
        return data
    }

    /// What a file's address says when its copy isn't here. The subscription list follows the viewer to their other
    /// devices through iCloud, and a file's copy only when it is small (`syncedTexts`, #1235), so this is nearly always a
    /// large file, or one still on its way, added on another device (#842).
    public static var missingMessage: String {
        L10n.text("This file hasn't reached this device. A small file added on another device syncs through iCloud; for a large one, use a web address instead.")
    }

    /// An address on the reserved host whose copy isn't on this device.
    public static func isMissing(_ address: String) -> Bool {
        guard let url = URL(string: address), let file = file(for: url) else { return false }
        return !FileManager.default.fileExists(atPath: file.path)
    }
}

/// The script host's error: a plain message. (From Yingxia's ScriptRuntime; the
/// runtime itself is not in HAo Movie, but ScriptCrypto throws this type.)
struct ScriptHostError: Error { let message: String; init(_ message: String) { self.message = message } }

public enum PluginFailure {
    public static func message(_ envelope: [String: JSONValue], language: String? = nil) -> String? {
        guard let detail = envelope["error"]?.string else { return nil }
        if let login = CloudDriveLoginRequired(envelope: envelope) { return login.message(language: language) }
        let missing = envelope["missingClass"]?.string
        switch envelope["errorCode"]?.string {
        case "source_http":
            if let host = envelope["host"]?.string, let status = envelope["status"]?.int {
                return L10n.text("The source %@ returned HTTP %lld.", host, status, language: language)
            }
        case "source_network":
            if let host = envelope["host"]?.string { return L10n.text("The source %@ could not be reached. Retry later.", host, language: language) }
        case "source_empty": return L10n.text("The plugin returned no content. Try another source.", language: language)
        case "embedded_request": return L10n.text("The plugin runtime could not complete this request. Try again or use another source.", language: language)
        case "source_timeout": return L10n.text("The source took too long to respond, so Yingxia stopped waiting. Try another line, or try again later.", language: language)
        case "unsupported_native_library": return L10n.text("This plugin is not supported: ftyguard_v8.so is missing.", language: language)
        case "unsupported_android":
            if let missing { return L10n.text("This source needs an Android feature that isn't supported yet: %@.", missing, language: language) }
            return L10n.text("This source requires Android features that the plugin runtime does not support yet.", language: language)
        case "android_screen":
            return L10n.text("This entry opens the source's own settings or sign-in screen (such as a QR code), which Yingxia can't show. Sign in under Settings → Cloud Drive Accounts instead.", language: language)
        case "class_conversion":
            if let broken = envelope["brokenClass"]?.string {
                return L10n.text("This plugin couldn't be prepared on this device (%@ could not be converted).", broken, language: language)
            }
            return L10n.text("This plugin couldn't be prepared on this device (missing %@).", missing ?? detail, language: language)
        case "plugin_message":
            // The plugin's own words, such as a drive it has no sign-in for (#408).
            if let text = envelope["message"]?.string { return L10n.text("The source says: %@", text, language: language) }
        case "plugin_crash":
            return L10n.text("The source's plugin crashed. The site may have changed; try another source.", language: language)
        default: break
        }
        // The spider class is not in the JAR the subscription points at: a subscription error, not a site error.
        if let name = PluginClassMissing.className(in: detail) {
            return L10n.text("This subscription's plugin package doesn't include %@. Ask the subscription's maintainer or use another source.", name, language: language)
        }
        return L10n.text("Plugin error: %@", detail, language: language)
    }

    /// The plugin itself failed (crash, conversion, Android gap), as opposed to the site or network.
    static func inPlugin(_ envelope: [String: JSONValue]) -> Bool {
        switch envelope["errorCode"]?.string {
        case "plugin_crash", "unsupported_android", "android_screen", "class_conversion", nil: return envelope["error"] != nil
        default: return false
        }
    }

    /// The first line names the failure, so reports group by it; `archive` is the plugin's SHA-256.
    public static func diagnostic(source: String, _ envelope: [String: JSONValue], archive: String? = nil) -> String {
        let error = envelope["error"]?.string ?? ""
        let summary = error.prefix { $0 != "\n" }
        var line = "source=\(source) code=\(envelope["errorCode"]?.string ?? "unclassified") \(summary)"
        if let missing = envelope["missingClass"]?.string { line += " missingClass=\(missing)" }
        if let broken = envelope["brokenClass"]?.string { line += " brokenClass=\(broken)" }
        let trace = envelope["trace"]?.string ?? ""
        // The trace repeats the rest of a multi-line error (a VerifyError's bytecode details).
        if trace.isEmpty, summary.endIndex < error.endIndex { line += error[summary.endIndex...] }
        // Which runtime and which archive: a stale host or a changed plugin explains many failures.
        let build = [envelope["host"]?.string.map { "host=\($0)" }, archive.map { "archive=\($0.prefix(12))" }].compactMap { $0 }
        if !build.isEmpty { line += "\n" + build.joined(separator: " ") }
        if !trace.isEmpty { line += "\n" + trace }
        return line
    }
}
