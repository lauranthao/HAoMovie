// Restored from Yingxia (jo32/tvbox-silicon, GPL-3.0) — shared helpers the kept
// files still use. Adapted for HAo Movie where noted (no TMDB, no JavaScript
// runtime, no libass/TVMedia); see the notes on each type.

import Accelerate
import CoreImage
import ImageIO
import SwiftUI

enum DiscoverLayout {
    #if os(tvOS)
    static let gutter: CGFloat = 50
    static let spacing: CGFloat = 40
    static let posterWidth: CGFloat = 220
    static let landscapeWidth: CGFloat = 360
    static let personWidth: CGFloat = 160
    static let heading: CGFloat = 28
    static let headingHeight: CGFloat = 44
    static let caption: CGFloat = 28
    static let secondary: CGFloat = 24
    static let captionHeight: CGFloat = 70
    static func heroHeight(_ width: CGFloat) -> CGFloat { width * 0.46875 }
    #else
    static let gutter: CGFloat = 17
    static let spacing: CGFloat = 13
    static let posterWidth: CGFloat = 116
    static let landscapeWidth: CGFloat = 177
    static let personWidth: CGFloat = 83
    static let heading: CGFloat = 16
    static let headingHeight: CGFloat = 32
    static let caption: CGFloat = 13
    static let secondary: CGFloat = 11
    static let captionHeight: CGFloat = 46
    static func heroHeight(_ width: CGFloat) -> CGFloat { width < 600 ? width * 1.5 : min(720, width * 0.65) }
    #endif
}

struct DiscoverRail<Content: View>: View {
    var arrowCenter: CGFloat? = nil
    @ViewBuilder let content: Content
    var body: some View {
        #if os(macOS)
        ScrollStrip(leftLabel: "Previous", rightLabel: "Next", overlayArrows: true, arrowCenter: arrowCenter) { content }
        #else
        ScrollView(.horizontal) { content }.scrollIndicators(.hidden)
        #endif
    }
}

struct DiscoverButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label
    @Environment(\.stripDrag) private var drag
    var body: some View { Button { if drag?.active != true { action() } } label: { label } }
}

struct DiscoverScrollKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct DiscoverScrollObserver: ViewModifier {
    @Binding var offset: CGFloat
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18, macOS 15, tvOS 18, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, value in offset = value }
        } else {
            content.onPreferenceChange(DiscoverScrollKey.self) { offset = $0 }
        }
    }
}

import SwiftUI
import Accelerate
import CoreImage
import ImageIO

/// A bounded, off-main-thread paint pass. The bottom of a cover gradually loses detail and
/// merges into its own colour, so the full-screen background and the scrolling shelves join.
struct DiscoverPaint: @unchecked Sendable {
    let image: CGImage
    let red: Double
    let green: Double
    let blue: Double
    var color: Color { Color(red: red, green: green, blue: blue) }
    var isDark: Bool { red * 0.2126 + green * 0.7152 + blue * 0.0722 < 0.58 }
}

