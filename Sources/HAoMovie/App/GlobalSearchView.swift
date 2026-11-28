import SwiftUI
#if os(iOS)
import UIKit
#endif

/// All-source search in Yingxia's catalog-search form: a bottom glass input bar,
/// history chips, and 136-point glass result cards over a drifting gradient.
/// The engine stays HAoMovie's source search (SearchModel): TMDB search, feeds,
/// filters and people rails need the TMDB Worker, which is not deployed yet,
/// so they are not faked here. Per-source chips, progress, Failed Sources +
/// retry, and per-source Load More are HAoMovie's own strengths, kept.
struct GlobalSearchView: View {
    @Environment(Store.self) private var store
    @State private var query = ""
    @State private var history: [String] = []
    @State private var focused = false
    @State private var expanded: Set<String> = []

    private var model: SearchModel { store.searchModel }
    private var keyword: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if keyword.isEmpty, !history.isEmpty { historyView.padding(.bottom, 12) }
                        if let config = store.subscription {
                            if model.busy, model.matches.isEmpty {
                                ProgressView().frame(maxWidth: .infinity).padding(.top, 50)
                            }
                            if model.busy, !model.matches.isEmpty { progressRow }
                            resultSections(config: config, width: geometry.size.width)
                            failedSources(config: config)
                            if !model.keyword.isEmpty, model.matches.isEmpty, !model.busy {
                                if model.failures.isEmpty {
                                    EmptyResults.search(model.keyword)
                                } else {
                                    EmptyResults(symbol: "wifi.exclamationmark", title: L10n.text("Couldn't Load Results"),
                                                 action: L10n.text("Try Again")) { store.searchVideos(model.keyword) }
                                }
                            }
                        } else {
                            SearchNeedsSubscriptionView()
                        }
                    }.padding(.top, 4).padding(.bottom, 16)
                }
                .scrollIndicators(.hidden)
                #if os(iOS)
                .scrollDismissesKeyboard(.interactively)
                #endif
                .safeAreaInset(edge: .top, spacing: 0) { topChrome }
                .safeAreaInset(edge: .bottom, spacing: 0) { bottomChrome }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipShape(DiscoverSearchHorizontalClip())
        }
        .background { Backdrop() }
        #if !os(macOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .onAppear {
            query = model.keyword
            reloadHistory()
        }
        .onChange(of: model.keyword) { _, keyword in
            query = keyword
            expanded.removeAll()
            reloadHistory()
        }
    }

    private var topChrome: some View {
        VStack(spacing: 20) {
            Text(L10n.text("Search")).font(.system(size: 17, weight: .semibold)).frame(height: 44).frame(maxWidth: .infinity)
            if store.subscription != nil {
                SourceStrip(items: [SourceStrip.Item(id: "", name: L10n.text("All Sources"))]
                    + model.matches.map { SourceStrip.Item(id: $0.id, name: $0.site.name) },
                            selection: model.selectedSource ?? "") {
                    model.select($0.isEmpty ? nil : $0)
                }
                .padding(.horizontal, 16)
            }
        }.padding(.top, 16).padding(.bottom, 4)
    }

    private var bottomChrome: some View {
        HStack(spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 19)).foregroundStyle(.secondary)
                DiscoverSearchInput(text: $query, focused: $focused) { submit() }
                    .frame(height: 44)
                if focused, !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .accessibilityLabel(L10n.text("Clear")).accessibilityIdentifier("discover.search.clear")
                }
            }.padding(.horizontal, 16).frame(height: 48).glassSurface(.regular, in: Capsule())
            if focused {
                Button { focused = false } label: { Image(systemName: "xmark").font(.system(size: 23)).frame(width: 48, height: 48).glassSurface(.regular, in: Circle()) }
                    .accessibilityLabel(L10n.text("Close")).accessibilityIdentifier("discover.search.cancel")
            }
        }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8)
    }

    private func submit() {
        guard !keyword.isEmpty else { focused = false; return }
        store.searchVideos(keyword)
        focused = false
    }

    private func reloadHistory() {
        history = UserDefaults.standard.data(forKey: "videoSearchHistory")
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
    }

    private func clearHistory() {
        history = []
        UserDefaults.standard.removeObject(forKey: "videoSearchHistory")
    }

    private var historyView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.text("Recent Searches")).font(.system(size: 16, weight: .semibold)); Spacer()
                Button { clearHistory() } label: { Image(systemName: "trash").font(.system(size: 13)).foregroundStyle(.secondary) }
                    .accessibilityLabel(L10n.text("Clear Search History"))
            }.padding(.horizontal, 16)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(history, id: \.self) { text in
                        Button { store.searchVideos(text) } label: { Text(text).font(.system(size: 13)).padding(.horizontal, 12).frame(height: 32).glassSurface(.regular, in: Capsule()) }
                    }
                }.padding(.horizontal, 16)
            }.scrollIndicators(.hidden)
        }
    }

    private var progressRow: some View {
        HStack {
            ProgressView().appControlSize(.small)
            Text(L10n.text("Searching… %lld of %lld sources", model.completed, model.total))
                .foregroundStyle(.secondary)
        }.padding(.horizontal, 16).padding(.top, 8)
    }

    @ViewBuilder private func resultSections(config: Subscription, width: CGFloat) -> some View {
        let shown = model.selectedSource.map { id in model.matches.filter { $0.id == id } } ?? model.matches
        ForEach(shown) { result in
            let videos = model.videos(for: result.id)
            if !videos.isEmpty {
                Section {
                    if expanded.contains(result.id) {
                        ForEach(videos) { video in
                            resultButton(video, result: result, config: config)
                                .padding(.horizontal, 16).padding(.bottom, 10)
                        }
                        if model.canLoadMore(result.id) {
                            Button { model.loadMore(result.id, config: config) } label: {
                                Group { if model.loadingMore { ProgressView() } else { Text(L10n.text("Load More")) } }
                                    .frame(maxWidth: .infinity).frame(height: 44)
                            }.disabled(model.loadingMore)
                        }
                    } else {
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 10) {
                                ForEach(videos) { video in
                                    resultButton(video, result: result, config: config)
                                        .frame(width: min(264, width - 32))
                                }
                            }.padding(.horizontal, 16)
                        }.scrollIndicators(.hidden).frame(height: 136).padding(.bottom, 12)
                    }
                } header: {
                    Button {
                        // Replace the two lazy layouts together; animating their insertion/removal
                        // cross-fades duplicate cards and repeatedly adjusts the scroll geometry.
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            focused = false
                            if expanded.contains(result.id) { expanded.remove(result.id) } else { expanded.insert(result.id) }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text("\(result.site.name) · \(videos.count)").font(.system(size: 16, weight: .semibold))
                            Image(systemName: expanded.contains(result.id) ? "rectangle.split.2x1" : "list.bullet")
                                .font(.system(size: 15, weight: .medium))
                            Spacer()
                        }.frame(height: 32).contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(.horizontal, 16).padding(.bottom, 4)
                }
            }
        }
    }

    private func resultButton(_ video: Video, result: SearchSourceResult, config: Subscription) -> some View {
        RouteLink {
            CatalogDestination(video: video, client: CatalogClient(site: result.site, origin: config.origin, jarURL: config.spiderURL))
        } label: {
            GlobalSearchCard(video: video)
        }.tmdbCardButton()
    }

    @ViewBuilder private func failedSources(config: Subscription) -> some View {
        if !model.failures.isEmpty, !model.matches.isEmpty {
            Section {
                ForEach(model.failures) { result in
                    HStack {
                        Text(result.site.name).lineLimit(1)
                        Spacer()
                        Text(result.error ?? "").foregroundStyle(.secondary).lineLimit(1)
                    }.padding(.horizontal, 16).padding(.vertical, 6)
                }
                Button(L10n.text("Retry Failed Sources")) { model.resume(config: config, retryFailures: true) }
                    .padding(.horizontal, 16).padding(.vertical, 6)
            } header: {
                Text(L10n.text("Failed Sources")).font(.system(size: 16, weight: .semibold))
                    .frame(height: 32, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 4)
            }
        }
    }
}

