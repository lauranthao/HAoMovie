// Restored from Yingxia (jo32/tvbox-silicon, GPL-3.0) — shared helpers the kept
// files still use. Adapted for HAo Movie where noted (no TMDB, no JavaScript
// runtime, no libass/TVMedia); see the notes on each type.

import Foundation

/// A subtitle source written as a script. HAo Movie ships no JavaScript runtime
/// (DexRuntime/QuickJS), so script subtitle sources cannot load: `load` always
/// throws, and sources fall back to their built-in providers.
public final class SubtitleScriptProvider: SubtitleProvider, @unchecked Sendable {
    public var manifest: SubtitleProviderManifest

    public init(manifest: SubtitleProviderManifest) { self.manifest = manifest }

    public static func load(script: String, label: String) async throws -> SubtitleScriptProvider {
        throw TVError.unsupported(L10n.text("Script subtitle sources need a JavaScript runtime, which this app doesn't include."))
    }

    public func search(_ hint: SubtitleHint, credentials: [String: String], within seconds: Double) async throws -> [SubtitleCandidate] {
        throw TVError.unsupported(L10n.text("Script subtitle sources need a JavaScript runtime, which this app doesn't include."))
    }

    public func resolve(_ candidate: SubtitleCandidate, credentials: [String: String], within seconds: Double) async throws -> SubtitleResource {
        throw TVError.unsupported(L10n.text("Script subtitle sources need a JavaScript runtime, which this app doesn't include."))
    }
}
