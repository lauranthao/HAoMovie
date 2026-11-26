// Restored from Yingxia (jo32/tvbox-silicon, GPL-3.0) — the SourceAccount store only.
// SourceSignIn is intentionally NOT restored: its QR flow runs the source's script
// through ScriptRuntime and reads CloudSources.current, and HAo Movie ships
// neither (no JavaScript runtime, no bundled Yingxia subscription). The account
// rows that need it are tvOS-gated in SettingsView and never compile on iOS.

import Foundation

/// A sign-in to the service behind one of the recommended sources, for a source whose entry says it takes one
/// (`yingxia.account` names it, `yingxia.signIn` says how). The app knows no service: the source's own script
/// gives the code to scan and reads the answers (its `account` function), and the app shows the code and keeps
/// what comes back on this device, to hand to that source alone (`SourceAccounts`).
public struct SourceAccount: Codable, Equatable, Sendable {
    /// The service's cookies for the signed-in session, as the script returned them.
    public var cookie = ""
    public var name = ""
    public init(cookie: String = "", name: String = "") { self.cookie = cookie; self.name = name }
    public var signedIn: Bool { !cookie.isEmpty }

    /// `id` names the folder, so only plain names are accounts.
    static func valid(_ id: String) -> Bool { !id.isEmpty && id.count <= 40 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }

    static func fileURL(_ id: String) -> URL {
        #if os(tvOS)
        // tvOS only permits Caches; `load` restores a purged copy from user defaults.
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
        // One folder per account, named after it with a capital, as versions up to 1.8.17 already kept theirs.
        return base.appendingPathComponent("com.tvbox.yingxia/\(id.prefix(1).uppercased() + id.dropFirst())/account.json")
    }
    private static func defaultsKey(_ id: String) -> String { id + "Account" }

    public static func load(_ id: String) -> Self {
        guard valid(id) else { return Self() }
        if let data = try? Data(contentsOf: fileURL(id)), let account = try? JSONDecoder().decode(Self.self, from: data) { return account }
        #if os(tvOS)
        if let data = UserDefaults.standard.data(forKey: defaultsKey(id)), let account = try? JSONDecoder().decode(Self.self, from: data) {
            try? account.save(id)
            return account
        }
        #endif
        return Self()
    }

    public func save(_ id: String) throws {
        guard Self.valid(id) else { throw TVError.invalidConfiguration }
        let file = Self.fileURL(id), folder = file.deletingLastPathComponent()
        let data = try JSONEncoder().encode(self)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #if os(tvOS)
        UserDefaults.standard.set(data, forKey: Self.defaultsKey(id))
        #endif
    }

    public static func signOut(_ id: String) {
        guard valid(id) else { return }
        try? FileManager.default.removeItem(at: fileURL(id))
        UserDefaults.standard.removeObject(forKey: defaultsKey(id))
    }
}
