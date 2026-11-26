import Foundation

/// 本地键值存储：UserDefaults + JSON 编解码。历史、收藏、订阅、播放进度都只存本机。
enum LocalStore {
    private static let defaults = UserDefaults.standard

    static func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func remove(key: String) {
        defaults.removeObject(forKey: key)
    }
}

/// 播放偏好（设置页可调）。
struct MovieSettings: Codable, Equatable {
    /// 默认倍速（0.5–4）
    var defaultSpeed: Double = 1.0
    /// 片头跳过秒数（0 = 不跳）
    var skipIntroSeconds: Double = 85
    /// 片尾跳过秒数（0 = 不跳）
    var skipOutroSeconds: Double = 90
    /// 是否记住上次倍速
    var rememberSpeed: Bool = true
    /// 自动连播下一集
    var autoNextEpisode: Bool = true
    /// M3U 直播列表地址（用户自填；为空则不显示直播源）
    var m3uURL: String = ""
}
