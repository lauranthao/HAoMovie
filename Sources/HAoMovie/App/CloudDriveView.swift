import SwiftUI

/// Cloud drive sign-ins on iPhone, iPad and Apple TV. Apple TV has no browser: it shows a code to
/// scan with the drive's phone app. iPhone and iPad can't scan their own screen, so they open the
/// drive's own sign-in page, with the code for another phone as the alternative. Plugins read the
/// saved sign-in on their next request.
struct CloudDriveView: View {
    @Environment(Store.self) private var store
    @State private var accounts = CloudDriveAccounts()
    @State private var login: CloudProvider?
    @State private var error: String?
    var body: some View {
        SettingsPage(title: L10n.text("Cloud Drive Accounts"), symbol: "externaldrive") {
            SettingsGroup(footer: footer) {
                ForEach(CloudProvider.shown(store)) { provider in
                    let signedIn = provider.isSignedIn(accounts)
                    SettingsRow(symbol: provider.symbol, tint: provider.tint, title: provider.name,
                                subtitle: L10n.text(signedIn ? "Signed In" : "Not Signed In")) {
                        if signedIn {
                            Button(L10n.text("Sign Out")) { signOut(provider) }.settingsButton()
                        } else {
                            Button(L10n.text("Sign In")) { login = provider }.settingsButton(prominent: true)
                        }
                    }
                }
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Brand.rose) }
        }
        .task { reload() }
        #if os(iOS)
        .sheet(item: $login) { provider in
            if provider == .xunlei { XunleiSignInView(signedIn: reload) }
            else if [.pan115, .tianyi, .pan123, .guangya].contains(provider) {
                // 115, Tianyi Cloud, 123pan and Guangya have no sign-in page here, only the code to scan with their app on another phone.
                NavigationStack {
                    CloudQRLoginView(drive: provider.qrDrive) { reload() }
                        .navigationTitle(L10n.text("Sign In to %@", provider.name))
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Cancel")) { login = nil } } }
                }
            } else {
                WebSignInView(service: provider.webSignIn, signedIn: reload) {
                    CloudQRLoginView(drive: provider.qrDrive) { reload() }
                }
            }
        }
        #else
        .fullScreenCover(item: $login) { provider in
            if provider == .xunlei { XunleiSignInView(signedIn: reload) }
            else { CloudQRLoginView(drive: provider.qrDrive) { reload() } }
        }
        #endif
    }
    private var footer: String {
        #if os(iOS)
        store.extrasUnlocked ? L10n.text("Sign in on the drive's own page, or scan a code with the drive's app on another phone. Yingxia keeps the sign-in on this device and supplies it to the plugins you run.")
            : L10n.text("Sign in on the drive's own page, or scan a code with the drive's app on another phone. Yingxia keeps the sign-in on this device.")
        #else
        store.extrasUnlocked ? L10n.text("Sign in by scanning a code with the drive's phone app. Yingxia keeps the sign-in on this device and supplies it to the plugins you run.")
            : L10n.text("Sign in by scanning a code with the drive's phone app. Yingxia keeps the sign-in on this device.")
        #endif
    }
    private func reload() {
        do { accounts = try CloudDriveAccounts.load(); error = nil } catch { self.error = error.localizedDescription }
    }
    private func signOut(_ provider: CloudProvider) {
        var updated = accounts
        provider.clear(&updated)
        // The plugin keeps its own copy of a Baidu or Aliyun sign-in; it goes too.
        EmbeddedJarHost.forgetPluginSignIns(provider.pluginFiles)
        do { try updated.save(); accounts = updated; error = nil } catch { self.error = error.localizedDescription }
    }
}