actor DiscoverPainter {
    static let shared = DiscoverPainter()
    private lazy var context = CIContext(options: [.cacheIntermediates: false])
    private var cache: [String: DiscoverPaint] = [:]
    private var order: [String] = []
    private var pending: [String: Task<DiscoverPaint?, Never>] = [:]

    /// `headers` for a source's poster; `soft` blurs the whole cover, for a poster standing in for a backdrop (Watch Now's
    /// Up Next), whose sharp half would show its low resolution at the size of the screen.
    func paint(_ source: URL, headers: [String: String] = [:], soft: Bool = false) async -> DiscoverPaint? {
        let key = (soft ? "soft|" : "") + source.absoluteString
        if let cached = cache[key] { return cached }
        if let task = pending[key] { return await task.value }
        // Source posters are used as they are; no size upgrade is asked for.
        let url = source
        let task = Task { await self.render(url, headers: headers, soft: soft) }
        pending[key] = task
        let result = await task.value
        pending[key] = nil
        if let result {
            cache[key] = result
            order.append(key)
            if order.count > 12 { cache.removeValue(forKey: order.removeFirst()) }
        }
        return result
    }

    private func render(_ url: URL, headers: [String: String], soft: Bool) async -> DiscoverPaint? {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        let rgb = palette(decoded)
        #if os(iOS)
        // On Mac, Core Image can leave Metal's shared archive locked when the iOS app is suspended.
        if ProcessInfo.processInfo.isiOSAppOnMac {
            guard let result = Self.renderWithCoreGraphics(decoded, tint: rgb, soft: soft) else { return nil }
            return DiscoverPaint(image: result, red: rgb.0, green: rgb.1, blue: rgb.2)
        }
        #endif
        let image = CIImage(cgImage: decoded)
        let rect = image.extent
        let blurred = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: rect.width * (soft ? 0.09 : 0.055)]).cropped(to: rect)
        let mask = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: rect.height * 0.62),
            "inputPoint1": CIVector(x: 0, y: rect.height * 0.38),
            "inputColor0": CIColor.black, "inputColor1": CIColor.white,
        ])!.outputImage!.cropped(to: rect)
        let progressive = soft ? blurred : blurred.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask])
        let tint = CIColor(red: rgb.0, green: rgb.1, blue: rgb.2)
        let fade = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: rect.height * 0.52),
            "inputPoint1": CIVector(x: 0, y: rect.height * 0.015),
            "inputColor0": CIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 0),
            "inputColor1": tint,
        ])!.outputImage!.cropped(to: rect)
        let composited = fade.composited(over: progressive)
        guard let result = context.createCGImage(composited, from: rect) else { return nil }
        return DiscoverPaint(image: result, red: rgb.0, green: rgb.1, blue: rgb.2)
    }

    private static func renderWithCoreGraphics(_ image: CGImage, tint: (Double, Double, Double), soft: Bool) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        func bitmap(width: Int, height: Int) -> CGContext? {
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }

        let width = image.width, height = image.height
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        guard let blurred = Self.blurred(image, sigma: soft ? 0.09 : 0.055, space: colorSpace),
              let output = bitmap(width: width, height: height) else { return nil }
        output.interpolationQuality = .high

        func gradient(_ bottom: CGColor, _ top: CGColor, from lower: CGFloat, to upper: CGFloat) {
            guard let ramp = CGGradient(colorsSpace: colorSpace, colors: [bottom, top] as CFArray, locations: [0, 1]) else { return }
            output.drawLinearGradient(ramp, start: CGPoint(x: 0, y: rect.height * lower),
                                      end: CGPoint(x: 0, y: rect.height * upper),
                                      options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }

        if soft {
            output.draw(blurred, in: rect)
        } else {
            output.draw(image, in: rect)
            output.beginTransparencyLayer(auxiliaryInfo: nil)
            output.draw(blurred, in: rect)
            output.setBlendMode(.destinationIn)
            gradient(CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0), from: 0.38, to: 0.62)
            output.endTransparencyLayer()
        }

        let color = CGColor(srgbRed: tint.0, green: tint.1, blue: tint.2, alpha: 1)
        gradient(color, color.copy(alpha: 0) ?? color, from: 0.015, to: 0.52)
        return output.makeImage()
    }

    /// Core Image's Gaussian blur, on the CPU: a copy small enough to be quick, blurred with four box passes (as good as a
    /// Gaussian at this size), which the full-size draw then enlarges smoothly. Without the blur, a copy that small
    /// enlarged into visible squares. `sigma` is a fraction of the width, like the Core Image radius above.
    private static func blurred(_ image: CGImage, sigma: Double, space: CGColorSpace) -> CGImage? {
        let width = min(image.width, 192)
        let height = max(1, Int((Double(image.height) * Double(width) / Double(image.width)).rounded()))
        let rowBytes = width * 4
        guard let small = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: rowBytes,
                                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = small.data, let scratch = malloc(rowBytes * height) else { return nil }
        defer { free(scratch) }
        small.interpolationQuality = .high
        small.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // n passes of a box w pixels wide spread a pixel as far as a Gaussian with the variance n(w^2 - 1)/12.
        let deviation = Double(width) * sigma
        let box = UInt32((3 * deviation * deviation + 1).squareRoot().rounded()) | 1
        var picture = vImage_Buffer(data: pixels, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
        var spare = vImage_Buffer(data: scratch, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
        for _ in 0..<2 {
            // Edge-extended, as `clampedToExtent()` is for Core Image; every channel is blurred alike, alpha included.
            guard vImageBoxConvolve_ARGB8888(&picture, &spare, nil, 0, 0, box, box, nil, vImage_Flags(kvImageEdgeExtend)) == kvImageNoError,
                  vImageBoxConvolve_ARGB8888(&spare, &picture, nil, 0, 0, box, box, nil, vImage_Flags(kvImageEdgeExtend)) == kvImageNoError
            else { return nil }
        }
        return small.makeImage()
    }

    private func palette(_ image: CGImage) -> (Double, Double, Double) {
        let width = 24, height = 36
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let bitmap = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return (0.08, 0.08, 0.08)
        }
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        struct Bin { var weight = 0.0; var r = 0.0; var g = 0.0; var b = 0.0 }
        var bins: [Int: Bin] = [:]
        // CGContext's first row is the image's bottom. Prefer the lower half; ignore printed
        // white credits and near-black letterboxing when choosing a surrounding surface.
        for y in 0..<22 {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
                let high = max(r, g, b), low = min(r, g, b)
                guard high > 0.055, low < 0.88 else { continue }
                let saturation = high > 0 ? (high - low) / high : 0
                let weight = (0.35 + saturation * 1.65) * (1 - Double(y) / 45)
                let key = Int(r * 5) * 36 + Int(g * 5) * 6 + Int(b * 5)
                var bin = bins[key, default: Bin()]
                bin.weight += weight; bin.r += r * weight; bin.g += g * weight; bin.b += b * weight
                bins[key] = bin
            }
        }
        guard let dominant = bins.values.max(by: { $0.weight < $1.weight }), dominant.weight > 0 else { return (0.08, 0.08, 0.08) }
        return (dominant.r / dominant.weight, dominant.g / dominant.weight, dominant.b / dominant.weight)
    }
}

