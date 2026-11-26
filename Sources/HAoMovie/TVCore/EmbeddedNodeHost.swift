#if os(iOS) || os(tvOS)
import Foundation

/// HAo Movie ships no embedded Node runtime, so CatPawOpen bundles cannot run here.
/// This stub keeps the host's API (used by `CatPawOpen` and `Models`) while always
/// reporting the runtime as unavailable; CatPaw sources fall back to their
/// non-Node path or report unsupported, as `request` throws below.
public actor EmbeddedNodeHost {
    public static let shared = EmbeddedNodeHost()
    /// No Node runtime is bundled with HAo Movie.
    public static let available: Bool = false

    public func request(site: Site, bundleURL: URL, params: [String: String], http: HTTPClient, origin: URL) async throws -> [String: JSONValue] {
        throw TVError.unsupported(L10n.text("This device can't run CatPawOpen sources."))
    }

    public func relocate(_ url: URL) async -> URL? { nil }

    public func restart(behind url: URL, olderThan age: TimeInterval) async -> Bool { false }
}
#endif
