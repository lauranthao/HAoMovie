// Restored from Yingxia (jo32/tvbox-silicon, GPL-3.0) — the Site extension from
// CloudSources.swift, which the kept files still use (HiddenSources, Store,
// SitesView, LoopbackPlaylist, Models). Adapted for HAo Movie where noted:
// no CloudFilesSource (isCloudFiles reads CloudFiles.sourceKey instead), and
// builtInExtension does not claim ByteVC2 (HAo Movie ships no repackager).

import Foundation

/// Accounts a service's sources may act as. The app signs in; the source gets the cookie in its ext.
public enum SourceAccounts {
    public static func cookie(_ account: String?) -> String {
        switch account {
        case "bilibili": BilibiliAccount.load().cookie
        case "douyin": DouyinAccount.load().cookie
        default: account.map { SourceAccount.load($0).cookie } ?? ""
        }
    }
    public static func signedIn(_ account: String?) -> Bool {
        switch account {
        case "bilibili": BilibiliAccount.load().signedIn
        case "douyin": DouyinAccount.load().signedIn
        default: account.map { SourceAccount.load($0).signedIn } ?? false
        }
    }
}

extension Site {
    /// What Yingxia's own subscription says about one of its sources (`yingxia` in the site entry).
    var yingxia: [String: JSONValue] { raw["yingxia"]?.object ?? [:] }
    /// A source the app provides itself: Yingxia's own (from its subscription) or a drive in Cloud Files.
    /// It never falls back to a subscription's JAR.
    public var isBuiltIn: Bool { isCloudFiles || isTelegram || yingxia["builtin"].map { if case .bool(true) = $0 { true } else { false } } == true }
    /// A drive in Cloud Files. HAo Movie has no CloudFilesSource: its Cloud Files
    /// source is keyed exactly `CloudFiles.sourceKey` ("builtin.files").
    public var isCloudFiles: Bool { key == CloudFiles.sourceKey || key.hasPrefix(CloudFiles.sourceKey + ".") }
    public var isBilibili: Bool { key == Bilibili.siteKey }
    /// The service account whose sign-in the source uses ("bilibili"), if any.
    public var account: String? { yingxia["account"]?.string }
    /// An SF Symbol for the source's icon, if its entry names one.
    public var symbol: String? { yingxia["symbol"]?.string }

    /// Yingxia's own sources run on the in-process runtime on every platform, even the Mac's.
    var runsInProcess: Bool { isBuiltIn && !isCloudFiles && runtime == .javascript }

    /// A built-in source's ext: its entry's own (an object) plus the app's language and the
    /// account's cookie. Yingxia also lists the pictures the app plays beyond what AVPlayer
    /// decodes (`decodes`: ByteVC2, which its repackager converts); HAo Movie ships no
    /// repackager, so it does not claim ByteVC2 — a source must not offer episodes this
    /// build cannot play.
    var builtInExtension: JSONValue {
        if isCloudFiles { return .object([:]) }
        var fields = raw["ext"]?.object ?? [:]
        fields["lang"] = .string(L10n.resolvedLanguage())
        if account != nil { fields["cookie"] = .string(SourceAccounts.cookie(account)) }
        return .object(fields)
    }

    /// The entry's name in `language`, when the entry gives names (`yingxia.names`).
    static func localizedName(_ entry: [String: JSONValue], language: String = L10n.resolvedLanguage()) -> String? {
        entry["yingxia"]?.object?["names"]?.object?[language]?.string ?? entry["names"]?.object?[language]?.string
    }
}