enum CloudProvider: String, Identifiable, CaseIterable {
    case quark, uc, pan115, tianyi, pan123, guangya, baidu, aliyun, xunlei
    var id: String { rawValue }
    var name: String {
        switch self {
        case .quark: L10n.text("Quark")
        case .uc: "UC"
        case .pan115: L10n.text("115 Cloud")
        case .tianyi: L10n.text("Tianyi Cloud")
        case .pan123: L10n.text("123pan")
        case .guangya: L10n.text("Guangya Cloud")
        case .baidu: L10n.text("Baidu Netdisk")
        case .aliyun: L10n.text("Aliyun Drive")
        case .xunlei: L10n.text("Xunlei")
        }
    }
    var symbol: String {
        switch self {
        case .quark: "icloud.fill"
        case .uc: "externaldrive.fill"
        case .pan115: "archivebox.fill"
        case .tianyi: "cloud.sun.fill"
        case .pan123: "123.rectangle.fill"
        case .guangya: "sun.max.fill"
        case .baidu: "cloud.fill"
        case .aliyun: "shippingbox.fill"
        case .xunlei: "bolt.fill"
        }
    }
    var tint: Color {
        switch self {
        case .quark: .blue
        case .uc: .orange
        case .pan115: .mint
        case .tianyi: .red
        case .pan123: .green
        case .guangya: .yellow
        case .baidu: .indigo
        case .aliyun: .purple
        case .xunlei: .cyan
        }
    }
    /// Aliyun and Xunlei only serve plugins, so an App Store build lists them once a subscription is added;
    /// Quark, UC, 115, Baidu Netdisk, Tianyi Cloud, 123pan and Guangya are browsed in Cloud Files too.
    @MainActor static func shown(_ store: Store) -> [CloudProvider] { store.extrasUnlocked ? allCases : [.quark, .uc, .pan115, .baidu, .tianyi, .pan123, .guangya] }

    /// Quark and UC sign in on their web page on a Mac; Xunlei with a texted code; every other sign-in is a code to scan.
    var signsInOnWeb: Bool { self == .quark || self == .uc }
    var domain: String { self == .quark ? "quark.cn" : "uc.cn" }
    var qrDrive: CloudDriveQRLogin.Drive { CloudDriveQRLogin.Drive(rawValue: rawValue)! }
    var webSignIn: WebSignIn { WebSignIn(rawValue: rawValue)! }
    var url: URL { URL(string: self == .quark ? "https://pan.quark.cn/" : "https://drive.uc.cn/")! }
    /// Where FTY plugins keep their own copy of the sign-in.
    var pluginFiles: [String] {
        switch self {
        case .baidu: ["mybd_cookie"]
        case .aliyun: ["ali_user", "ali_oauth", "ali_info"]
        case .quark, .uc, .pan115, .tianyi, .pan123, .guangya, .xunlei: []
        }
    }
    func isSignedIn(_ accounts: CloudDriveAccounts) -> Bool {
        let value: String
        switch self {
        case .quark: value = accounts.quarkCookie
        case .uc: value = accounts.ucCookie
        case .baidu: value = accounts.baiduCookie ?? ""
        case .pan115: value = accounts.pan115Cookie ?? ""
        case .tianyi: value = accounts.tianyiToken ?? ""
        case .pan123: value = accounts.pan123Token ?? ""
        case .guangya: value = accounts.guangya?.refreshToken ?? ""
        case .aliyun: value = accounts.token
        case .xunlei: value = accounts.xunlei?.refreshToken ?? ""
        }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    func set(_ cookie: String, in accounts: inout CloudDriveAccounts) {
        switch self {
        case .quark:
            if accounts.quarkCookie != cookie { accounts.quarkServiceTicket = nil }
            accounts.quarkCookie = cookie
        case .uc: accounts.ucCookie = cookie
        case .baidu: accounts.baiduCookie = cookie.isEmpty ? nil : cookie
        case .pan115: accounts.pan115Cookie = cookie.isEmpty ? nil : cookie
        case .tianyi: accounts.tianyiToken = cookie.isEmpty ? nil : cookie
        case .pan123: accounts.pan123Token = cookie.isEmpty ? nil : cookie
        case .aliyun: accounts.token = cookie
        // Guangya's is made only by its code, and Xunlei's only by XunleiSignInView; this only clears them.
        case .guangya: if cookie.isEmpty { accounts.guangya = nil }
        case .xunlei: if cookie.isEmpty { accounts.xunlei = nil }
        }
    }
    func clear(_ accounts: inout CloudDriveAccounts) {
        set("", in: &accounts)
        if self == .uc { accounts.ucToken = "" }
    }
    /// "Signed In · Quark" style summary for the Settings row.
    static func summary() -> String {
        let accounts = (try? CloudDriveAccounts.load()) ?? CloudDriveAccounts()
        let names = allCases.filter { $0.isSignedIn(accounts) }.map(\.name)
        return names.isEmpty ? L10n.text("Not Signed In") : L10n.text("Signed In") + " · " + names.joined(separator: ", ")
    }
}
