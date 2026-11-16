import Foundation
import Speech

struct CaptionCue: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var start: Double
    var end: Double
    var text: String
}

enum TakeCaptions {
    static func sidecar(for video: URL) -> URL { video.deletingPathExtension().appendingPathExtension("catch-captions.json") }

    static func save(_ cues: [CaptionCue], for video: URL) throws {
        try JSONEncoder().encode(cues).write(to: sidecar(for: video), options: .atomic)
    }

    static func load(for video: URL) -> [CaptionCue]? {
        guard let data = try? Data(contentsOf: sidecar(for: video)) else { return nil }
        return try? JSONDecoder().decode([CaptionCue].self, from: data)
    }

    static func trimmed(_ cues: [CaptionCue], start: Double, end: Double) -> [CaptionCue] {
        cues.compactMap { cue in
            let left = max(start, cue.start), right = min(end, cue.end)
            guard right > left else { return nil }
            return CaptionCue(start: left - start, end: right - start, text: cue.text)
        }
    }

    static func srt(_ cues: [CaptionCue]) -> String {
        func timestamp(_ value: Double) -> String {
            let ms = max(0, Int((value * 1000).rounded()))
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
        }
        return cues.enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.start)) --> \(timestamp(cue.end))\n\(cue.text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }.joined(separator: "\n")
    }

    /// A portable transcript for notes, issue reports, and editing handoffs.
    static func transcript(_ cues: [CaptionCue]) -> String {
        cues.map { cue in
            let seconds = cue.start.isFinite && cue.start < Double(Int.max) ? Int(max(0, cue.start)) : 0
            let stamp = String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
            return "[\(stamp)] \(cue.text.trimmingCharacters(in: .whitespacesAndNewlines))"
        }.joined(separator: "\n")
    }

    static func webVTT(_ cues: [CaptionCue]) -> String {
        let escaped = cues.map { cue -> CaptionCue in
            var copy = cue
            copy.text = copy.text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
            return copy
        }
        let body = srt(escaped).components(separatedBy: "\n").map { line in
            line.contains(" --> ") ? line.replacingOccurrences(of: ",", with: ".") : line
        }.joined(separator: "\n")
        return "WEBVTT\n\n" + body
    }

    static func recognize(url: URL, completion: @escaping (Result<[CaptionCue], Error>) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else { completion(.failure(CaptionError.permission)); return }
            guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
                completion(.failure(CaptionError.unavailable)); return
            }
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = false
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let result = result, result.isFinal {
                    finished = true
                    let segments = result.bestTranscription.segments
                    // Group words into short readable captions, retaining their measured timing.
                    var cues: [CaptionCue] = []
                    for segment in segments {
                        let text = segment.substring
                        if let last = cues.last, segment.timestamp - last.start < 3.5,
                           last.text.count + text.count < 72, segment.timestamp - last.end < 0.8 {
                            cues[cues.count - 1].text += " " + text
                            cues[cues.count - 1].end = segment.timestamp + max(segment.duration, 0.1)
                        } else {
                            cues.append(CaptionCue(start: segment.timestamp, end: segment.timestamp + max(segment.duration, 0.1), text: text))
                        }
                    }
                    completion(.success(cues))
                } else if let error = error {
                    finished = true; completion(.failure(error))
                }
            }
        }
    }

    enum CaptionError: LocalizedError {
        case permission, unavailable
        var errorDescription: String? {
            switch self {
            case .permission: return "Speech recognition permission is unavailable. Allow Catch in System Settings → Privacy & Security → Speech Recognition."
            case .unavailable: return "On-device transcription is unavailable for the current language. Check macOS speech resources and try again."
            }
        }
    }
}
