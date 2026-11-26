// Restored from Yingxia (jo32/tvbox-silicon, GPL-3.0) — shared helpers the kept
// files still use. Adapted for HAo Movie where noted (no TMDB, no JavaScript
// runtime, no libass/TVMedia); see the notes on each type.

import SwiftUI

enum FormMetrics {
    #if os(macOS)
    static let icon: CGFloat = 22, symbol: CGFloat = 11, hero: CGFloat = 52
    #else
    static let icon: CGFloat = 30, symbol: CGFloat = 14, hero: CGFloat = 64
    #endif
}

struct SettingsIcon: View {
    let symbol: String
    var tint: Color = .gray
    var body: some View {
        #if os(iOS)
        // Black (Douyin) would vanish in dark mode, so it follows the text colour.
        Image(systemName: symbol)
            .font(.system(size: FormMetrics.symbol, weight: .semibold)).foregroundStyle(tint == .black ? Color.primary : tint)
            .frame(width: FormMetrics.icon, height: FormMetrics.icon)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: FormMetrics.icon * 0.26, style: .continuous))
            .accessibilityHidden(true)
        #else
        Image(systemName: symbol)
            .font(.system(size: FormMetrics.symbol, weight: .semibold)).foregroundStyle(.white)
            .frame(width: FormMetrics.icon, height: FormMetrics.icon)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: FormMetrics.icon * 0.26, style: .continuous))
            .accessibilityHidden(true)
        #endif
    }
}

struct FormLabel: View {
    let symbol: String
    var tint: Color = .gray
    let title: String
    var subtitle: String? = nil
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle, !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
        } icon: { SettingsIcon(symbol: symbol, tint: tint) }
    }
}

struct FormLink<Destination: View>: View {
    let symbol: String
    var tint: Color = .gray
    let title: String
    var value: String? = nil
    var warning = false
    @ViewBuilder var destination: () -> Destination
    var body: some View {
        RouteLink(destination: destination) {
            #if os(iOS)
            // One line, as in the Settings app: the title keeps its width and a long value is cut
            // short; LabeledContent dropped the value under the title instead.
            HStack(spacing: 8) {
                FormLabel(symbol: symbol, tint: tint, title: title).lineLimit(1).layoutPriority(1)
                Spacer(minLength: 0)
                if let value, !value.isEmpty { valueText(value) }
            }
            #else
            LabeledContent {
                if let value, !value.isEmpty { valueText(value) }
            } label: { FormLabel(symbol: symbol, tint: tint, title: title) }
            #endif
        }
    }
    private func valueText(_ value: String) -> some View {
        Text(value).lineLimit(1).foregroundStyle(warning ? AnyShapeStyle(Brand.amber) : AnyShapeStyle(.secondary))
    }
}

struct SettingsWebRow: View {
    let symbol: String
    var tint: Color = .gray
    let title: String
    var subtitle: String? = nil
    let url: URL
    @Environment(\.openURL) private var openURL
    var body: some View {
        Button { openURL(url) } label: {
            HStack(spacing: 8) {
                FormLabel(symbol: symbol, tint: tint, title: title, subtitle: subtitle).foregroundStyle(.primary)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        #if os(macOS)
        .buttonStyle(.plain)
        #else
        // A button in a list draws its title in the tint; this one reads like the rows around it.
        .tint(.primary)
        #endif
    }
}
