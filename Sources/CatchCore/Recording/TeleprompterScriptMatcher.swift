import Foundation

/// Matches spoken transcripts against a teleprompter script using a hybrid
/// exact + fuzzy word aligner with lookahead distance gating, ambiguity checks,
/// confidence confirmation, and silent `[STAGE DIRECTION]` support.
///
/// Fuzzy word matching and CJK tokenization logic incorporates concepts adapted
/// from Textream (MIT License, Copyright (c) 2026 Fatih Kadir Akin).
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
    /// Sliding window of recent candidate word indices used to gate larger fuzzy jumps.
    private var recentCandidateEnds: [Int] = []

    var nextSpokenWord: NSRange? {
        nextWord < words.count ? words[nextWord].range : nil
    }

    /// UTF-16 character location up to which the script has been read.
    var completedCharacterOffset: Int {
        guard nextWord > 0 else { return 0 }
        let idx = min(nextWord - 1, words.count - 1)
        return NSMaxRange(words[idx].range)
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

    /// Reposition matching to an explicit UTF-16 character offset (e.g. after tapping a word).
    mutating func jump(to offset: Int) {
        nextWord = words.firstIndex { NSMaxRange($0.range) > offset } ?? words.count
        recentCandidateEnds.removeAll(keepingCapacity: true)
    }

    /// Match a recent phrase near the reading position.
    ///
    /// Supports both exact and Levenshtein/prefix fuzzy matching so speech-recognition
    /// substitutions do not stall tracking, while still requiring extra word context for
    /// distant jumps and holding on ambiguous repeated phrases.
    mutating func advance(with phrase: String, isFinal: Bool = false) -> Int? {
        let spoken = Self.tokenize(phrase).suffix(10).map(\.value)
        guard let last = spoken.last, nextWord < words.count else { return nil }
        let limit = min(words.count, nextWord + 64)

        struct Candidate {
            let end: Int
            let count: Int
            let exactCount: Int
            let distance: Int
        }

        var best: Candidate?
        var ambiguous = false

        for end in nextWord..<limit {
            let lastExact = words[end].value == last
            let lastFuzzy = lastExact || Self.isFuzzyMatch(words[end].value, last)
            guard lastFuzzy else { continue }

            var count = 1
            var exactCount = lastExact ? 1 : 0
            while count < spoken.count, count <= end {
                let srcWord = words[end - count].value
                let spkWord = spoken[spoken.count - count - 1]
                if srcWord == spkWord {
                    count += 1
                    exactCount += 1
                } else if Self.isFuzzyMatch(srcWord, spkWord) {
                    count += 1
                } else {
                    break
                }
            }

            let distance = end - count + 1 - nextWord
            // Speech can finalise the last word as its own result after a pause.
            // Accept a single final word only at the current reading position.
            let required: Int
            if end == nextWord && isFinal {
                required = 1
            } else if distance <= 0 {
                required = 2
            } else if distance <= 4 {
                required = 3
            } else {
                required = 4
            }
            guard count >= required else { continue }

            // Require at least one exact match or strong multi-word fuzzy agreement
            // so a distant jump cannot trigger on purely weak fuzzy hits.
            if distance > 2 && exactCount == 0 && count < required + 1 {
                continue
            }

            let candidate = Candidate(end: end, count: count, exactCount: exactCount, distance: distance)
            if let current = best {
                if candidate.count < current.count { continue }
                if candidate.count == current.count {
                    // A phrase continuing from the current position takes priority
                    // over the same words elsewhere in the lookahead window.
                    if current.end - current.count + 1 <= nextWord { continue }
                    if candidate.distance > 0 {
                        if candidate.exactCount > current.exactCount {
                            best = candidate
                            ambiguous = false
                        } else if candidate.exactCount == current.exactCount {
                            ambiguous = true
                        }
                        continue
                    }
                }
            }
            best = candidate
            ambiguous = false
        }

        guard let best, !ambiguous else { return nil }

        // Confidence gating for larger fuzzy-only jumps (> 6 words ahead with fuzzy edits):
        // require 2-of-3 recent candidates to agree within 3 words before committing.
        let isLargeFuzzyJump = best.distance > 6 && best.exactCount < best.count && !isFinal
        if isLargeFuzzyJump {
            recentCandidateEnds.append(best.end)
            if recentCandidateEnds.count > 3 {
                recentCandidateEnds.removeFirst()
            }
            let agreement = recentCandidateEnds.filter { abs($0 - best.end) <= 3 }.count
            guard agreement >= 2 else { return nil }
        } else {
            recentCandidateEnds.removeAll(keepingCapacity: true)
        }

        nextWord = best.end + 1
        let endOffset = NSMaxRange(words[best.end].range)
        let nextOffset = nextWord < words.count ? words[nextWord].range.location : Int.max
        if let cue = cues.first(where: { $0.location >= endOffset && $0.location < nextOffset }) {
            return cue.location
        }
        return nextWord < words.count ? nextOffset : words[best.end].range.location
    }

    /// Fuzzy word equality tolerant of common STT substitutions and minor inflections.
    /// Short words (<= 2 chars) must match exactly to prevent false jumps on "a"/"in"/"to".
    static func isFuzzyMatch(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let shorter = min(a.count, b.count)
        guard shorter >= 3 else { return false }

        // Prefix match for 4+ char stems (e.g., "record" / "recording", "catch" / "catcher")
        if shorter >= 4 && (a.hasPrefix(b) || b.hasPrefix(a)) {
            let longer = max(a.count, b.count)
            if shorter * 2 >= longer { return true }
        }

        // Shared prefix >= 60% of the shorter word (at least 3 chars) with bounded length delta
        let sharedPrefix = zip(a, b).prefix(while: { $0 == $1 }).count
        if sharedPrefix >= max(3, shorter * 3 / 5), abs(a.count - b.count) <= 3 {
            return true
        }

        // Levenshtein edit distance tolerance scaled to word length
        let dist = editDistance(a, b)
        if shorter <= 4 { return dist <= 1 }
        if shorter <= 8 { return dist <= 2 }
        return dist <= max(a.count, b.count) / 3
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let lhs = Array(a)
        let rhs = Array(b)
        guard !lhs.isEmpty else { return rhs.count }
        guard !rhs.isEmpty else { return lhs.count }
        var dp = Array(0...rhs.count)
        for i in 1...lhs.count {
            var prev = dp[0]
            dp[0] = i
            for j in 1...rhs.count {
                let temp = dp[j]
                dp[j] = lhs[i - 1] == rhs[j - 1] ? prev : min(prev, dp[j], dp[j - 1]) + 1
                prev = temp
            }
        }
        return dp[rhs.count]
    }

    /// Upcoming vocabulary hints (5+ letter unique words) for speech recognition biasing.
    static func contextualVocabulary(in script: String, from offset: Int = 0, limit: Int = 50) -> [String] {
        let matcher = TeleprompterScriptMatcher(script: script, at: offset)
        var seen = Set<String>()
        var result: [String] = []
        for word in matcher.words.dropFirst(matcher.nextWord) {
            let token = word.value
            guard token.count >= 5, seen.insert(token).inserted else { continue }
            result.append(token)
            if result.count >= limit { break }
        }
        return result
    }

    private static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (v >= 0x4E00 && v <= 0x9FFF)
            || (v >= 0x3400 && v <= 0x4DBF)
            || (v >= 0x20000 && v <= 0x2A6DF)
            || (v >= 0xF900 && v <= 0xFAFF)
            || (v >= 0x3040 && v <= 0x309F)
            || (v >= 0x30A0 && v <= 0x30FF)
            || (v >= 0xAC00 && v <= 0xD7AF)
    }

    private static func tokenize(_ text: String) -> [Word] {
        let source = text as NSString
        var output: [Word] = []
        for match in wordsPattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let raw = source.substring(with: match.range)
            if raw.unicodeScalars.contains(where: isCJKScalar) {
                var utf16Offset = match.range.location
                var nonCJKStart: Int?
                var nonCJKBuffer = ""
                for char in raw {
                    let charLen = (String(char) as NSString).length
                    let isCJK = char.unicodeScalars.first.map(isCJKScalar) ?? false
                    if isCJK {
                        if let start = nonCJKStart, !nonCJKBuffer.isEmpty {
                            output.append(Word(
                                value: normalize(nonCJKBuffer),
                                range: NSRange(location: start, length: utf16Offset - start)
                            ))
                            nonCJKStart = nil
                            nonCJKBuffer = ""
                        }
                        output.append(Word(
                            value: normalize(String(char)),
                            range: NSRange(location: utf16Offset, length: charLen)
                        ))
                    } else {
                        if nonCJKStart == nil { nonCJKStart = utf16Offset }
                        nonCJKBuffer.append(char)
                    }
                    utf16Offset += charLen
                }
                if let start = nonCJKStart, !nonCJKBuffer.isEmpty {
                    output.append(Word(
                        value: normalize(nonCJKBuffer),
                        range: NSRange(location: start, length: utf16Offset - start)
                    ))
                }
            } else {
                output.append(Word(value: normalize(raw), range: match.range))
            }
        }
        return output
    }

    private static func normalize(_ token: String) -> String {
        token
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en"))
            .replacingOccurrences(of: "’", with: "'")
    }
}
