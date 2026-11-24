import AVFoundation
import Foundation
import Speech

struct CaptionCue: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var start: Double
    var end: Double
    var text: String
}

struct TimedSegment: Equatable {
    var start: Double
    var duration: Double
    var text: String

    var end: Double { start + max(duration, 0.1) }
}

struct AudioChunk: Equatable {
    var startSample: Int
    var endSample: Int
    var sampleRate: Double

    var startTime: Double { Double(startSample) / sampleRate }
    var duration: Double { Double(endSample - startSample) / sampleRate }
}

/// Accumulates `SFSpeechRecognizer` callbacks across silence-induced utterance resets
/// without duplicating revised partial hypotheses from the same utterance.
struct UtteranceAccumulator {
    private(set) var committed: [TimedSegment] = []
    private(set) var active: [TimedSegment] = []
    private var fallbackText: String?

    var hasTimedSegments: Bool { !committed.isEmpty || !active.isEmpty }

    mutating func ingest(_ segments: [TimedSegment], fallbackText: String? = nil) {
        let cleaned = segments.compactMap { segment -> TimedSegment? in
            let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return TimedSegment(start: max(0, segment.start), duration: max(0, segment.duration), text: trimmed)
        }

        // Empty callbacks can occur when the on-device recognizer flushes between utterances.
        // Commit the active utterance rather than discarding it.
        if cleaned.isEmpty {
            if !active.isEmpty {
                committed.append(contentsOf: active)
                active.removeAll()
            }
            return
        }

        // Partial results on macOS sometimes report timestamp == 0 and duration == 0
        // until timing is finalized. Never commit untimed partials as t=0 utterances.
        let hasTiming = cleaned.contains { $0.start > 0 || $0.duration > 0 }
        if !hasTiming {
            let text = (fallbackText ?? cleaned.map(\.text).joined(separator: " "))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { self.fallbackText = text }
            return
        }

        self.fallbackText = nil
        let incoming = cleaned.sorted { $0.start < $1.start }
        let incomingStart = incoming[0].start

        if !active.isEmpty {
            let activeStart = active[0].start
            let activeEnd = active.map(\.end).max() ?? activeStart

            if incomingStart >= activeEnd - 0.15 {
                // Non-overlapping new utterance after a pause/reset: preserve previous utterance.
                committed.append(contentsOf: active)
            } else if incomingStart > activeStart + 1.0 {
                // Sliding-window trim of the front of a long utterance: preserve non-overlapping prefix.
                let prefix = active.filter { $0.end <= incomingStart - 0.05 }
                committed.append(contentsOf: prefix)
            }
            // Otherwise incoming revises the same active utterance and replaces it cleanly.
        }

        // If a later callback retroactively re-includes an already committed span, drop the
        // overlapping committed tail so we never emit duplicate words.
        committed.removeAll { $0.start >= incomingStart - 0.05 || $0.end > incomingStart + 0.05 }
        active = incoming
    }

    mutating func finish(fallbackDuration: Double = 0.5) -> [TimedSegment] {
        if !active.isEmpty {
            committed.append(contentsOf: active)
            active.removeAll()
        }
        if committed.isEmpty, let fallbackText, !fallbackText.isEmpty {
            return [TimedSegment(start: 0, duration: max(fallbackDuration, 0.1), text: fallbackText)]
        }
        return committed.sorted { $0.start < $1.start }
    }
}

enum TakeCaptions {
    static let recognitionSampleRate: Double = 16_000

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

    static func shiftSegments(_ segments: [TimedSegment], by offset: Double) -> [TimedSegment] {
        segments.map { TimedSegment(start: $0.start + offset, duration: $0.duration, text: $0.text) }
    }

    static func buildCues(from segments: [TimedSegment]) -> [CaptionCue] {
        let ordered = segments
            .compactMap { segment -> TimedSegment? in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return TimedSegment(start: max(0, segment.start), duration: max(0, segment.duration), text: text)
            }
            .sorted { $0.start < $1.start }

        // Group words into short readable captions, retaining their measured timing.
        var cues: [CaptionCue] = []
        for segment in ordered {
            let segEnd = segment.end
            if let last = cues.last,
               segment.start - last.start < 3.5,
               last.text.count + segment.text.count < 72,
               segment.start - last.end < 0.8 {
                cues[cues.count - 1].text += " " + segment.text
                cues[cues.count - 1].end = max(last.end, segEnd)
            } else {
                if let last = cues.last, segment.start > last.start, last.end > segment.start {
                    cues[cues.count - 1].end = segment.start
                }
                cues.append(CaptionCue(start: segment.start, end: segEnd, text: segment.text))
            }
        }
        return cues
    }

