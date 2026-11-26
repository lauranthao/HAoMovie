import SwiftUI

/// 异步海报图：加载中显示占位色，失败显示胶片图标。
struct AsyncPoster: View {
    var urlString: String
    var ratio: CGFloat = HaoMovieDesign.posterRatio

    var body: some View {
        AsyncImage(url: URL(string: urlString)) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            case .failure:
                ZStack {
                    HaoMovieDesign.surface
                    Image(systemName: "film.fill")
                        .font(.title2)
                        .foregroundStyle(HaoMovieDesign.textSecondary)
                }
            default:
                HaoMovieDesign.surface
            }
        }
        .aspectRatio(ratio, contentMode: .fit)
        .haoPosterStyle()
    }
}

/// 海报卡片：图 + 标题 + 备注（HAo 自己的卡片样式：标题 13 号半粗，备注 11 号灰）。
struct PosterCard: View {
    var item: VodItem
    var showRemarks: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: HaoMovieDesign.space4) {
            AsyncPoster(urlString: item.vodPic)
            Text(item.vodName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            if showRemarks, !item.vodRemarks.isEmpty {
                Text(item.vodRemarks)
                    .font(.system(size: 11))
                    .foregroundStyle(HaoMovieDesign.textSecondary)
                    .lineLimit(1)
            }
        }
    }
}

/// 列表行：小海报 + 标题 + 元信息（搜索结果、历史用）。
struct VodRow: View {
    var item: VodItem
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: HaoMovieDesign.space12) {
            AsyncPoster(urlString: item.vodPic)
                .frame(width: 56)
            VStack(alignment: .leading, spacing: HaoMovieDesign.space4) {
                Text(item.vodName)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle ?? metaLine)
                    .font(.system(size: 12))
                    .foregroundStyle(HaoMovieDesign.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }

    private var metaLine: String {
        [item.typeName, item.vodYear, item.vodArea, item.vodRemarks]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