/// The hero's selection and artwork, read only by the hero and the backdrop: scrolling and paging must not evaluate the
/// rows again.
@MainActor @Observable final class WatchNowHeroState {
    var selected: String?
    var scrollY: CGFloat = 0
    var paints: [String: DiscoverPaint] = [:]
    var paint: DiscoverPaint? { selected.flatMap { paints[$0] } }

    /// Artwork for each title, two at a time, the shown one first: the title's own poster, blurred.
    /// Never a TMDB lookup (HAo Movie has no TMDB).
    func load(_ entries: [PlaybackHistoryEntry]) async {
        if selected == nil || !entries.contains(where: { $0.id == selected }) { selected = entries.first?.id }
        let missing = entries.filter { paints[$0.id] == nil }
        await withTaskGroup(of: (String, DiscoverPaint?).self) { group in
            var remaining = missing.makeIterator()
            func enqueue(_ entry: PlaybackHistoryEntry) {
                group.addTask {
                    // The phone's hero is portrait: a cover fills it, sharp at the top, as Discover's.
                    let paint: DiscoverPaint? = if let poster = entry.context.poster {
                        await DiscoverPainter.shared.paint(poster, headers: entry.context.posterHeaders ?? [:])
                    } else { nil }
                    return (entry.id, paint)
                }
            }
            for _ in 0..<2 { if let entry = remaining.next() { enqueue(entry) } }
            for await (id, paint) in group {
                guard !Task.isCancelled else { group.cancelAll(); break }
                if let paint { paints[id] = paint }
                if let entry = remaining.next() { enqueue(entry) }
            }
        }
    }
}

@MainActor @Observable final class WatchNowRows {
    static let shared = WatchNowRows()
    struct Row { var videos: [Video]; var date: Date }
    private(set) var rows: [String: Row] = [:]
    @ObservationIgnored private var loading: Set<String> = []

    static func key(category: String, client: CatalogClient) -> String { "\(client.origin)|\(client.site.key)|\(category)" }

    func load(category: String, client: CatalogClient) {
        let key = Self.key(category: category, client: client)
        if let row = rows[key], Date().timeIntervalSince(row.date) < 600 { return }
        guard loading.insert(key).inserted else { return }
        Task {
            defer { loading.remove(key) }
            do {
                // Rows of one plugin source start together (Discover starts four at once), and its queue turns
                // away calls past the few it holds: wait and ask again, or the row would be gone for ten minutes.
                let page = try await PluginQueue.retrying { try await client.list(category: category, query: "", page: 1) }
                var seen = Set<String>()
                let videos = page.videos.filter { seen.insert($0.id).inserted }
                if rows[key]?.videos != videos { rows[key] = Row(videos: videos, date: Date()) } else { rows[key]?.date = Date() }
            } catch {
                Diagnostics.shared.failure("catalog", "watch now row \(client.reportContext)", error)
                // Keep covers already shown; a row that never loaded goes away.
                if rows[key] == nil { rows[key] = Row(videos: [], date: Date()) }
            }
            if rows.count > 40, let oldest = rows.min(by: { $0.value.date < $1.value.date })?.key { rows[oldest] = nil }
        }
    }
}
