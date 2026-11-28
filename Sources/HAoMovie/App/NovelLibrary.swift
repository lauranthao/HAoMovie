// Ported from Yingxia (jo32/tvbox-silicon, GPL-3.0) — Sources/TVCore/NovelLibrary.swift, lines 1-146.
// OMITTED: the `NovelBooks` actor (original lines 147-319). It searches, explores, reads details,
// tables of contents and chapter text through `NovelRuntime` (QuickJS + Legado engine.js) and
// `NovelSources`, so it cannot run until the QuickJS runtime leg lands; restore it verbatim with
// NovelRuntime. Everything kept here is runtime-independent.
import Foundation

/// Where the Novels section keeps its files, and the viewer's bookshelf.
public enum NovelLibrary {
    public static var root: URL {
        #if os(tvOS)
        // tvOS apps have no persistent Application Support; Caches is what they keep.
        URL.cachesDirectory.appending(path: "com.tvbox.yingxia/Novels", directoryHint: .isDirectory)
        #else
        URL.applicationSupportDirectory.appending(path: "com.tvbox.yingxia/Novels", directoryHint: .isDirectory)
        #endif
    }
    /// Tables of contents and chapter texts, which can always be read again from the source.
    static var cache: URL { URL.cachesDirectory.appending(path: "com.tvbox.yingxia/NovelText", directoryHint: .isDirectory) }

    /// A book on the shelf, and where reading stopped in it.
    public struct ShelfBook: Codable, Hashable, Sendable, Identifiable {
        public var book: NovelBook
        public var added: Date
        public var chapterIndex: Int
        public var chapterTitle: String
        public var chapterCount: Int
        /// How far into the chapter, 0–1.
        public var position: Double
        /// For an audiobook, where in the chapter listening stopped, in seconds (#1130).
        public var seconds: Double?
        public var updated: Date
        /// Places the viewer marked (#1452), in reading order.
        public var bookmarks: [NovelBookmark]
        /// One shelf entry per title and author, whichever source it is read from.
        public var id: String { book.match }
        public init(book: NovelBook, added: Date = Date(), chapterIndex: Int = 0, chapterTitle: String = "", chapterCount: Int = 0, position: Double = 0,
                    updated: Date = Date(), bookmarks: [NovelBookmark] = []) {
            self.book = book; self.added = added; self.chapterIndex = chapterIndex; self.chapterTitle = chapterTitle
            self.chapterCount = chapterCount; self.position = position; self.updated = updated; self.bookmarks = bookmarks
        }
        /// Shelves saved before bookmarks have none.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            book = try c.decode(NovelBook.self, forKey: .book)
            added = ((try? c.decodeIfPresent(Date.self, forKey: .added)) ?? nil) ?? Date()
            chapterIndex = ((try? c.decodeIfPresent(Int.self, forKey: .chapterIndex)) ?? nil) ?? 0
            chapterTitle = ((try? c.decodeIfPresent(String.self, forKey: .chapterTitle)) ?? nil) ?? ""
            chapterCount = ((try? c.decodeIfPresent(Int.self, forKey: .chapterCount)) ?? nil) ?? 0
            position = ((try? c.decodeIfPresent(Double.self, forKey: .position)) ?? nil) ?? 0
            updated = ((try? c.decodeIfPresent(Date.self, forKey: .updated)) ?? nil) ?? added
            bookmarks = ((try? c.decodeIfPresent([NovelBookmark].self, forKey: .bookmarks)) ?? nil) ?? []
        }
        public var started: Bool { chapterIndex > 0 || position > 0 || !chapterTitle.isEmpty }

        /// Adds a bookmark, keeping them in reading order.
        public mutating func mark(_ bookmark: NovelBookmark) {
            bookmarks.removeAll { $0.id == bookmark.id }
            let at = bookmarks.firstIndex { ($0.chapterIndex, $0.position) > (bookmark.chapterIndex, bookmark.position) } ?? bookmarks.count
            bookmarks.insert(bookmark, at: at)
        }

