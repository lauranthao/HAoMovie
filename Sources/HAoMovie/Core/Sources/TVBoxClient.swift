import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// TVBox type 1 JSON 源的网络客户端。只支持 JSON 源（type 1/4）；jar 插件源不支持。
/// 单源超时 10 秒；失败由调用方记入冷却（SubscriptionStore），不在此重试。
enum TVBoxClient {

    enum ClientError: LocalizedError {
        case invalidURL
        case badStatus(Int)
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "源地址无效"
            case .badStatus(let code): return "源站返回 \(code)"
            case .emptyResponse: return "源站返回为空"
            }
        }
    }

    private static func get(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw ClientError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("HAoMovie/0.1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientError.badStatus(http.statusCode)
        }
        guard !data.isEmpty else { throw ClientError.emptyResponse }
        return data
    }

    /// 拉取订阅 JSON，返回其中的站点列表（只保留 JSON 源）。
    static func fetchSubscription(apiURL: String) async throws -> [TVBoxSite] {
        let data = try await get(apiURL)
        return try TVBoxParsing.parseSubscription(data).filter { $0.isSupported }
    }

    /// 拉取某站点的分类。
    static func fetchCategories(site: TVBoxSite) async throws -> [TVBoxSiteClass] {
        let data = try await get(site.api)
        return try TVBoxParsing.parseCategories(data)
    }

    /// 拉取某分类下某一页影片。
    static func fetchList(site: TVBoxSite, typeId: String, page: Int) async throws -> (items: [VodItem], page: Int, pageCount: Int, total: Int) {
        let url = site.api + (site.api.contains("?") ? "&" : "?") + "ac=videolist&t=\(typeId)&pg=\(page)"
        let data = try await get(url)
        return try TVBoxParsing.parseVodList(data)
    }

    /// 拉取影片详情（含播放线路）。
    static func fetchDetail(site: TVBoxSite, vodId: String) async throws -> VodDetail? {
        let url = site.api + (site.api.contains("?") ? "&" : "?") + "ac=videolist&ids=\(vodId)"
        let data = try await get(url)
        return try TVBoxParsing.parseVodDetail(data)
    }

    /// 在某站点内搜索。
    static func search(site: TVBoxSite, keyword: String) async throws -> [VodItem] {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let url = site.api + (site.api.contains("?") ? "&" : "?") + "ac=videolist&wd=\(encoded)"
        let data = try await get(url)
        return try TVBoxParsing.parseVodList(data).items
    }

    /// 拉取 M3U 直播列表文本。
    static func fetchM3U(urlString: String) async throws -> [LiveGroup] {
        let data = try await get(urlString)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .gb18030) else {
            throw ClientError.emptyResponse
        }
        return M3UParser.parse(text)
    }
}
