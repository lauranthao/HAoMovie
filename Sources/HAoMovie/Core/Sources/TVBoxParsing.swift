import Foundation

/// TVBox type 1 JSON 的纯解析函数 —— 不含任何网络与 UI，可在 Linux 上实测。
enum TVBoxParsing {

    // MARK: - 播放线路解析

    /// vod_play_from 用 $$$ 分隔线路名，vod_play_url 用 $$$ 分隔各线路的选集，
    /// 选集之间用 # 分隔，集名与地址之间用 $ 分隔。
    /// 空线路、空地址、缺 $ 的脏项一律过滤。
    static func parsePlayLines(playFrom: String, playUrl: String) -> [VodPlayLine] {
        guard !playUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let fromParts = playFrom.components(separatedBy: "$$$")
        let urlParts = playUrl.components(separatedBy: "$$$")
        var lines: [VodPlayLine] = []
        for (index, urlPart) in urlParts.enumerated() {
            let episodes = parseEpisodes(urlPart)
            guard !episodes.isEmpty else { continue }
            let name: String
            if index < fromParts.count, !fromParts[index].trimmingCharacters(in: .whitespaces).isEmpty {
                name = fromParts[index].trimmingCharacters(in: .whitespaces)
            } else {
                name = "线路\(index + 1)"
            }
            lines.append(VodPlayLine(name: name, episodes: episodes))
        }
        return lines
    }

    static func parseEpisodes(_ part: String) -> [VodEpisode] {
        part.components(separatedBy: "#").compactMap { chunk in
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            // 集名与地址之间是最后一个 $（地址本身可能含 $ 编码，取最后一段为地址）
            guard let dollar = trimmed.lastIndex(of: "$") else { return nil }
            let title = String(trimmed[..<dollar]).trimmingCharacters(in: .whitespaces)
            let url = String(trimmed[trimmed.index(after: dollar)...]).trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty, !url.isEmpty else { return nil }
            return VodEpisode(title: title, url: url)
        }
    }

    // MARK: - 分类 / 列表 / 详情 JSON

    struct ClassListResponse: Codable {
        var list: [TVBoxSiteClass]?

        enum CodingKeys: String, CodingKey {
            case list = "class"
        }
    }

    struct VodListResponse: Codable {
        var list: [VodItem]?
        var page: Int?
        var pagecount: Int?
        var total: Int?
        var limit: Int?
    }

    static func parseCategories(_ data: Data) throws -> [TVBoxSiteClass] {
        let decoded = try JSONDecoder().decode(ClassListResponse.self, from: data)
        return decoded.list ?? []
    }

    static func parseVodList(_ data: Data) throws -> (items: [VodItem], page: Int, pageCount: Int, total: Int) {
        let decoded = try JSONDecoder().decode(VodListResponse.self, from: data)
        return (
            items: decoded.list ?? [],
            page: decoded.page ?? 1,
            pageCount: decoded.pagecount ?? 1,
            total: decoded.total ?? decoded.list?.count ?? 0
        )
    }

    /// 详情接口返回的 list 元素自带 vod_play_from / vod_play_url，直接解成 VodDetail。
    static func parseVodDetail(_ data: Data) throws -> VodDetail? {
        struct Wrapper: Codable { var list: [VodDetail]? }
        return try JSONDecoder().decode(Wrapper.self, from: data).list?.first
    }

    // MARK: - 订阅 JSON

    static func parseSubscription(_ data: Data) throws -> [TVBoxSite] {
        try JSONDecoder().decode(TVBoxSubscriptionJSON.self, from: data).sites
    }
}
