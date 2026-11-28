// Ported from Yingxia (jo32/tvbox-silicon, GPL-3.0) — Sources/TVCore/MangaLibrary.swift, lines 1-73.
// OMITTED: the `MangaImages` actor (original lines 74-235). It asks the source for image requests
// through `MangaRuntime` (`thumbnailRequests`, `imageConfig`, `retryRequest`, `transformResponse`,
// `modify`) over `MangaHTTP`, so it cannot run until the QuickJS runtime leg lands; restore it with
// MangaRuntime/MangaNetwork. Everything kept here is runtime-independent.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Where the comic section keeps its files, and the viewer's shelf: favorites and reading history.
public enum MangaLibrary {
    public static var root: URL {
        #if os(tvOS)
        // tvOS apps have no persistent Application Support; Caches is what they keep.
        URL.cachesDirectory.appending(path: "com.tvbox.yingxia/Manga", directoryHint: .isDirectory)
        #else
        URL.applicationSupportDirectory.appending(path: "com.tvbox.yingxia/Manga", directoryHint: .isDirectory)
        #endif
    }

    /// Where reading stopped in one comic.
    public struct Progress: Codable, Hashable, Sendable, Identifiable {
        public var comic: MangaComic
        public var chapterID: String?
        public var chapterTitle: String
        public var chapterIndex: Int
        public var chapterCount: Int
        public var page: Int
        public var pageCount: Int
        public var updated: Date
        public var id: String { comic.identity }
        public init(comic: MangaComic, chapterID: String?, chapterTitle: String, chapterIndex: Int, chapterCount: Int, page: Int, pageCount: Int, updated: Date = Date()) {
            self.comic = comic; self.chapterID = chapterID; self.chapterTitle = chapterTitle; self.chapterIndex = chapterIndex
            self.chapterCount = chapterCount; self.page = page; self.pageCount = pageCount; self.updated = updated
        }
    }

    public struct Favorite: Codable, Hashable, Sendable, Identifiable {
        public var comic: MangaComic
        public var added: Date
        public var id: String { comic.identity }
        public init(comic: MangaComic, added: Date = Date()) { self.comic = comic; self.added = added }
    }

    /// Chapters the viewer has finished, by comic: read to the end of a chapter, or marked by hand. The progress
    /// only keeps one position, so earlier chapters need a set of their own to show as read.
    public struct ReadChapters: Codable, Equatable, Sendable {
        /// Finished chapter IDs, by comic identity.
        public var read: [String: Set<String>] = [:]
        public init() {}
        public func isRead(_ chapter: String, of comic: String) -> Bool { read[comic]?.contains(chapter) ?? false }
        public mutating func mark(_ chapter: String, of comic: String) { read[comic, default: []].insert(chapter) }
        public mutating func unmark(_ chapter: String, of comic: String) {
            read[comic]?.remove(chapter)
            if read[comic]?.isEmpty == true { read[comic] = nil }
        }
        /// Drop a comic's marks, as when it leaves the history. Says whether anything went.
        @discardableResult public mutating func forget(_ comic: String) -> Bool { read.removeValue(forKey: comic) != nil }
        /// Keep only these comics' marks, so the file doesn't outgrow the history. Says whether anything went.
        @discardableResult public mutating func keep(only comics: Set<String>) -> Bool {
            let before = read.count
            read = read.filter { comics.contains($0.key) }
            return read.count != before
        }
    }

    public static func load<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        try? JSONDecoder().decode(type, from: Data(contentsOf: root.appendingPathComponent(name)))
    }
    public static func save<T: Encodable>(_ value: T, as name: String) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: root.appendingPathComponent(name), options: .atomic) }
    }
}
