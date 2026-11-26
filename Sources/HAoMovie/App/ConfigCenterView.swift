// Restored from Yingxia (jo32/tvbox-silicon, GPL-3.0) — shared helpers the kept
// files still use. Adapted for HAo Movie where noted (no TMDB, no JavaScript
// runtime, no libass/TVMedia); see the notes on each type.

import SwiftUI
import WebKit

struct ConfigCenterView: View {
    let address: () async -> URL?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    @State private var page: URL?
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(Brand.amber)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                }
                ConfigCenterBrowser(webView: webView, error: $error, loading: $loading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .top) { if loading { ProgressView().padding(12) } }
            }
            .navigationTitle(L10n.text("Config Center"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await open(reload: true) } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel(L10n.text("Refresh"))
                }
            }
        }
        .task { await open(reload: true) }
        // Back from another app (copying a password, say): the page moves to the bundle's new port, if it has one.
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await open(reload: false) } } }
    }

    private func open(reload: Bool) async {
        guard let fresh = await address() else {
            loading = false
            error = L10n.text("The plugin returned no content. Try another source.")
            return
        }
        guard let page, var current = webView.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }),
              current.host == fresh.host() else {
            page = fresh
            webView.load(URLRequest(url: fresh))
            return
        }
        // A page the address redirected to (Wex's, #360) is served elsewhere: Refresh starts from the address again.
        guard current.port == page.port else {
            self.page = fresh
            if reload { webView.load(URLRequest(url: fresh)) }
            return
        }
        // Where the viewer is in the page, on the port the bundle answers on now.
        let moved = page.port != fresh.port
        current.port = fresh.port
        self.page = fresh
        if moved, let url = current.url { webView.load(URLRequest(url: url)) } else if reload { webView.reload() }
    }
}

private struct ConfigCenterBrowser: UIViewRepresentable {
    let webView: WKWebView
    @Binding var error: String?
    @Binding var loading: Bool

    func makeCoordinator() -> Coordinator { Coordinator(error: $error, loading: $loading) }
    func makeUIView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        return webView
    }
    func updateUIView(_ view: WKWebView, context: Context) {}

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        @Binding var error: String?
        @Binding var loading: Bool
        init(error: Binding<String?>, loading: Binding<Bool>) { _error = error; _loading = loading }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loading = true; error = nil }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError failure: Error) { failed(failure) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError failure: Error) { failed(failure) }
        private func failed(_ failure: Error) {
            loading = false
            let code = (failure as NSError).code, domain = (failure as NSError).domain
            if (domain == NSURLErrorDomain && code == NSURLErrorCancelled) || (domain == "WebKitErrorDomain" && code == 102) { return }
            error = failure.localizedDescription
        }

        /// Wex's config center redirects to the plugin's proxy at this device's network address, where nothing listens:
        /// the proxy only answers on loopback (#360).
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if navigationAction.targetFrame?.isMainFrame != false, let url = navigationAction.request.url,
               let local = ConfigCenter.local(url), local != url {
                decisionHandler(.cancel)
                webView.load(URLRequest(url: local))
                return
            }
            decisionHandler(.allow)
        }

        /// Links that open a new window open here.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }
        // A web view shows no alert, confirm or prompt of its own; config pages ask with them ("确定删除？").
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
            present(message, on: webView, actions: [(L10n.text("OK"), .default, completionHandler)], cancel: completionHandler)
        }
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
            present(message, on: webView, actions: [(L10n.text("Cancel"), .cancel, { completionHandler(false) }),
                                                    (L10n.text("OK"), .default, { completionHandler(true) })],
                    cancel: { completionHandler(false) })
        }
        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
            let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: L10n.text("Cancel"), style: .cancel) { _ in completionHandler(nil) })
            alert.addAction(UIAlertAction(title: L10n.text("OK"), style: .default) { _ in completionHandler(alert.textFields?.first?.text ?? "") })
            guard let host = Self.presenter(for: webView) else { return completionHandler(nil) }
            host.present(alert, animated: true)
        }

        private func present(_ message: String, on webView: WKWebView,
                             actions: [(String, UIAlertAction.Style, @MainActor () -> Void)], cancel: @MainActor () -> Void) {
            guard let host = Self.presenter(for: webView) else { return cancel() }
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            for (title, style, action) in actions { alert.addAction(UIAlertAction(title: title, style: style) { _ in action() }) }
            host.present(alert, animated: true)
        }

        /// The sheet's controller: the frontmost one above the web view's window.
        private static func presenter(for webView: WKWebView) -> UIViewController? {
            var controller = webView.window?.rootViewController
            while let next = controller?.presentedViewController, !next.isBeingDismissed { controller = next }
            return controller
        }
    }
}
