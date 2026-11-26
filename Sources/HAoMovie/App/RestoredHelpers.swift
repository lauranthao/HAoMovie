// Restored from Yingxia (jo32/tvbox-silicon, GPL-3.0) — shared helpers the kept
// files still use. Adapted for HAo Movie where noted (no TMDB, no JavaScript
// runtime, no libass/TVMedia); see the notes on each type.

import SwiftUI

struct FilterChipLabel: View {
    let title: String
    /// Its panel is showing.
    var open = false
    var body: some View {
        #if os(macOS)
        HStack(spacing: 6) {
            Text(title).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
        }
        .font(.system(size: 13)).padding(.horizontal, 12).frame(height: 30)
        .background(.primary.opacity(open ? 0.16 : 0.07), in: Capsule())
        .overlay { Capsule().strokeBorder(.primary.opacity(0.1), lineWidth: 0.5) }
        .contentShape(Capsule())
        #else
        HStack(spacing: 8) {
            Text(title).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 13, weight: .semibold))
        }.font(.system(size: 15)).padding(.horizontal, 14).frame(height: 38).glassSurface(.regular, in: Capsule())
        #endif
    }
}

struct SourceCreditsRow: View {
    let credits: [VideoCredit]
    let client: CatalogClient
    var body: some View {
        let groups: [(String, [VideoCredit])] = [(L10n.text("Director"), credits.filter { $0.role == .director }),
                                                 (L10n.text("Cast"), credits.filter { $0.role == .actor })].filter { !$0.1.isEmpty }
        VStack(alignment: .leading, spacing: 10) {
            ForEach(groups, id: \.0) { title, people in
                ChipRow {
                    HStack(spacing: 8) {
                        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(people, id: \.self) { person in
                            if let category = person.category {
                                RouteLink {
                                    SiteView(site: client.site, origin: client.origin, jarURL: client.jarURL,
                                             folder: Video(id: category, name: person.name, category: "folder"))
                                } label: { Label(person.name, systemImage: "person.crop.circle").lineLimit(1) }
                                .controlButton()
                            } else {
                                Text(person.name).font(.subheadline).lineLimit(1)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .tvFocusSection()
            }
        }
    }
}

enum BannerMetrics {
    #if os(tvOS)
    static let inset: CGFloat = 48, spacing: CGFloat = 14, title: CGFloat = 60, logoHeight: CGFloat = 150, corner: CGFloat = 24
    /// The facts line fits on one line at the TV's type size.
    static let textWidth: CGFloat = 1100
    static let factsFont = Font.title3
    #else
    static let inset: CGFloat = 24, spacing: CGFloat = 8, title: CGFloat = 34, logoHeight: CGFloat = 90, corner: CGFloat = 20
    static let textWidth: CGFloat = 760
    static let factsFont = Font.subheadline
    #endif
    static let backdropPixels = 2400
}

struct PosterBanner<Actions: View>: View {
    let poster: URL?
    var headers: [String: String] = [:]
    let title: String
    let subtitle: String
    /// The cover's width over height once it loads; landscape covers are common (Bilibili, short dramas).
    @Binding var aspect: CGFloat?
    @ViewBuilder let actions: Actions
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size, inset = BannerMetrics.inset
            let ratio = min(max(aspect ?? 2.0 / 3.0, 0.6), 1.8)
            // A landscape cover may take at most ~40% of the banner, so the title keeps its room.
            let artWidth = min(max(size.height - inset * 2, 60) * ratio, size.width * 0.4)
            ZStack(alignment: .bottomLeading) {
                Color(white: 0.12)
                PosterImage(url: poster, headers: headers)
                    .frame(width: size.width, height: size.height).clipped()
                    .blur(radius: 40).scaleEffect(1.35)
                    .overlay(Color.black.opacity(0.35))
                LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0), .init(color: .clear, location: 0.6)],
                               startPoint: .leading, endPoint: .trailing)
                PosterImage(url: poster, headers: headers, aspect: $aspect)
                    .frame(width: artWidth, height: artWidth / ratio)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
                    .padding(inset)
                    .frame(width: size.width, height: size.height, alignment: .trailing)
                VStack(alignment: .leading, spacing: BannerMetrics.spacing) {
                    Text(title).font(.system(size: BannerMetrics.title, weight: .bold)).lineLimit(2).minimumScaleFactor(0.7)
                        .shadow(color: .black.opacity(0.4), radius: 8)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(BannerMetrics.factsFont).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                    }
                    actions.padding(.top, 6)
                }
                .padding(inset)
                .frame(maxWidth: min(max(size.width - artWidth - inset * 2, 240), BannerMetrics.textWidth), alignment: .leading)
            }
        }
        .foregroundStyle(.white).environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: BannerMetrics.corner, style: .continuous))
    }
}

@MainActor final class BackgroundGrace {
    #if !os(macOS)
    private let name: String
    private var task: UIBackgroundTaskIdentifier = .invalid
    init(name: String) { self.name = name }
    func hold() {
        guard task == .invalid else { return }
        task = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.release() }
        }
    }
    func release() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
    #else
    init(name: String) {}
    func hold() {}
    func release() {}
    #endif
}
