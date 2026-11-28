// Ported from Yingxia (jo32/tvbox-silicon, GPL-3.0) — App/NovelSourcesView.swift.
// `import TVCore` removed (single-target app). Adapted for HAo Movie:
// - The sign-in UI is NOT ported: `NovelSignInView`, the web sign-in sheet and
//   browser, and the "Sign In" sections in `NovelListView` are all dropped.
//   No login entry is added anywhere in the novels UI.
import SwiftUI

/// Settings › Book Sources: the subscribed Legado lists, and how many of their sources are on.
struct NovelSourcesView: View {
    @State private var store = NovelStore.shared
    @State private var refreshing = false
    @State private var adding: Set<URL> = []
    @State private var offerErrors: [URL: String] = [:]

    private let about = L10n.text("Book sources are Legado (阅读) sources. Add a list as a subscription in Settings › Subscriptions. Each source reads a website; the website's content is its own.")

    var body: some View {
        #if os(tvOS)
        SettingsPage(title: L10n.text("Book Sources"), symbol: "text.book.closed", subtitle: about) {
            SettingsGroup(title: L10n.text("Source Lists"), footer: store.lists.isEmpty ? L10n.text("No book source lists yet.") : nil) {
                ForEach(store.lists) { list in
                    TVSettingsLink(title: NovelSources.title(of: list), value: count(list)) { NovelListView(url: list.address) }
                }
            }
            if !store.lists.isEmpty {
                SettingsGroup {
                    TVSettingsAction(title: L10n.text("Refresh All"), busy: refreshing) { refresh() }.disabled(refreshing)
                }
            }
            if !store.offers.isEmpty {
                SettingsGroup(title: L10n.text("Lists You Can Add"), footer: offersFooter) {
                    ForEach(store.offers) { offer in
                        let added = isAdded(offer)
                        Button { if !added { add(offer) } } label: {
                            TVSettingsRowLabel(title: offer.name, detail: offerErrors[offer.address] ?? offer.address.lastPathComponent,
                                               value: added ? L10n.text("Added") : adding.contains(offer.address) ? L10n.text("Adding…") : L10n.text("Add"))
                        }
                        .glassRow()
                    }
                }
                SettingsGroup {
                    TVSettingsAction(title: L10n.text("Clear Lists You Can Add")) { store.offer([]) }
                }
            }
        }
        .onAppear { store.reloadSources() }
        #else
        List {
            Section {
                if store.lists.isEmpty { Text(L10n.text("No book source lists yet.")).foregroundStyle(.secondary) }
                ForEach(store.lists) { list in
                    RouteLink { NovelListView(url: list.address) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(NovelSources.title(of: list)).lineLimit(1)
                                Text(L10n.text("Updated %@", list.updated.formatted(date: .abbreviated, time: .shortened))).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(count(list)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .contextMenu {
                        Button(L10n.text("Remove Source List"), role: .destructive) { store.removeList(list.address) }
                    }
                }
                .onDelete { offsets in
                    let urls = offsets.map { store.lists[$0].address }
                    for url in urls { store.removeList(url) }
                }
            } header: {
                HStack {
                    Text(L10n.text("Source Lists"))
                    Spacer()
                    if refreshing { ProgressView().appControlSize(.small) }
                    else if !store.lists.isEmpty {
                        Button { refresh() } label: { Label(L10n.text("Refresh All"), systemImage: "arrow.clockwise") }
                            .font(.footnote.weight(.semibold)).textCase(nil).tint(.secondary)
                    }
                }
            } footer: { Text(about) }
            if !store.offers.isEmpty {
                Section {
                    ForEach(store.offers) { offer in offerRow(offer) }
                } header: {
                    HStack {
                        Text(L10n.text("Lists You Can Add"))
                        Spacer()
                        Button(L10n.text("Clear")) { store.offer([]) }
                            .font(.footnote.weight(.semibold)).textCase(nil).tint(.secondary)
                    }
                } footer: { Text(offersFooter) }
            }
        }
        .screenTitle(L10n.text("Book Sources"))
        .onAppear { store.reloadSources() }
        #endif
    }

    #if !os(tvOS)
    private func offerRow(_ offer: NovelSourceOffer) -> some View {
        let error = offerErrors[offer.address]
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(offer.name).lineLimit(1)
                Text(error ?? offer.address.lastPathComponent).font(.caption).foregroundStyle(error == nil ? Color.secondary : Brand.amber).lineLimit(2)
            }
            Spacer()
            if isAdded(offer) {
                // Not a Label: a Label would move the row's separator to its title.
                (Text(Image(systemName: "checkmark")) + Text(" " + L10n.text("Added"))).font(.callout).foregroundStyle(.secondary)
            } else if adding.contains(offer.address) {
                ProgressView().appControlSize(.small)
            } else {
                Button(L10n.text("Add")) { add(offer) }.buttonStyle(.bordered).buttonBorderShape(.capsule)
            }
        }
    }
    #endif

    private var offersFooter: String {
        L10n.text("Found on %@. Lists you add appear under Source Lists.", store.offers.first?.address.host() ?? "")
    }
    private func isAdded(_ offer: NovelSourceOffer) -> Bool { store.lists.contains { $0.address == offer.address } }
    private func add(_ offer: NovelSourceOffer) {
        guard !adding.contains(offer.address) else { return }
        adding.insert(offer.address); offerErrors[offer.address] = nil
        Task {
            defer { adding.remove(offer.address) }
            do { try await store.add(offer) } catch { offerErrors[offer.address] = error.novelMessage }
        }
    }

