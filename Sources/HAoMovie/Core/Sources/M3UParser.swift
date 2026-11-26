import Foundation

/// M3U / M3U8 播放列表的纯解析函数 —— 不含网络与 UI，可在 Linux 上实测。
enum M3UParser {

    /// 解析 M3U 文本。#EXTINF 行带 tvg-name / tvg-logo / group-title 属性，
    /// 下一行即播放地址；无 EXTINF 的裸 URL 行按组名 "其他" 归组。
    /// 脏行（空行、#EXTM3U 头、注释）全部跳过。
    static func parse(_ text: String) -> [LiveGroup] {
        var grouped: [String: [LiveChannel]] = [:]
        var order: [String] = []
        let lines = text.components(separatedBy: .newlines)
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            index += 1
            if line.hasPrefix("#EXTINF:") {
                let attributes = parseAttributes(line)
                // 逗号之后是显示名
                let displayName: String
                if let comma = line.firstIndex(of: ",") {
                    displayName = String(line[line.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
                } else {
                    displayName = ""
                }
                // 下一个非空行是地址
                var url = ""
                while index < lines.count {
                    let next = lines[index].trimmingCharacters(in: .whitespaces)
                    index += 1
                    if next.isEmpty || next.hasPrefix("#") { continue }
                    url = next
                    break
                }
                guard !url.isEmpty else { continue }
                let name = attributes["tvg-name"] ?? (displayName.isEmpty ? url : displayName)
                let group = attributes["group-title"] ?? "其他"
                let channel = LiveChannel(
                    name: name,
                    logo: attributes["tvg-logo"] ?? "",
                    group: group,
                    url: url
                )
                if grouped[group] == nil { order.append(group) }
                grouped[group, default: []].append(channel)
            } else if !line.isEmpty, !line.hasPrefix("#"), line.hasPrefix("http") {
                let group = "其他"
                let channel = LiveChannel(name: line, logo: "", group: group, url: line)
                if grouped[group] == nil { order.append(group) }
                grouped[group, default: []].append(channel)
            }
        }
        return order.map { LiveGroup(name: $0, channels: grouped[$0] ?? []) }
    }

    /// 解析 key="value" 形式的属性；值里有空格也保留。
    static func parseAttributes(_ line: String) -> [String: String] {
        var result: [String: String] = [:]
        var cursor = line.startIndex
        while cursor < line.endIndex {
            // 找 key=
            guard let eq = line[cursor...].firstIndex(of: "=") else { break }
            let keyStart = line[cursor..<eq].trimmingCharacters(in: .whitespaces)
            let key = keyStart.components(separatedBy: .whitespaces).last ?? ""
            var value = ""
            var next = line.index(after: eq)
            if next < line.endIndex, line[next] == "\"" {
                next = line.index(after: next)
                if let endQuote = line[next...].firstIndex(of: "\"") {
                    value = String(line[next..<endQuote])
                    cursor = line.index(after: endQuote)
                } else {
                    value = String(line[next...])
                    cursor = line.endIndex
                }
            } else {
                if let end = line[next...].firstIndex(where: { $0 == " " || $0 == "," }) {
                    value = String(line[next..<end])
                    cursor = end
                } else {
                    value = String(line[next...])
                    cursor = line.endIndex
                }
            }
            if !key.isEmpty { result[key] = value }
        }
        return result
    }
}
