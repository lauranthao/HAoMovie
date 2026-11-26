import Foundation

// MARK: - 订阅（TVBox JSON）

/// 一条用户导入的 TVBox 订阅。App 自身不内置任何订阅地址。
struct TVBoxSubscription: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    /// 订阅 JSON 的地址（http/https），或粘贴导入时记为 "pasted"
    var apiURL: String
    /// 是否启用（停用的订阅不参与搜索与浏览）
    var enabled: Bool
    var createdAt: Date
    /// 最近一次拉取失败的时间；失败后搜索时排后、冷却 10 分钟
    var lastFailureAt: Date?

    init(id: UUID = UUID(), name: String, apiURL: String, enabled: Bool = true, createdAt: Date = Date(), lastFailureAt: Date? = nil) {
        self.id = id
        self.name = name
        self.apiURL = apiURL
        self.enabled = enabled
        self.createdAt = createdAt
        self.lastFailureAt = lastFailureAt
    }

    var isCoolingDown: Bool {
        guard let lastFailureAt else { return false }
        return Date().timeIntervalSince(lastFailureAt) < 600
    }
}

/// 订阅 JSON 里的站点（type 1 源）。
struct TVBoxSite: Identifiable, Codable, Equatable {
    var key: String
    var name: String
    var type: Int
    var api: String
    /// 是否可搜索（type 1/4 可搜；jar 爬虫源暂不支持）
    var searchable: Bool

    var id: String { key }

    /// 本腿只支持 JSON 源（type 1/4）；jar 插件源（type 3）明确不支持。
    var isSupported: Bool { type == 1 || type == 4 }

    enum CodingKeys: String, CodingKey {
        case key, name, type, api, searchable
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try VodItem.flexibleString(c, .key)
        name = try VodItem.flexibleString(c, .name)
        // type 可能是数字或字符串
        if let i = try? c.decode(Int.self, forKey: .type) {
            type = i
        } else if let s = try? c.decode(String.self, forKey: .type), let i = Int(s) {
            type = i
        } else {
            type = 0
        }
        api = try VodItem.flexibleString(c, .api)
        searchable = try c.decodeIfPresent(Bool.self, forKey: .searchable) ?? true
    }

    init(key: String, name: String, type: Int, api: String, searchable: Bool = true) {
        self.key = key
        self.name = name
        self.type = type
        self.api = api
        self.searchable = searchable
    }
}

/// 订阅 JSON 顶层（只取需要的字段，其余忽略）。
struct TVBoxSubscriptionJSON: Codable {
    var sites: [TVBoxSite]
}

/// 播放线路 / 站内分类共用。
struct TVBoxSiteClass: Identifiable, Codable, Equatable {
    var typeId: String
    var typeName: String

    var id: String { typeId }

    enum CodingKeys: String, CodingKey {
        case typeId = "type_id"
        case typeName = "type_name"
    }
}

// MARK: - 影片

/// 列表里的影片条目。vod_id 在各源可能是字符串或数字，统一解成字符串。
struct VodItem: Identifiable, Codable, Equatable {
    var vodId: String
    var vodName: String
    var vodPic: String
    var vodRemarks: String
    var vodYear: String
    var vodArea: String
    var vodActor: String
    var vodDirector: String
    var vodContent: String
    var typeName: String

    var id: String { vodId }

    enum CodingKeys: String, CodingKey {
        case vodId = "vod_id"
        case vodName = "vod_name"
        case vodPic = "vod_pic"
        case vodRemarks = "vod_remarks"
        case vodYear = "vod_year"
        case vodArea = "vod_area"
        case vodActor = "vod_actor"
        case vodDirector = "vod_director"
        case vodContent = "vod_content"
        case typeName = "type_name"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vodId = try Self.flexibleString(c, .vodId)
        vodName = try Self.flexibleString(c, .vodName)
        vodPic = try Self.flexibleString(c, .vodPic)
        vodRemarks = try Self.flexibleString(c, .vodRemarks)
        vodYear = try Self.flexibleString(c, .vodYear)
        vodArea = try Self.flexibleString(c, .vodArea)
        vodActor = try Self.flexibleString(c, .vodActor)
        vodDirector = try Self.flexibleString(c, .vodDirector)
        vodContent = try Self.flexibleString(c, .vodContent)
        typeName = try Self.flexibleString(c, .typeName)
    }

