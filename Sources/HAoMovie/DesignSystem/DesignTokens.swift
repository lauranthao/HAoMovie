import SwiftUI

/// HAo Movie 自己的设计 token —— 不照搬映匣的样式。
/// 主色取品牌红（与 HAo Music 的红音符同系），卡片圆角 12，海报圆角 10，
/// 间距只用 4/8/12/16/20/24 六档。
enum HaoMovieDesign {
    /// 品牌红：播放键、选中态、强调文字
    static let accent = Color(red: 0.941, green: 0.267, blue: 0.220)
    /// 深色播放键（详情页大播放按钮在浅色底上用）
    static let playButton = Color(red: 0.941, green: 0.267, blue: 0.220)
    static let background = Color(.systemBackground)
    static let surface = Color(.secondarySystemBackground)
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let hairline = Color(.separator)

    // MARK: - 间距（只用这六档）
    static let space4: CGFloat = 4
    static let space8: CGFloat = 8
    static let space12: CGFloat = 12
    static let space16: CGFloat = 16
    static let space20: CGFloat = 20
    static let space24: CGFloat = 24

    // MARK: - 圆角
    static let cardRadius: CGFloat = 12
    static let posterRadius: CGFloat = 10
    static let chipRadius: CGFloat = 8
    static let sheetRadius: CGFloat = 20

    // MARK: - 海报比例
    static let posterRatio: CGFloat = 2.0 / 3.0
    static let backdropRatio: CGFloat = 16.0 / 9.0
}

extension View {
    /// 海报卡片的统一样式：圆角 + 细边
    func haoPosterStyle() -> some View {
        clipShape(RoundedRectangle(cornerRadius: HaoMovieDesign.posterRadius))
            .overlay(
                RoundedRectangle(cornerRadius: HaoMovieDesign.posterRadius)
                    .stroke(HaoMovieDesign.hairline, lineWidth: 0.5)
            )
    }

    /// 页面左右边距统一 16
    func haoPagePadding() -> some View {
        padding(.horizontal, HaoMovieDesign.space16)
    }
}