/// A search result as Yingxia's 136-point glass card: 80×120 poster, bold title,
/// year · remarks · category, and the source's synopsis. No star rating: a source
/// search result carries no rating to show.
struct GlobalSearchCard: View {
    let video: Video
    var body: some View {
        HStack(spacing: 10) {
            PosterImage(url: video.poster, headers: video.posterHeaders)
                .frame(width: 80, height: 120).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(video.name).font(.system(size: 17, weight: .bold)).lineLimit(1)
                Text([video.year ?? "", video.remarks, video.category ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                Text(video.synopsis.isEmpty ? " " : video.synopsis)
                    .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2).lineSpacing(2)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 4)
        }.padding(8).frame(height: 136)
            .contentPanel(cornerRadius: 16)
    }
}

/// Keep Duo's side display clear while allowing glass shadows through the vertical safe areas.
private struct DiscoverSearchHorizontalClip: Shape {
    func path(in rect: CGRect) -> Path { Path(CGRect(x: rect.minX, y: rect.minY - 1000, width: rect.width, height: rect.height + 2000)) }
}

#if os(iOS)
/// Do not submit marked text while a Chinese/Japanese IME is still composing.
private struct DiscoverSearchInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let submit: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.font = .systemFont(ofSize: 17)
        field.textColor = .label
        field.tintColor = .label
        field.placeholder = L10n.text("Search")
        field.returnKeyType = .search
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.accessibilityIdentifier = "discover.search.input"
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.markedTextRange == nil && field.text != text { field.text = text }
        if !focused && field.isFirstResponder {
            field.window?.endEditing(true)
        } else if focused && !field.isFirstResponder {
            DispatchQueue.main.async { [weak field, weak coordinator = context.coordinator] in
                guard let field, let coordinator, coordinator.parent.focused, field.window != nil else { return }
                field.becomeFirstResponder()
            }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: DiscoverSearchInput
        init(_ parent: DiscoverSearchInput) { self.parent = parent }
        @objc func changed(_ field: UITextField) {
            guard field.markedTextRange == nil else { return }
            parent.text = String((field.text ?? "").prefix(100))
        }
        func textFieldDidBeginEditing(_ field: UITextField) { if !parent.focused { parent.focused = true } }
        func textFieldDidEndEditing(_ field: UITextField) { changed(field); if parent.focused { parent.focused = false } }
        func textFieldShouldReturn(_ field: UITextField) -> Bool { changed(field); field.window?.endEditing(true); parent.submit(); return true }
    }
}
#else
private struct DiscoverSearchInput: View {
    @Binding var text: String
    @Binding var focused: Bool
    let submit: () -> Void
    @FocusState private var hasFocus: Bool
    var body: some View {
        TextField(L10n.text("Search"), text: $text)
            .font(.system(size: 16)).focused($hasFocus).autocorrectionDisabled().onSubmit(submit)
            .onChange(of: focused) { _, value in hasFocus = value }
            .onChange(of: hasFocus) { _, value in focused = value }
            .accessibilityIdentifier("discover.search.input")
    }
}
#endif
