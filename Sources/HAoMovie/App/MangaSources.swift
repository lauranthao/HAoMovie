// Ported from Yingxia (jo32/tvbox-silicon, GPL-3.0) — Sources/TVCore/MangaSources.swift.
// OMITTED: `install(from:)`, `install(code:origin:)` and `remove(_:)` (original lines ~99-129).
// They describe the script through `MangaRuntime.shared.inspect(code:)` and reset the source through
// `MangaRuntime.shared.reset(_:)`, and `remove` also clears `MangaSourceData`; all three need the
// QuickJS runtime, so they cannot run until the runtime leg lands. Restore them verbatim with
// MangaRuntime/MangaNetwork. Everything kept here is runtime-independent.
import Foundation

/// A source listed by a Venera repository (`index.json` of github.com/venera-app/venera-configs or a copy).
public struct MangaRepositoryEntry: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var key: String?
    public var address: URL
    public var version: String
    public var description: String
    public var id: String { key ?? address.absoluteString }
}

/// A source the viewer installed.
public struct MangaInstalledSource: Codable, Hashable, Sendable, Identifiable {
    public var key: String
    public var name: String
    public var version: String
    /// Where its script came from, for updates; nil when pasted or imported.
    public var origin: URL?
    public var installed: Date
    /// The script's checksum: a changed script restarts the source's runtime.
    public var revision: String
    public var id: String { key }
}

/// Installed Venera comic sources and the repositories they come from, kept in Application Support.
public final class MangaSources: @unchecked Sendable {
    public static let shared = MangaSources()
    /// Venera's own repository, which the Add Repository page offers (never added on its own).
    public static let veneraRepository = URL(string: "https://cdn.jsdelivr.net/gh/venera-app/venera-configs@main/index.json")!

    private let lock = NSLock()
    private var list: [MangaInstalledSource]
    private var repositoryList: [URL]
    private static var folder: URL { MangaLibrary.root.appendingPathComponent("Sources", isDirectory: true) }
    private static var listFile: URL { MangaLibrary.root.appendingPathComponent("sources.json") }
    private static var repositoriesFile: URL { MangaLibrary.root.appendingPathComponent("repositories.json") }

    init() {
        list = (try? JSONDecoder().decode([MangaInstalledSource].self, from: Data(contentsOf: Self.listFile))) ?? []
        repositoryList = (try? JSONDecoder().decode([URL].self, from: Data(contentsOf: Self.repositoriesFile))) ?? []
    }

    public var installed: [MangaInstalledSource] { lock.withLock { list } }
    public var repositories: [URL] { lock.withLock { repositoryList } }
    public func installed(_ key: String) -> MangaInstalledSource? { lock.withLock { list.first { $0.key == key } } }

    func code(_ key: String) throws -> String {
        try String(contentsOf: Self.folder.appendingPathComponent(key + ".js"), encoding: .utf8)
    }

    private func save() {
        try? FileManager.default.createDirectory(at: MangaLibrary.root, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: Self.listFile, options: .atomic) }
        if let data = try? JSONEncoder().encode(repositoryList) { try? data.write(to: Self.repositoriesFile, options: .atomic) }
    }

    // MARK: Repositories

    public func addRepository(_ url: URL) {
        lock.withLock {
            guard !repositoryList.contains(url) else { return }
            repositoryList.append(url); save()
        }
    }
    public func removeRepository(_ url: URL) { lock.withLock { repositoryList.removeAll { $0 == url }; save() } }

    /// How many sources a Venera source list holds, or nil when the data isn't one: a JSON array whose
    /// items name a script (`fileName` or a `.js` url) and a `key`.
    public static func listedCount(_ data: Data) -> Int? {
        guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]], !items.isEmpty else { return nil }
        let scripts = items.filter { item in
            let file = MangaValue.string(item["fileName"]) ?? MangaValue.string(item["filename"])
            let link = MangaValue.string(item["url"])
            return item["key"] != nil && (file?.hasSuffix(".js") == true || link?.hasSuffix(".js") == true)
        }
        return scripts.count * 2 >= items.count ? items.count : nil
    }

    /// The sources a repository lists. Addresses are resolved against the index's own address.
    public func entries(of repository: URL) async throws -> [MangaRepositoryEntry] {
        let (data, origin) = try await HTTPClient().get(repository)
        guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw TVError.unsupported(L10n.text("This address is not a Venera source list."))
        }
        return items.compactMap { item in
            let file = MangaValue.string(item["fileName"]) ?? MangaValue.string(item["filename"])
            let link = MangaValue.string(item["url"])
            guard let address = (link.flatMap { URL(string: $0) }) ?? file.flatMap({ URL(string: $0, relativeTo: origin)?.absoluteURL }) else { return nil }
            return MangaRepositoryEntry(name: MangaValue.string(item["name"]) ?? file ?? "", key: MangaValue.string(item["key"]), address: address,
                                        version: MangaValue.string(item["version"]) ?? "", description: MangaValue.string(item["description"]) ?? "")
        }
    }

    // MARK: Sources

    public func move(fromOffsets: IndexSet, toOffset: Int) {
        lock.withLock {
            var moved = list
            let items = fromOffsets.map { moved[$0] }
            for index in fromOffsets.sorted(by: >) { moved.remove(at: index) }
            let target = toOffset - fromOffsets.filter { $0 < toOffset }.count
            moved.insert(contentsOf: items, at: max(0, min(target, moved.count)))
            list = moved
            save()
        }
    }

    /// Whether `entry` is newer than what is installed under its key.
    public func hasUpdate(_ entry: MangaRepositoryEntry) -> Bool {
        guard let key = entry.key, let current = installed(key) else { return false }
        return Self.compare(entry.version, current.version) == .orderedDescending
    }

    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(x.count, y.count) {
            let l = index < x.count ? x[index] : 0, r = index < y.count ? y[index] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
