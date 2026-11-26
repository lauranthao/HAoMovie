import Foundation

/// A source name split for display: a leading emoji as `symbol`, the words as
/// `parts`, and the plain name as `text`. A name with no leading emoji has no
/// symbol; its first word still seeds the monogram tile.
struct SourceLabel {
    let text: String
    let parts: [String]
    let symbol: String?

    init(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var symbol: String?
        var rest = trimmed
        if let first = trimmed.first, Self.isEmoji(String(first)) {
            symbol = String(first)
            rest = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        self.symbol = symbol
        self.text = rest.isEmpty ? trimmed : rest
        let words = self.text.split(separator: " ").map(String.init)
        self.parts = words.isEmpty ? [self.text] : words
    }

    private static func isEmoji(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.properties.isEmoji }
    }
}