        /// Reads on from another source's copy (#1450): the place and the bookmarks move to the same chapters there,
        /// found by title, else by number.
        public mutating func follow(_ book: NovelBook, chapters: [NovelChapter]) {
            self.book = book
            if let index = NovelChapterMatch.index(title: chapterTitle, index: chapterIndex, in: chapters) {
                chapterIndex = index; chapterTitle = chapters[index].title
            }
            for at in bookmarks.indices {
                guard let index = NovelChapterMatch.index(title: bookmarks[at].chapterTitle, index: bookmarks[at].chapterIndex, in: chapters) else { continue }
                bookmarks[at].chapterIndex = index; bookmarks[at].chapterTitle = chapters[index].title
            }
            bookmarks.sort { ($0.chapterIndex, $0.position) < ($1.chapterIndex, $1.position) }
            chapterCount = chapters.count
        }
    }

    /// Moves the shelf's entry for `old` to another source's copy (#1450), the place and bookmarks with it, where it stood.
    /// A shelf entry the new copy already made (reading it records it, and its author can differ) gives way to it.
    /// False when `old` isn't on the shelf.
    @discardableResult
    public static func switchSource(_ shelf: inout [ShelfBook], from old: NovelBook, to book: NovelBook, chapters: [NovelChapter]) -> Bool {
        guard let index = shelf.firstIndex(where: { $0.id == old.match }) else { return false }
        var entry = shelf.remove(at: index)
        entry.follow(book, chapters: chapters)
        shelf.removeAll { $0.id == entry.id }
        shelf.insert(entry, at: min(index, shelf.count))
        return true
    }

    public static func load<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        try? JSONDecoder().decode(type, from: Data(contentsOf: root.appendingPathComponent(name)))
    }
    public static func save<T: Encodable>(_ value: T, as name: String) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: root.appendingPathComponent(name), options: .atomic) }
    }
}

/// A place the viewer marked in a book: the chapter (its number and title, so it survives a change of source) and how
/// far into it, with the words there to recognise it by.
public struct NovelBookmark: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var chapterIndex: Int
    public var chapterTitle: String
    /// How far into the chapter, 0–1, as the shelf keeps the reading place.
    public var position: Double
    public var excerpt: String
    public var created: Date
    public init(id: UUID = UUID(), chapterIndex: Int, chapterTitle: String, position: Double, excerpt: String, created: Date = Date()) {
        self.id = id; self.chapterIndex = chapterIndex; self.chapterTitle = chapterTitle
        self.position = min(1, max(0, position)); self.excerpt = excerpt; self.created = created
    }
}

/// Finds a chapter in another source's table of contents: the same title (ignoring spaces and punctuation; the one
/// nearest the old number when several share it), else the same number.
public enum NovelChapterMatch {
    public static func key(_ title: String) -> String { title.lowercased().filter { $0.isLetter || $0.isNumber } }

    public static func index(title: String, index: Int, in chapters: [NovelChapter]) -> Int? {
        let wanted = key(title)
        if !wanted.isEmpty {
            let same = chapters.filter { !$0.isVolume && key($0.title) == wanted }
            if let nearest = same.min(by: { abs($0.index - index) < abs($1.index - index) }) { return nearest.index }
        }
        guard !chapters.isEmpty else { return nil }
        let at = min(max(0, index), chapters.count - 1)
        // A volume heading isn't read: the chapter after it.
        return chapters[at...].first { !$0.isVolume }?.index ?? chapters[..<at].last { !$0.isVolume }?.index
    }
}

/// One search result: the same book from every source that listed it, the first source's copy first.
public struct NovelSearchHit: Sendable, Identifiable, Hashable {
    public var books: [NovelBook]
    /// The first book's `match`, worked out once: search looks up every book every source answers with by it.
    public let id: String
    /// The first book's title and author as `match` reads them, for ranking.
    let name: String, author: String
    public var book: NovelBook { books[0] }
    public init(books: [NovelBook]) {
        self.books = books
        name = NovelBook.normalized(books[0].name)
        author = NovelBook.normalized(books[0].author)
        id = name + "|" + author
    }
}