    /// "12 of 340 on".
    private func count(_ list: NovelSourceList) -> String {
        // Read the store first: saved lists load in the background, and an empty list never reads `enabledKeys` in the
        // filter, so the row would not update when they arrive.
        let keys = store.enabledKeys
        let sources = NovelSources.shared.sources(in: list.address)
        return L10n.text("%lld of %lld on", sources.filter { keys.contains($0.key) }.count, sources.count)
    }

    private func refresh() {
        refreshing = true
        Task { await store.refreshLists(); refreshing = false }
    }
}

/// One list's sources, each switched on or off; search and explore use the ones that are on.
struct NovelListView: View {
    let url: URL
    @State private var store = NovelStore.shared
    @State private var filter = ""
    @State private var working = false
    @State private var message: String?
    /// The Name field's text, saved when it's submitted or the page closes rather than per keystroke.
    @State private var name: String
    @Environment(\.dismiss) private var dismiss

    init(url: URL) {
        self.url = url
        _name = State(initialValue: NovelStore.shared.lists.first { $0.address == url }?.name ?? "")
    }

    private var sources: [NovelSource] {
        _ = store.sources
        let all = NovelSources.shared.sources(in: url)
        guard !filter.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(filter) || $0.group.localizedCaseInsensitiveContains(filter) || $0.key.localizedCaseInsensitiveContains(filter) }
    }

    private func detail(_ source: NovelSource) -> String {
        var parts: [String] = []
        if !source.group.isEmpty { parts.append(source.group) }
        if !source.searchable { parts.append(L10n.text("No search")) }
        if source.explorable { parts.append(L10n.text("Explore")) }
        parts.append(URL(string: source.key)?.host() ?? source.key)
        return parts.joined(separator: " · ")
    }

    var body: some View {
        #if os(tvOS)
        TVSettingsSubpage(symbol: "text.book.closed", title: store.title(of: url), subtitle: L10n.text("%lld sources", sources.count)) {
            // Like a subscription's: a name of the viewer's own instead of the address's (#1099).
            SettingsGroup {
                TVSettingsField(title: L10n.text("Name"), text: Binding(get: { name }, set: { name = $0; store.renameList(url, to: $0) }), prose: true,
                                emptyValue: NovelSources.title(of: url))
            }
            SettingsGroup(footer: message) {
                TVSettingsAction(title: L10n.text("Turn All On")) { store.setEnabled(true, sources.map(\.key)) }
                TVSettingsAction(title: L10n.text("Turn All Off")) { store.setEnabled(false, sources.map(\.key)) }
                TVSettingsAction(title: L10n.text("Refresh List"), busy: working) { refresh() }.disabled(working)
            }
            SettingsGroup {
                ForEach(sources) { source in
                    let on = store.enabledKeys.contains(source.key)
                    Button { store.setEnabled(!on, [source.key]) } label: {
                        TVSettingsRowLabel(title: source.name, detail: detail(source), value: on ? L10n.text("On") : L10n.text("Off"))
                    }
                    .glassRow()
                }
            }
            SettingsGroup {
                TVSettingsAction(title: L10n.text("Remove Source List"), destructive: true) { store.removeList(url); dismiss() }
            }
        }
        #else
        List {
            // Like a subscription's: a name of the viewer's own instead of the address's (#1099). Empty shows that one.
            Section {
                LabeledContent(L10n.text("Name")) {
                    TextField(L10n.text("Name"), text: $name, prompt: Text(NovelSources.title(of: url)))
                        .labelsHidden().multilineTextAlignment(.trailing)
                        .onSubmit { store.renameList(url, to: name) }
                }
            }
            Section {
                HStack {
                    Button(L10n.text("Turn All On")) { store.setEnabled(true, sources.map(\.key)) }
                    Spacer()
                    Button(L10n.text("Turn All Off")) { store.setEnabled(false, sources.map(\.key)) }
                }
                .buttonStyle(.borderless)
            } footer: {
                Text(L10n.text("Search asks every source that is on. Turn off the ones that never answer to make it faster.") + " "
                     + L10n.text("Turn All On and Turn All Off change only the sources the filter shows, such as one group."))
            }
            Section {
                ForEach(sources) { source in
                    Toggle(isOn: Binding(get: { store.enabledKeys.contains(source.key) }, set: { store.setEnabled($0, [source.key]) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.name).lineLimit(1)
                            Text(detail(source)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .settingsSwitch()
                }
            } header: { Text(L10n.text("%lld sources", sources.count)) }
            Section {
                Button { refresh() } label: {
                    HStack { Text(L10n.text("Refresh List")); if working { Spacer(); ProgressView() } }
                }
                .disabled(working)
                Button(L10n.text("Remove Source List"), role: .destructive) { store.removeList(url); dismiss() }
            } footer: {
                if let message { Text(message) } else { Text(url.absoluteString).textSelection(.enabled) }
            }
        }
        .searchable(text: $filter, prompt: Text(L10n.text("Filter book sources")))
        .screenTitle(store.title(of: url))
        .onDisappear { store.renameList(url, to: name) }
        #endif
    }

    private func refresh() {
        working = true; message = nil
        Task {
            defer { working = false }
            do { try await store.refresh(url); message = L10n.text("Refreshed.") }
            catch { message = error.novelMessage }
        }
    }
}