    /// Mixes all non-silent mono audio tracks into a single peak-safe mono track.
    /// Dropping completely silent tracks (e.g. silent system audio alongside a live mic)
    /// keeps the spoken track at full level, while summing active tracks preserves both
    /// system-audio speech and microphone narration.
    static func mixAudioTracks(_ tracks: [[Float]]) -> [Float] {
        let active = tracks.filter { samples in
            samples.contains { abs($0) >= 1e-4 }
        }
        guard !active.isEmpty else { return [] }
        if active.count == 1 { return active[0] }

        let maxLength = active.map(\.count).max() ?? 0
        var mixed = [Float](repeating: 0, count: maxLength)
        for track in active {
            for i in 0..<track.count {
                mixed[i] += track[i]
            }
        }
        var peak: Float = 0
        for sample in mixed {
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
        }
        if peak > 0.95 {
            let scale = 0.95 / peak
            for i in 0..<mixed.count {
                mixed[i] *= scale
            }
        }
        return mixed
    }

    /// Splits mono audio at quiet pauses and enforces a maximum window length so each
    /// on-device `SFSpeechURLRecognitionRequest` stays within a single clean utterance
    /// window and retains accurate word timestamps.
    static func planAudioChunks(
        samples: [Float],
        sampleRate: Double = recognitionSampleRate,
        minSilenceDuration: Double = 0.7,
        minChunkDuration: Double = 1.5,
        maxChunkDuration: Double = 25.0
    ) -> [AudioChunk] {
        guard !samples.isEmpty, sampleRate > 0 else { return [] }
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        guard peak >= 1e-4 else { return [] }

        let totalSamples = samples.count
        let frameSamples = max(1, Int((0.1 * sampleRate).rounded()))
        var frameDB: [Double] = []
        frameDB.reserveCapacity((totalSamples + frameSamples - 1) / frameSamples)

        var idx = 0
        while idx < totalSamples {
            let end = min(totalSamples, idx + frameSamples)
            var sumSq: Double = 0
            for i in idx..<end {
                let v = Double(samples[i])
                sumSq += v * v
            }
            let rms = sqrt(sumSq / Double(end - idx))
            frameDB.append(20.0 * log10(max(rms, 1e-9)))
            idx = end
        }

        let sorted = frameDB.sorted()
        let count = sorted.count
        let p10 = max(sorted[count / 10], -70.0)
        let p90 = sorted[min(count - 1, (count * 9) / 10)]
        let spread = p90 - p10

        var boundaries: [Int] = [0]
        let minSilenceFrames = max(1, Int((minSilenceDuration / 0.1).rounded()))
        let minChunkSamples = Int((minChunkDuration * sampleRate).rounded())
        let minActiveFramesPerSide = 3

        if spread >= 8.0 {
            let threshold = max(p10 + 6.0, min(p90 - 12.0, (p10 + p90) * 0.5))
            let isQuiet = frameDB.map { $0 < threshold }

            var frame = 0
            while frame < isQuiet.count {
                if isQuiet[frame] {
                    var endFrame = frame
                    while endFrame < isQuiet.count && isQuiet[endFrame] {
                        endFrame += 1
                    }
                    if endFrame - frame >= minSilenceFrames {
                        let midFrame = (frame + endFrame) / 2
                        let splitSample = min(totalSamples, midFrame * frameSamples)
                        let prevBoundaryFrame = boundaries.last! / frameSamples
                        let activeBefore = (prevBoundaryFrame..<frame).reduce(0) { $0 + (isQuiet[$1] ? 0 : 1) }
                        let activeAfter = (endFrame..<isQuiet.count).reduce(0) { $0 + (isQuiet[$1] ? 0 : 1) }
                        if activeBefore >= minActiveFramesPerSide,
                           activeAfter >= minActiveFramesPerSide,
                           splitSample - boundaries.last! >= minChunkSamples,
                           totalSamples - splitSample >= minChunkSamples {
                            boundaries.append(splitSample)
                        }
                    }
                    frame = endFrame
                } else {
                    frame += 1
                }
            }
        }
        boundaries.append(totalSamples)

        let maxChunkSamples = max(minChunkSamples * 2, Int((maxChunkDuration * sampleRate).rounded()))
        var finalChunks: [AudioChunk] = []
        for i in 0..<(boundaries.count - 1) {
            var chunkStart = boundaries[i]
            let chunkEnd = boundaries[i + 1]
            while chunkEnd - chunkStart > maxChunkSamples {
                let searchStartSample = chunkStart + Int((Double(maxChunkSamples) * 0.6).rounded())
                let searchEndSample = min(chunkEnd - minChunkSamples, chunkStart + maxChunkSamples)
                if searchEndSample <= searchStartSample {
                    let hardSplit = min(chunkEnd, chunkStart + maxChunkSamples)
                    finalChunks.append(AudioChunk(startSample: chunkStart, endSample: hardSplit, sampleRate: sampleRate))
                    chunkStart = hardSplit
                    continue
                }
                let startFrame = max(0, searchStartSample / frameSamples)
                let endFrame = min(frameDB.count - 1, searchEndSample / frameSamples)
                var bestFrame = startFrame
                var lowestDB = frameDB[startFrame]
                if startFrame <= endFrame {
                    for f in startFrame...endFrame where frameDB[f] < lowestDB {
                        lowestDB = frameDB[f]
                        bestFrame = f
                    }
                }
                let splitSample = max(chunkStart + minChunkSamples, min(chunkEnd - minChunkSamples, bestFrame * frameSamples))
                finalChunks.append(AudioChunk(startSample: chunkStart, endSample: splitSample, sampleRate: sampleRate))
                chunkStart = splitSample
            }
            if chunkEnd > chunkStart {
                finalChunks.append(AudioChunk(startSample: chunkStart, endSample: chunkEnd, sampleRate: sampleRate))
            }
        }
        return finalChunks
    }

