import Foundation

extension Site {
    public var searchable: Bool { (raw["searchable"]?.int ?? 1) == 1 }
    /// TVBox's `hide: 1` keeps a search-only source out of the source lists.
    public var hidden: Bool { raw["hide"]?.int == 1 }
    public func canBrowse(jarURL: URL?) -> Bool {
        // Telegram channels are answered by the app itself, not by a spider.
        if isTelegram { return true }
        // Only native JSON/XML sources run in this build: no JAR, JS or Python runtime is included.
        if native { return true }
        return false
    }
}

/// One later page of a source's search results.
public struct SearchBatch: Identifiable, Sendable {
    public let source: String
    public let page: Int
    public let videos: [Video]
    public var id: String { "\(source)#\(page)" }
}

public struct SearchSourceResult: Identifiable, Sendable {
    public let site: Site
    public let page: CatalogPage?
    public let error: String?
    public var id: String { site.id }
}

/// One source currently executing a global search, regardless of runtime or subscription.
public struct SearchSourceActivity: Identifiable, Sendable {
    public let site: Site
    public let started: Date
    public var id: String { site.id }
}

public enum GlobalSearch {
    /// Limit simultaneous plugin processes and publish each source independently.
    public static func search(sites: [Site], origin: URL, jarURL: URL?, query: String,
                              http: HTTPClient = HTTPClient(), concurrency: Int = 4,
                              onStart: @escaping @Sendable (Site) async -> Void = { _ in },
                              onResult: @escaping @Sendable (SearchSourceResult) async -> Void) async {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        var seen = Set<String>()
        let eligible = sites.filter { $0.searchable && $0.canBrowse(jarURL: jarURL) && seen.insert($0.id).inserted }
        let began = ContinuousClock.now
        Diagnostics.shared.record(.info, "search", "begin sources=\(eligible.count) plugins=\(eligible.filter { !$0.native }.count) skipped=\(sites.count - eligible.count)")
        defer { Diagnostics.shared.record(.info, "search", "end elapsed=\(began.duration(to: .now)) cancelled=\(Task.isCancelled)") }
        // Only native sources are searched in this build: no JAR, JS or Python runtime is included.
        await run(eligible.filter(\.native), concurrency: concurrency, origin: origin, jarURL: jarURL,
                  keyword: keyword, http: http, onStart: onStart, onResult: onResult)
    }

    private static func run(_ eligible: [Site], concurrency: Int, origin: URL, jarURL: URL?, keyword: String, http: HTTPClient,
                            onStart: @escaping @Sendable (Site) async -> Void,
                            onResult: @escaping @Sendable (SearchSourceResult) async -> Void) async {
        guard !eligible.isEmpty else { return }
        await withTaskGroup(of: SearchSourceResult.self) { group in
            var iterator = eligible.makeIterator()
            func enqueue(_ site: Site) {
                group.addTask {
                    let started = ContinuousClock.now
                    do {
                        try Task.checkCancellation()
                        await onStart(site)
                        let page = try await CatalogClient(site: site, origin: origin, http: http, jarURL: jarURL)
                            .list(category: nil, query: keyword, page: 1)
                        Diagnostics.shared.record(.debug, "search", "source=\(site.key) ok videos=\(page.videos.count) elapsed=\(started.duration(to: .now))")
                        return SearchSourceResult(site: site, page: page, error: nil)
                    } catch {
                        // localizedDescription hides the error type; keep the full value for diagnosis.
                        Diagnostics.shared.record(.warning, "search", "source=\(site.key) native=\(site.native) failed elapsed=\(started.duration(to: .now)) error=\(String(reflecting: error))")
                        return SearchSourceResult(site: site, page: nil, error: error.localizedDescription)
                    }
                }
            }
            for _ in 0..<min(max(1, concurrency), eligible.count) {
                if let site = iterator.next() { enqueue(site) }
            }
            for await result in group {
                guard !Task.isCancelled else { group.cancelAll(); break }
                await onResult(result)
                if let site = iterator.next() { enqueue(site) }
            }
        }
    }
}