    init(vodId: String, vodName: String, vodPic: String = "", vodRemarks: String = "", vodYear: String = "", vodArea: String = "", vodActor: String = "", vodDirector: String = "", vodContent: String = "", typeName: String = "") {
        self.vodId = vodId
        self.vodName = vodName
        self.vodPic = vodPic
        self.vodRemarks = vodRemarks
        self.vodYear = vodYear
        self.vodArea = vodArea
        self.vodActor = vodActor
        self.vodDirector = vodDirector
        self.vodContent = vodContent
        self.typeName = typeName
    }

    /// decodeIfPresent 在类型不匹配时会抛错（缺 key/null 才返回 nil），
    /// 所以用 try? 逐个试 String / Int，数字统一转字符串。
    static func flexibleString(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> String {
        if let s = try? c.decode(String.self, forKey: key) { return s }
        if let i = try? c.decode(Int.self, forKey: key) { return String(i) }
        return ""
    }

    /// TVBoxSite 的 CodingKeys 与 VodItem 的不同名，但 key 的 rawValue 相同；
    /// 用泛型容器重载，供 TVBoxSite.init(from:) 复用。
    static func flexibleString<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> String {
        if let s = try? c.decode(String.self, forKey: key) { return s }
        if let i = try? c.decode(Int.self, forKey: key) { return String(i) }
        return ""
    }
}

/// 详情页影片：条目字段 + 播放源字符串。
struct VodDetail: Codable, Equatable {
    var item: VodItem
    /// 线路名，$$$ 分隔，如 "线路1$$$线路2"
    var vodPlayFrom: String
    /// 各线路选集，$$$ 分隔线路，# 分隔集，$ 分隔集名与地址
    var vodPlayUrl: String

    enum CodingKeys: String, CodingKey {
        case vodPlayFrom = "vod_play_from"
        case vodPlayUrl = "vod_play_url"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        item = try VodItem(from: decoder)
        vodPlayFrom = try VodItem.flexibleString(c, .vodPlayFrom)
        vodPlayUrl = try VodItem.flexibleString(c, .vodPlayUrl)
    }

    init(item: VodItem, vodPlayFrom: String = "", vodPlayUrl: String = "") {
        self.item = item
        self.vodPlayFrom = vodPlayFrom
        self.vodPlayUrl = vodPlayUrl
    }

    /// 解析出的播放线路（空线路、空地址已过滤）。
    var playLines: [VodPlayLine] {
        TVBoxParsing.parsePlayLines(playFrom: vodPlayFrom, playUrl: vodPlayUrl)
    }
}

/// 一条播放线路。
struct VodPlayLine: Identifiable, Equatable {
    var name: String
    var episodes: [VodEpisode]

    var id: String { name }
}

/// 一集。
struct VodEpisode: Identifiable, Equatable {
    var title: String
    var url: String

    var id: String { title + "|" + url }
}

// MARK: - 直播

/// M3U 频道。
struct LiveChannel: Identifiable, Equatable {
    var name: String
    var logo: String
    var group: String
    var url: String

    var id: String { group + "|" + name + "|" + url }
}

/// M3U 分组。
struct LiveGroup: Identifiable, Equatable {
    var name: String
    var channels: [LiveChannel]

    var id: String { name }
}

// MARK: - 历史与收藏（本地）

/// 继续观看记录。播放失败不回写进度（旧进度保留）。
struct HistoryEntry: Identifiable, Codable, Equatable {
    var vodId: String
    var siteKey: String
    var siteName: String
    var vodName: String
    var poster: String
    var episodeTitle: String
    var episodeIndex: Int
    var lineIndex: Int
    /// 秒
    var position: Double
    /// 秒；0 表示未知总长
    var duration: Double
    var updatedAt: Date

    var id: String { siteKey + "|" + vodId }

    var progress: Double {
        guard duration > 0, position > 0 else { return 0 }
        return min(1, position / duration)
    }

    var isFinished: Bool { progress >= 0.95 }
}

struct FavoriteEntry: Identifiable, Codable, Equatable {
    var vodId: String
    var siteKey: String
    var siteName: String
    var vodName: String
    var poster: String
    var addedAt: Date

    var id: String { siteKey + "|" + vodId }
}