    static let maxLeadingGapSeconds: Double = 120.0
    static let maxSingleGapSeconds: Double = 60.0
    static let maxExtractedDurationSeconds: Double = 3 * 3600.0

    static func extractMixedMonoAudio(from url: URL, sampleRate: Double = recognitionSampleRate) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { return [] }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        var decodedTracks: [[Float]] = []
        decodedTracks.reserveCapacity(audioTracks.count)
        let maxSingleGapSamples = max(1, Int((maxSingleGapSeconds * sampleRate).rounded()))
        let maxTotalSamples = max(1, Int((maxExtractedDurationSeconds * sampleRate).rounded()))

        for track in audioTracks {
            let reader = try AVAssetReader(asset: asset)
            var trackOriginSeconds: Double = 0
            if let segments = try? await track.load(.segments),
               let firstNonEmpty = segments.first(where: { !$0.isEmpty }) {
                let targetStart = firstNonEmpty.timeMapping.target.start
                if targetStart.isValid && targetStart.isNumeric && targetStart.seconds > maxLeadingGapSeconds {
                    reader.timeRange = CMTimeRange(start: targetStart, duration: .positiveInfinity)
                    trackOriginSeconds = targetStart.seconds
                }
            }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { continue }
            reader.add(output)
            guard reader.startReading() else {
                if let error = reader.error { throw error }
                continue
            }

            var samples: [Float] = []
            let gapThresholdSamples = max(1, Int((0.02 * sampleRate).rounded()))

            while let sampleBuffer = output.copyNextSampleBuffer() {
                if samples.count >= maxTotalSamples { break }
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                if pts.isValid && pts.seconds.isFinite && pts.seconds > 0 {
                    // Guard against corrupt/empty leading edit segments (e.g. mismatched clock epochs)
                    // so we never allocate gigabytes of leading silence.
                    if samples.isEmpty && pts.seconds > maxLeadingGapSeconds {
                        trackOriginSeconds = pts.seconds
                    }
                    let adjustedSeconds = pts.seconds - trackOriginSeconds
                    if adjustedSeconds > 0 && adjustedSeconds < maxExtractedDurationSeconds {
                        let expectedIndex = min(maxTotalSamples, Int((adjustedSeconds * sampleRate).rounded()))
                        let gap = expectedIndex - samples.count
                        if gap > maxSingleGapSamples {
                            trackOriginSeconds += Double(gap) / sampleRate
                        } else if gap > gapThresholdSamples {
                            samples.append(contentsOf: repeatElement(Float(0), count: gap))
                        }
                    }
                }
                guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
                let byteLength = CMBlockBufferGetDataLength(blockBuffer)
                guard byteLength > 0 else { continue }
                let floatCount = byteLength / MemoryLayout<Float>.size
                guard floatCount > 0 else { continue }
                var buffer = [Float](repeating: 0, count: floatCount)
                let status = buffer.withUnsafeMutableBytes { ptr in
                    CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: byteLength, destination: ptr.baseAddress!)
                }
                if status == kCMBlockBufferNoErr {
                    let remaining = maxTotalSamples - samples.count
                    if remaining <= 0 { break }
                    if buffer.count <= remaining {
                        samples.append(contentsOf: buffer)
                    } else {
                        samples.append(contentsOf: buffer.prefix(remaining))
                    }
                }
            }

