import Foundation

struct TeleprompterScriptMatcher {
    private struct Word {
        let value: String
        let range: NSRange
    }

    private static let wordsPattern = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+(?:['’][\\p{L}\\p{N}]+)*")
    private static let cuePattern = try! NSRegularExpression(pattern: "\\[[^\\[\\]]+\\]")
    private static let stageDirectionPattern = try! NSRegularExpression(
        pattern: "(?m)^[ \\t]*(?:\\*\\*)?(\\[[^\\[\\]]+\\])(?:\\*\\*)?[ \\t]*(?=\\r?$)"
    )
    private let words: [Word]
    let cues: [NSRange]
    private var nextWord = 0

    var nextSpokenWord: NSRange? {
        nextWord < words.count ? words[nextWord].range : nil
    }

    static func stageDirections(in script: String) -> [(line: NSRange, cue: NSRange)] {
        let length = (script as NSString).length
        return stageDirectionPattern.matches(in: script, range: NSRange(location: 0, length: length))
            .map { ($0.range, $0.range(at: 1)) }
    }

    init(script: String, at offset: Int = 0) {
        let length = (script as NSString).length
        let cues = Self.cuePattern.matches(in: script, range: NSRange(location: 0, length: length)).map(\.range)
        self.cues = cues
        words = Self.tokenize(script).filter { word in
            !cues.contains { NSLocationInRange(word.range.location, $0) }
        }
        nextWord = words.firstIndex { NSMaxRange($0.range) > offset } ?? words.count
    }

    /// Match a recent phrase near the reading position. A distant or repeated phrase needs
    /// more evidence than the next word, so incidental speech is less likely to skip ahead.
    mutating func advance(with phrase: String, isFinal: Bool = false) -> Int? {
        let spoken = Self.tokenize(phrase).suffix(8).map(\.value)
        guard let last = spoken.last, nextWord < words.count else { return nil }
        let limit = min(words.count, nextWord + 64)
        var best: (end: Int, count: Int)?
        var ambiguous = false

        for end in nextWord..<limit where words[end].value == last {
            var count = 1
            while count < spoken.count, count <= end,
                  words[end - count].value == spoken[spoken.count - count - 1] {
                count += 1
            }
            let distance = end - count + 1 - nextWord
            // Speech can finalise the last word as its own result after a pause.
            // Accept a single final word only at the current reading position.
            let required = end == nextWord && isFinal ? 1 : distance <= 0 ? 2 : distance <= 4 ? 3 : 4
            guard count >= required else { continue }
            if let current = best {
                if count < current.count { continue }
                if count == current.count {
                    // A phrase continuing from the current position takes priority
                    // over the same words elsewhere in the lookahead window.
                    if current.end - count + 1 <= nextWord { continue }
                    if distance > 0 {
                        ambiguous = true
                        continue
                    }
                }
            }
            best = (end, count)
            ambiguous = false
        }

        guard let best, !ambiguous else { return nil }
        nextWord = best.end + 1
        let endOffset = NSMaxRange(words[best.end].range)
        let nextOffset = nextWord < words.count ? words[nextWord].range.location : Int.max
        if let cue = cues.first(where: { $0.location >= endOffset && $0.location < nextOffset }) {
            return cue.location
        }
        return nextWord < words.count ? nextOffset : words[best.end].range.location
    }

    private static func tokenize(_ text: String) -> [Word] {
        let source = text as NSString
        return wordsPattern.matches(in: text, range: NSRange(location: 0, length: source.length)).map {
            let value = source.substring(with: $0.range)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en"))
                .replacingOccurrences(of: "’", with: "'")
            return Word(value: value, range: $0.range)
        }
    }
}
