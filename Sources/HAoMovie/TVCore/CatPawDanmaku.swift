import Foundation

// CatPawDanmaku.swift (HAoMovie: only the request extension was restored —
// the CatPaw danmaku enum itself is not used by this build).
// From Yingxia's TVCore/CatPawDanmaku.swift.

extension CatalogClient {
    /// A call to the source's CatPawOpen bundle beside its spider routes: sign-ins, its comments' address.
    func catPawRequest(_ params: [String: String]) async throws -> [String: JSONValue] {
        #if os(macOS)
        return try await LocalJarHost.shared.request(site: site, jarURL: site.scriptURL(origin: origin), params: params, http: http, scriptOrigin: origin)
        #elseif os(iOS) || os(tvOS)
        return try await EmbeddedNodeHost.shared.request(site: site, bundleURL: site.scriptURL(origin: origin), params: params, http: http, origin: origin)
        #else
        throw TVError.unsupported(L10n.text("This device can't run CatPawOpen sources."))
        #endif
    }
}
