import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Douban's hot lists, read from the API its mobile site uses
/// (`m.douban.com/rexxar`). It answers only with a Douban Referer, and so
/// do its covers (img*.doubanio.com sends HTTP 418 without one;
/// `PosterResource` adds it). No account, no key: the lists are public.
enum DoubanCatalog {
    static let referer = "https://m.douban.com/movie/"

    enum Feed: String, CaseIterable, Sendable {
        case movies = "movie_hot_gaia"
        case television = "tv_hot"
        case variety = "show_hot"
        case showing = "movie_showing"
        case top250 = "movie_top250"

        var title: String {
            switch self {
            case .movies: L10n.text("Douban Hot Movies")
            case .television: L10n.text("Douban Hot Series")
            case .variety: L10n.text("Douban Hot Variety Shows")
            case .showing: L10n.text("Now Showing")
            case .top250: L10n.text("Top 250")
            }
        }
    }

    enum MediaType: String, Sendable {
        case movie, tv
    }

    struct Item: Hashable, Sendable, Identifiable {
        let id: String
        let title: String
        let year: Int?
        /// Douban's score out of 10; nil while a title has too few ratings.
        let rating: Double?
        let cover: URL?
        let mediaType: MediaType
        /// "2026 / 中国大陆 / 剧情 / <director> / <cast>"
        let subtitle: String
    }

    /// `start` pages through the list: the first title to return, counting from 0.
    static func items(_ feed: Feed, start: Int = 0, count: Int = 30, session: URLSession = .shared) async throws -> [Item] {
        var parts = URLComponents(string: "https://m.douban.com/rexxar/api/v2/subject_collection/\(feed.rawValue)/items")!
        parts.queryItems = [URLQueryItem(name: "start", value: String(start)), URLQueryItem(name: "count", value: String(count))]
        var request = URLRequest(url: parts.url!, timeoutInterval: 20)
        request.setValue(referer, forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> [Item] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["subject_collection_items"] as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
        var seen = Set<String>()
        return rows.compactMap { row -> Item? in
            // Lists can carry other kinds of rows (ads, books); only films and series open a title.
            guard let id = (row["id"] as? String) ?? (row["id"] as? NSNumber)?.stringValue, seen.insert(id).inserted,
                  let title = (row["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
                  let kind = row["type"] as? String, kind == "movie" || kind == "tv" else { return nil }
            // Series and variety lists give `pic`, the film list `cover`.
            let pic = row["pic"] as? [String: Any], cover = row["cover"] as? [String: Any]
            let address = (pic?["large"] as? String) ?? (pic?["normal"] as? String) ?? (cover?["url"] as? String)
            let score = ((row["rating"] as? [String: Any])?["value"] as? NSNumber)?.doubleValue
            let year = (row["year"] as? String).flatMap { Int($0) } ?? (row["year"] as? NSNumber)?.intValue
            return Item(id: id, title: title, year: year, rating: score.flatMap { $0 > 0 ? $0 : nil },
                        cover: address.flatMap { URL(string: $0) }, mediaType: kind == "movie" ? .movie : .tv,
                        subtitle: row["card_subtitle"] as? String ?? "")
        }
    }

    /// The title to search across the user's sources: Douban names each
    /// season as its own title ("现在就出发 第四季", and for some shows the
    /// year: "我家那闺女2026"); the search finds the series itself, so the
    /// season suffix (and a trailing year) is stripped. A film keeps its
    /// name ("银翼杀手2049").
    static func searchTitle(_ item: Item) -> String {
        let title = item.title
        var pattern = #"\s*第[一二三四五六七八九十百零〇\d]+季$"#
        if item.mediaType == .tv { pattern = #"(\s*第[一二三四五六七八九十百零〇\d]+季|(?<=\D)\s*(19|20)\d\d)$"# }
        guard let range = title.range(of: pattern, options: .regularExpression), range.lowerBound > title.startIndex else { return title }
        return String(title[..<range.lowerBound])
    }
}