            if reader.status == .failed, let error = reader.error {
                throw error
            }
            if !samples.isEmpty {
                decodedTracks.append(samples)
            }
        }

        return mixAudioTracks(decodedTracks)
    }

    static func writeWAV(samples: ArraySlice<Float>, sampleRate: Double = recognitionSampleRate, to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw CaptionError.audioExtractionFailed
        }
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: fileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frameCapacity: AVAudioFrameCount = 32_768
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity),
              let channelData = pcmBuffer.floatChannelData?[0] else {
            throw CaptionError.audioExtractionFailed
        }

        var cursor = samples.startIndex
        while cursor < samples.endIndex {
            let count = min(Int(frameCapacity), samples.endIndex - cursor)
            pcmBuffer.frameLength = AVAudioFrameCount(count)
            for i in 0..<count {
                channelData[i] = max(-1.0, min(1.0, samples[cursor + i]))
            }
            try file.write(from: pcmBuffer)
            cursor += count
        }
    }

    static func isNoSpeechError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110 {
            return true
        }
        return nsError.localizedDescription.lowercased().contains("no speech detected")
    }

    private static func recognizeChunk(
        url: URL,
        offset: Double,
        duration: Double,
        recognizer: SFSpeechRecognizer
    ) async throws -> [TimedSegment] {
        try await withCheckedThrowingContinuation { continuation in
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            request.addsPunctuation = true

            let lock = NSLock()
            var accumulator = UtteranceAccumulator()
            var finished = false
            var activeTask: SFSpeechRecognitionTask?
            let timeoutSeconds = max(45.0, min(180.0, duration * 4.0))

            let timeoutWork = DispatchWorkItem {
                lock.lock()
                guard !finished else {
                    lock.unlock()
                    return
                }
                finished = true
                let taskToCancel = activeTask
                activeTask = nil
                let hasTimed = accumulator.hasTimedSegments
                let finalized = hasTimed ? accumulator.finish(fallbackDuration: duration) : []
                lock.unlock()
                taskToCancel?.cancel()
                if hasTimed {
                    continuation.resume(returning: shiftSegments(finalized, by: offset))
                } else {
                    continuation.resume(throwing: CaptionError.timedOut)
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutWork)

            let task = recognizer.recognitionTask(with: request) { result, error in
                lock.lock()
                guard !finished else {
                    lock.unlock()
                    return
                }

                if let result = result {
                    let segments = result.bestTranscription.segments.map {
                        TimedSegment(start: $0.timestamp, duration: $0.duration, text: $0.substring)
                    }
                    accumulator.ingest(segments, fallbackText: result.bestTranscription.formattedString)

                    if result.isFinal {
                        finished = true
                        activeTask = nil
                        let finalized = accumulator.finish(fallbackDuration: duration)
                        lock.unlock()
                        timeoutWork.cancel()
                        continuation.resume(returning: shiftSegments(finalized, by: offset))
                        return
                    }
                }

                if let error = error {
                    finished = true
                    activeTask = nil
                    let hasTimed = accumulator.hasTimedSegments
                    let finalized = hasTimed ? accumulator.finish(fallbackDuration: duration) : []
                    lock.unlock()
                    timeoutWork.cancel()
                    if hasTimed {
                        continuation.resume(returning: shiftSegments(finalized, by: offset))
                    } else if isNoSpeechError(error) {
                        continuation.resume(returning: [])
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }

                lock.unlock()
            }

            lock.lock()
            if finished {
                lock.unlock()
                task.cancel()
            } else {
                activeTask = task
                lock.unlock()
            }
        }
    }

    static func recognize(url: URL, completion: @escaping (Result<[CaptionCue], Error>) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else { completion(.failure(CaptionError.permission)); return }
            guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
                completion(.failure(CaptionError.unavailable)); return
            }

            Task.detached(priority: .userInitiated) {
                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("catch-captions-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: tempDir) }

                do {
                    let monoSamples = try await extractMixedMonoAudio(from: url)
                    let chunks = planAudioChunks(samples: monoSamples)
                    guard !chunks.isEmpty else {
                        completion(.success([]))
                        return
                    }

                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    var allSegments: [TimedSegment] = []

                    for (index, chunk) in chunks.enumerated() {
                        let chunkURL = tempDir.appendingPathComponent("chunk-\(index).wav")
                        try writeWAV(samples: monoSamples[chunk.startSample..<chunk.endSample], sampleRate: chunk.sampleRate, to: chunkURL)
                        let chunkSegments = try await recognizeChunk(
                            url: chunkURL,
                            offset: chunk.startTime,
                            duration: chunk.duration,
                            recognizer: recognizer
                        )
                        allSegments.append(contentsOf: chunkSegments)
                    }

                    completion(.success(buildCues(from: allSegments)))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    enum CaptionError: LocalizedError {
        case permission, unavailable, audioExtractionFailed, timedOut
        var errorDescription: String? {
            switch self {
            case .permission: return "Speech recognition permission is unavailable. Allow Catch in System Settings → Privacy & Security → Speech Recognition."
            case .unavailable: return "On-device transcription is unavailable for the current language. Check macOS speech resources and try again."
            case .audioExtractionFailed: return "Could not prepare audio from this recording for transcription."
            case .timedOut: return "On-device transcription timed out. Retry or check macOS Speech Recognition settings."
            }
        }
    }
}
