// Restored from Yingxia (jo32/tvbox-silicon, GPL-3.0) — shared helpers the kept
// files still use. Adapted for HAo Movie where noted (no TMDB, no JavaScript
// runtime, no libass/TVMedia); see the notes on each type.

import Foundation

enum ScriptAssets {
    static let root: URL? = nil  // HAo Movie bundles no script assets.
    static let cache: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.tvbox.yingxia/Scripts", isDirectory: true)
    static let profiles: URL = cache.appendingPathComponent("Profiles", isDirectory: true)

    // Widely shared drpy2 builds import their helper libraries from a qu.ax mirror that no longer
    // serves them. They are drpy's standard bundled libraries, so load the bundled copies instead.
    static let retiredLibraries = ["cLFE.js": "jsencrypt.js", "kOUW.js": "node-rsa.js", "ucoN.js": "pako.min.js", "XUKQ.js": "模板.js", "wYCz.js": "gbk.js"]

    /// Module resolution as Runtime/ScriptHost/host.mjs `moduleURL`.
    static func resolve(_ specifier: String, from base: String) -> String? {
        if specifier.hasPrefix("lib/") { return "assets://js/" + specifier }
        if specifier.hasPrefix("assets://") || specifier.hasPrefix("http://") || specifier.hasPrefix("https://") { return retired(specifier) ?? specifier }
        guard let parent = URL(string: base), let resolved = URL(string: specifier, relativeTo: parent)?.absoluteString
                ?? specifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed).flatMap({ URL(string: $0, relativeTo: parent)?.absoluteString }) else { return nil }
        return retired(resolved) ?? resolved
    }
    private static func retired(_ address: String) -> String? {
        guard let range = address.range(of: #"/qu\.ax/(\w+\.js)$"#, options: .regularExpression) else { return nil }
        let name = String(address[range].dropFirst("/qu.ax/".count))
        return retiredLibraries[name].map { "assets://js/lib/" + $0 }
    }
    static func bundled(_ address: String) -> String? {
        guard let root, address.hasPrefix("assets://") else { return nil }
        let relative = String(address.dropFirst("assets://".count)).removingPercentEncoding ?? ""
        let file = root.appendingPathComponent(relative).standardizedFileURL
        guard file.path.hasPrefix(root.standardizedFileURL.path + "/") else { return nil }
        return try? String(contentsOf: file, encoding: .utf8)
    }
}
