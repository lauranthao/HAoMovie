import SwiftUI

/// All-source search: one field, source chips, and each source's videos as they arrive.
/// A video opens its source's detail page; a source that failed can be retried.
struct GlobalSearchView: View {
    @Environment(Store.self) private var store
    @State private var query = ""
    @State private var history: [String] = []

    private var model: SearchModel { store.searchModel }

    var body: some View {
        List {
            if let config = store.subscription {
                sourceChips
                if model.busy {
                    Section {
                        HStack {
                            ProgressView().appControlSize(.small)
                            Text(L10n.text("Searching… %lld of %lld sources", model.completed, model.total))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                resultSections(config: config)
                if model.canLoadMore(model.selectedSource) {
                    Section {
                        Button(L10n.text("Load More")) { model.loadMore(model.selectedSource, config: config) }
                    }
                }
                if !model.failures.isEmpty {
                    Section(L10n.text("Failed Sources")) {
                        ForEach(model.failures) { result in
                            HStack {
                                Text(result.site.name).lineLimit(1)
                                Spacer()
                                Text(result.error ?? "").foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Button(L10n.text("Retry Failed Sources")) { model.resume(config: config, retryFailures: true) }
                    }
                }
            } else {
                Section {
                    Text(L10n.text("Add a subscription in Settings to search its sources."))
                        .foregroundStyle(.secondary)
                }
            }
            if model.keyword.isEmpty, !history.isEmpty {
                Section(L10n.text("Recent Searches")) {
                    ForEach(history, id: \.self) { term in
                        Button(term) { store.searchVideos(term) }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: L10n.text("Search videos"))
        .onSubmit(of: .search) { store.searchVideos(query) }
        .onAppear {
            query = model.keyword
            history = UserDefaults.standard.data(forKey: "videoSearchHistory")
                .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        }
        .onChange(of: model.keyword) { _, keyword in query = keyword }
        .navigationTitle(L10n.text("Search"))
    }

    private var sourceChips: some View {
        Section {
            SourceStrip(items: [SourceStrip.Item(id: "", name: L10n.text("All Sources"))]
                + model.matches.map { SourceStrip.Item(id: $0.id, name: $0.site.name) },
                        selection: model.selectedSource ?? "") {
                model.select($0.isEmpty ? nil : $0)
            }
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    }

    @ViewBuilder private func resultSections(config: Subscription) -> some View {
        let shown = model.selectedSource.map { id in model.matches.filter { $0.id == id } } ?? model.matches
        if !model.keyword.isEmpty, shown.isEmpty, !model.busy {
            Section {
                Text(L10n.text("No results for “%@”.", model.keyword)).foregroundStyle(.secondary)
            }
        }
        ForEach(shown) { result in
            let videos = model.videos(for: result.id)
            if !videos.isEmpty {
                Section(header: Text("\(result.site.name) · \(videos.count)")) {
                    ForEach(videos) { video in
                        RouteLink {
                            CatalogDestination(video: video, client: CatalogClient(site: result.site, origin: config.origin, jarURL: config.spiderURL))
                        } label: {
                            HStack(spacing: 12) {
                                PosterImage(url: video.poster, headers: video.posterHeaders)
                                    .frame(width: 48, height: 72)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(video.name).lineLimit(2)
                                    Text([video.year ?? "", video.remarks].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
