import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// Translates subtitle lines on the device. The app provides one where Apple's Translation framework runs (iPhone,
/// iPad and Mac, from iOS 18 and macOS 15). Nothing is translated until a translation is asked for; then each
/// segment is translated as AVPlayer asks for it, a little ahead of the picture.
public protocol SubtitleTranslating: Sendable {
    /// The language subtitles are translated into: the app's.
    var target: Locale.Language { get }
    /// Whether the device translates `source` into `target`, now or once the languages are downloaded.
    func supports(_ source: Locale.Language) async -> Bool
    /// The lines in `target`, one for each, in order.
    func translate(_ lines: [String], from source: Locale.Language) async throws -> [String]
}

public enum SubtitleTranslation {
    /// The device's translator, set by the app at launch where it has one.
    public static var translator: (any SubtitleTranslating)? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: (any SubtitleTranslating)?

    /// How long a segment waits for its translation before it is served as it was: AVPlayer waits for it too.
    static let patience: Duration = .seconds(8)

    /// The language most of the cues' words are in, when that is clear.
    static func detect(_ cues: [SubtitleDocument.Cue]) -> Locale.Language? {
        #if canImport(NaturalLanguage)
        let sample = cues.prefix(80).map { plain($0.text) }.joined(separator: "\n")
        guard sample.count >= 20 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let (language, probability) = recognizer.languageHypotheses(withMaximum: 1).first, probability >= 0.6,
              language != .undetermined else { return nil }
        return Locale.Language(identifier: language.rawValue)
        #else
        return nil
        #endif
    }

    /// A cue's words without WebVTT markup: tags dropped, entities read.
    static func plain(_ text: String) -> String {
        text.replacing(/<[^>]*>/, with: "")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Translated words as WebVTT cue text.
    static func cueText(_ words: String) -> String? {
        let text = words.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\r\n", with: "\n").replacing(/\n{2,}/, with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The cues in the translator's language, timed as they were. When it fails, or takes longer than `patience`,
    /// they keep their words, and `translated` is false.
    static func translate(_ cues: [SubtitleDocument.Cue], from source: Locale.Language, with translator: any SubtitleTranslating,
                          patience: Duration = patience) async -> (cues: [SubtitleDocument.Cue], translated: Bool, error: String?) {
        let lines = cues.map { plain($0.text).trimmingCharacters(in: .whitespacesAndNewlines) }
        let wanted = lines.indices.filter { !lines[$0].isEmpty }
        guard !wanted.isEmpty else { return (cues, true, nil) }
        let outcome: Result<[String], Error>? = await withTaskGroup(of: Result<[String], Error>?.self) { group in
            group.addTask {
                do { return .success(try await translator.translate(wanted.map { lines[$0] }, from: source)) } catch { return .failure(error) }
            }
            group.addTask { try? await Task.sleep(for: patience); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        switch outcome {
        case .success(let words) where words.count == wanted.count:
            var translated = cues
            for (position, index) in wanted.enumerated() {
                if let text = cueText(words[position]) { translated[index].text = text }
            }
            return (translated, true, nil)
        case .success(let words): return (cues, false, "lines=\(wanted.count) answers=\(words.count)")
        case .failure(let error): return (cues, false, error.localizedDescription)
        case nil: return (cues, false, "no answer in \(patience)")
        }
    }

    /// The name a twin goes by in the Subtitles menu: "Chinese (Translated from English)".
    static func name(target: Locale.Language, source: Locale.Language) -> String {
        let locale = Locale(identifier: L10n.resolvedLanguage())
        let targetName = locale.localizedString(forIdentifier: target.minimalIdentifier) ?? target.minimalIdentifier
        let sourceName = source.languageCode.flatMap { locale.localizedString(forLanguageCode: $0.identifier) } ?? source.minimalIdentifier
        return L10n.text("%@ (Translated from %@)", targetName, sourceName)
    }
}
