import SwiftUI

/// 入口：无启动动画，直接进主界面（chen 2026-11-26 决定：三个应用都不要启动动画）。
/// 基于映匣（jo32/tvbox-silicon，GPL-3.0）的入口结构改写：音乐/漫画/小说/云盘/插件/TMDB/账号
/// 等模块已从本工程移除，这里只保留视频核心的启动路径。
@main
struct HAoMovieApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = Store()
    @State private var updates = Updates()
    /// A link that asks to add a subscription, waiting for the viewer to agree (#167).
    @State private var subscriptionRequest: SubscriptionImportLink?
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    init() {
        #if os(iOS)
        DownloadsLifecycle.install()
        #endif
        SubtitleTranslationSetup.install()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // Opening another profile starts every page again, so none of the last profile's stays on screen (#1456).
                .id(store.profile.id)
                .modifier(ThemeTint())
                .task { Diagnostics.shared.record(.info, "app", "Application scene opened") }
                .task { await store.restoreSubscription() }
                #if os(iOS)
                // Links carry the app's one scheme (`haomovie://import?url=…`); only the action's host tells them apart.
                .onOpenURL { url in
                    if let link = SubscriptionImportLink(url) { subscriptionRequest = link }
                }
                .sheet(item: $subscriptionRequest) { SubscriptionImportView(link: $0) }
                #endif
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        PlaybackHistoryLifecycle.enterBackground(history: store.playbackHistory)
                        Task { _ = await Diagnostics.shared.snapshot() }
                    }
                }
                .environment(store)
                .environment(updates)
        }
    }
}

#if os(iOS)
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// The player's rotate button narrows this to landscape (see PlayerOrientation).
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { PlayerOrientation.mask }
    }
}
#endif

/// What a `haomovie://import?url=` link opens: the subscription it names, and the viewer's agreement. A page
/// can point at a subscription, but nothing is downloaded before Add (#167).
struct SubscriptionImportView: View {
    let link: SubscriptionImportLink
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var failure: String?
    /// What the import added, shown before the sheet closes: a directory's subscriptions arrive switched off.
    @State private var added: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 40)).foregroundStyle(Brand.accent)
                    .frame(maxWidth: .infinity)
                Text(L10n.text("Add This Subscription?"))
                    .font(.title3.weight(.bold)).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 10) {
                    field(L10n.text("Subscription URL"), link.address.absoluteString)
                    if let name = link.name { field(L10n.text("Name"), name) }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentPanel(cornerRadius: 16)
                // Gone once the result shows, which the half-height sheet then has room for.
                if added == nil {
                    Text(L10n.text("A page can only ask: HAo Movie adds this subscription after you agree, never on its own."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(Brand.amber)
                }
                if let added {
                    Label(added, systemImage: "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(.green)
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background { Backdrop() }
            .navigationTitle(L10n.text("Subscription"))
            .toolbar {
                if added == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.text("Cancel")) { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if added != nil { Button(L10n.text("Done")) { dismiss() }.fontWeight(.semibold) }
                    // Settings may be importing already, and the store takes one import at a time.
                    else if adding || store.importing { ProgressView() }
                    else { Button(L10n.text("Add"), action: add).fontWeight(.semibold) }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    private func field(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.callout).lineLimit(3).truncationMode(.middle).textSelection(.enabled)
        }
    }

    private func add() {
        adding = true; failure = nil
        Task {
            await store.importSubscription(address: link.address.absoluteString, name: link.name)
            adding = false
            // Settings shows these too; here they say what did or did not arrive.
            if let error = store.importError { failure = error } else { added = store.notice ?? L10n.text("Done") }
        }
    }
}
