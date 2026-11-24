import AVFoundation
import XCTest
@testable import CatchCore

final class TakeCaptionsTests: XCTestCase {
    func testTrimClipsAndShiftsCuesAndFormatsSRT() {
        let cues = [CaptionCue(start: 1, end: 3, text: "First"),
                    CaptionCue(start: 4, end: 6, text: "Second"),
                    CaptionCue(start: 7, end: 8, text: "Outside")]
        let trimmed = TakeCaptions.trimmed(cues, start: 2, end: 5)
        XCTAssertEqual(trimmed.map(\.start), [0, 2])
        XCTAssertEqual(trimmed.map(\.end), [1, 3])
        XCTAssertEqual(TakeCaptions.srt(trimmed), "1\n00:00:00,000 --> 00:00:01,000\nFirst\n\n2\n00:00:02,000 --> 00:00:03,000\nSecond\n")
    }

    func testUtteranceAccumulatorPreservesEarlierSentencesAcrossSilenceResetsWithoutDuplicates() {
        var accumulator = UtteranceAccumulator()

        // Utterance 1 (0–8s): progressive partial revisions of the same utterance
        accumulator.ingest([
            TimedSegment(start: 2.0, duration: 0.4, text: "Welcome"),
            TimedSegment(start: 2.5, duration: 0.3, text: "to")
        ])
        accumulator.ingest([
            TimedSegment(start: 2.0, duration: 0.4, text: "Welcome"),
            TimedSegment(start: 2.45, duration: 0.25, text: "to"),
            TimedSegment(start: 2.8, duration: 0.5, text: "Catch"),
            TimedSegment(start: 7.1, duration: 0.7, text: "studio.")
        ])

        // Recognizer flushes empty result during pause
        accumulator.ingest([])

        // Utterance 2 (11–14s): starts after silence reset, revised once
        accumulator.ingest([
            TimedSegment(start: 11.0, duration: 0.4, text: "Here"),
            TimedSegment(start: 11.5, duration: 0.3, text: "is"),
            TimedSegment(start: 11.9, duration: 0.5, text: "demo")
        ])
        accumulator.ingest([
            TimedSegment(start: 11.0, duration: 0.4, text: "Here"),
            TimedSegment(start: 11.5, duration: 0.3, text: "is"),
            TimedSegment(start: 11.9, duration: 0.4, text: "our"),
            TimedSegment(start: 13.3, duration: 0.6, text: "demo.")
        ])

        // Utterance 3 (16.62–19.29s): final callback only contains the last utterance
        accumulator.ingest([
            TimedSegment(start: 16.62, duration: 0.4, text: "Thank"),
            TimedSegment(start: 17.05, duration: 0.3, text: "you"),
            TimedSegment(start: 17.4, duration: 0.3, text: "for"),
            TimedSegment(start: 17.75, duration: 0.5, text: "watching"),
            TimedSegment(start: 18.8, duration: 0.49, text: "recording.")
        ])

        let segments = accumulator.finish()
        let cues = TakeCaptions.buildCues(from: segments)

        XCTAssertEqual(segments.map(\.text), [
            "Welcome", "to", "Catch", "studio.",
            "Here", "is", "our", "demo.",
            "Thank", "you", "for", "watching", "recording."
        ])
        XCTAssertTrue(cues.contains { $0.start >= 1.9 && $0.text.contains("Welcome") })
        XCTAssertTrue(cues.contains { $0.start >= 10.9 && $0.text.contains("Here is our") })
        XCTAssertTrue(cues.contains { $0.start >= 16.6 && $0.text.contains("Thank you for watching") })
    }

    func testUtteranceAccumulatorIgnoresUntimedPartialsOnceTimedSegmentsArrive() {
        var accumulator = UtteranceAccumulator()

        // Untimed partial hypotheses (timestamp == 0, duration == 0)
        accumulator.ingest([
            TimedSegment(start: 0, duration: 0, text: "Thank"),
            TimedSegment(start: 0, duration: 0, text: "you")
        ], fallbackText: "Thank you")

        // Final timed result
        accumulator.ingest([
            TimedSegment(start: 16.62, duration: 0.35, text: "Thank"),
            TimedSegment(start: 17.0, duration: 0.25, text: "you.")
        ])

        let segments = accumulator.finish()
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].start, 16.62, accuracy: 0.001)
        XCTAssertEqual(segments.map(\.text), ["Thank", "you."])
    }

    func testUtteranceAccumulatorPreservesSlidingWindowPrefixAndDeduplicatesRetroactiveOverlap() {
        var accumulator = UtteranceAccumulator()

        accumulator.ingest([
            TimedSegment(start: 1.0, duration: 0.5, text: "One"),
            TimedSegment(start: 2.0, duration: 0.5, text: "two"),
            TimedSegment(start: 3.5, duration: 0.5, text: "three")
        ])

        // Sliding window drops "One" and "two" while advancing past 3.5s
        accumulator.ingest([
            TimedSegment(start: 3.5, duration: 0.5, text: "three"),
            TimedSegment(start: 4.2, duration: 0.5, text: "four")
        ])

        // Retroactive callback re-emits from 2.0s onward; should not duplicate "two" or "three"
        accumulator.ingest([
            TimedSegment(start: 2.0, duration: 0.5, text: "two"),
            TimedSegment(start: 3.5, duration: 0.5, text: "three"),
            TimedSegment(start: 4.2, duration: 0.5, text: "four"),
            TimedSegment(start: 5.0, duration: 0.5, text: "five")
        ])

        let segments = accumulator.finish()
        XCTAssertEqual(segments.map(\.text), ["One", "two", "three", "four", "five"])
    }

    func testMixAudioTracksPreservesMicWhenSystemTrackIsSilentAndPreventsClipping() {
        let silentSystem = [Float](repeating: 0, count: 1600)
        let micSpeech = (0..<1600).map { Float(sin(Double($0) * 0.1)) * 0.6 }

        // Silent system track must be ignored so mic track retains full level
        let micOnlyMix = TakeCaptions.mixAudioTracks([silentSystem, micSpeech])
        XCTAssertEqual(micOnlyMix.count, micSpeech.count)
        XCTAssertEqual(micOnlyMix[10], micSpeech[10], accuracy: 1e-5)

        // Two loud active tracks must be summed and peak-limited to <= 0.95
        let loudSystem = (0..<1600).map { Float(sin(Double($0) * 0.1)) * 0.8 }
        let loudMix = TakeCaptions.mixAudioTracks([loudSystem, micSpeech])
        let peak = loudMix.reduce(Float(0)) { max($0, abs($1)) }
        XCTAssertLessThanOrEqual(peak, 0.9501)
        XCTAssertGreaterThan(peak, 0.9)

        // All silent tracks return empty
        XCTAssertTrue(TakeCaptions.mixAudioTracks([silentSystem, silentSystem]).isEmpty)
    }

    func testPlanAudioChunksSplitsAtPausesAndMergesChunkOffsetsAccurately() {
        let sampleRate = TakeCaptions.recognitionSampleRate
        let totalSamples = Int(20.0 * sampleRate)
        var samples = [Float](repeating: 0, count: totalSamples)

        // Low ambient noise floor (~-28 dB) across entire clip, matching noisy mic floor
        for i in 0..<totalSamples {
            samples[i] = Float(sin(Double(i) * 0.037)) * 0.04
        }
        // Add three spoken-level tone bursts (~-11 dB) at 2.0–7.8s, 10.0–13.5s, 16.6–19.3s
        func addBurst(start: Double, end: Double, amplitude: Float = 0.4) {
            let s = Int(start * sampleRate)
            let e = min(totalSamples, Int(end * sampleRate))
            for i in s..<e {
                samples[i] += Float(sin(Double(i) * 0.18)) * amplitude
            }
        }
        addBurst(start: 2.0, end: 7.8)
        addBurst(start: 10.0, end: 13.5)
        addBurst(start: 16.6, end: 19.3)

        let chunks = TakeCaptions.planAudioChunks(samples: samples, sampleRate: sampleRate)
        XCTAssertEqual(chunks.count, 3, "Expected 3 chunks around the two pauses, got \(chunks)")
        XCTAssertEqual(chunks.first?.startSample, 0)
        XCTAssertEqual(chunks.last?.endSample, totalSamples)

        // Simulate chunk-local recognition results shifted by each chunk's startTime
        let localPerChunk: [[TimedSegment]] = [
            [TimedSegment(start: 2.0, duration: 0.6, text: "First"),
             TimedSegment(start: 2.7, duration: 0.7, text: "sentence.")],
            [TimedSegment(start: 10.0 - chunks[1].startTime, duration: 0.5, text: "Second"),
             TimedSegment(start: 10.6 - chunks[1].startTime, duration: 0.7, text: "sentence.")],
            [TimedSegment(start: 16.62 - chunks[2].startTime, duration: 0.5, text: "Final"),
             TimedSegment(start: 17.2 - chunks[2].startTime, duration: 0.8, text: "sentence.")]
        ]

        var merged: [TimedSegment] = []
        for (chunk, local) in zip(chunks, localPerChunk) {
            merged.append(contentsOf: TakeCaptions.shiftSegments(local, by: chunk.startTime))
        }

        let cues = TakeCaptions.buildCues(from: merged)
        XCTAssertEqual(cues.count, 3)
        XCTAssertEqual(cues[0].text, "First sentence.")
        XCTAssertEqual(cues[0].start, 2.0, accuracy: 0.05)
        XCTAssertEqual(cues[1].text, "Second sentence.")
        XCTAssertEqual(cues[1].start, 10.0, accuracy: 0.05)
        XCTAssertEqual(cues[2].text, "Final sentence.")
        XCTAssertEqual(cues[2].start, 16.62, accuracy: 0.05)
    }

    func testPlanAudioChunksEnforcesMaxChunkDurationOnContinuousAudio() {
        let sampleRate = TakeCaptions.recognitionSampleRate
        let totalSamples = Int(60.0 * sampleRate)
        let continuous = (0..<totalSamples).map { Float(sin(Double($0) * 0.15)) * 0.35 }

        let chunks = TakeCaptions.planAudioChunks(samples: continuous, sampleRate: sampleRate, maxChunkDuration: 25.0)
        XCTAssertGreaterThanOrEqual(chunks.count, 3)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.duration, 25.05)
        }
        XCTAssertEqual(chunks.first?.startSample, 0)
        XCTAssertEqual(chunks.last?.endSample, totalSamples)
    }

    func testExtractMixedMonoAudioReadsSecondTrackFromMultiTrackMP4AndWritesValidWAV() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("catch-captions-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mp4URL = tempDir.appendingPathComponent("multi-track.mp4")
        try await writeTwoAudioTrackMP4(to: mp4URL, durationSeconds: 2.0)

        let extracted = try await TakeCaptions.extractMixedMonoAudio(from: mp4URL)
        let extractedDuration = Double(extracted.count) / TakeCaptions.recognitionSampleRate
        XCTAssertEqual(extractedDuration, 2.0, accuracy: 0.15)

        // Track 1 was completely silent, Track 2 had a 440Hz tone -> extracted mix must carry Track 2's signal
        let peak = extracted.reduce(Float(0)) { max($0, abs($1)) }
        XCTAssertGreaterThan(peak, 0.25, "Expected Track 2 microphone audio to be preserved when Track 1 is silent")

        let wavURL = tempDir.appendingPathComponent("chunk-0.wav")
        try TakeCaptions.writeWAV(samples: extracted[...], to: wavURL)
        let wavFile = try AVAudioFile(forReading: wavURL)
        XCTAssertEqual(wavFile.fileFormat.sampleRate, TakeCaptions.recognitionSampleRate, accuracy: 1.0)
        XCTAssertEqual(wavFile.fileFormat.channelCount, 1)
        XCTAssertGreaterThan(wavFile.length, AVAudioFramePosition(TakeCaptions.recognitionSampleRate * 1.8))
    }

    func testIsNoSpeechErrorRecognizesAssistantCode1110() {
        let noSpeech = NSError(domain: "kAFAssistantErrorDomain", code: 1110, userInfo: [NSLocalizedDescriptionKey: "No speech detected"])
        let other = NSError(domain: "kAFAssistantErrorDomain", code: 201, userInfo: [NSLocalizedDescriptionKey: "Service unavailable"])
        XCTAssertTrue(TakeCaptions.isNoSpeechError(noSpeech))
        XCTAssertFalse(TakeCaptions.isNoSpeechError(other))
    }

    // MARK: - Helpers

    private func writeTwoAudioTrackMP4(to url: URL, durationSeconds: Double) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let sampleRate = 48_000.0
        let totalFrames = Int(durationSeconds * sampleRate)

        let track1Settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000
        ]
        let track2Settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000
        ]

        let input1 = AVAssetWriterInput(mediaType: .audio, outputSettings: track1Settings)
        let input2 = AVAssetWriterInput(mediaType: .audio, outputSettings: track2Settings)
        input1.expectsMediaDataInRealTime = false
        input2.expectsMediaDataInRealTime = false
        writer.add(input1)
        writer.add(input2)

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let blockFrames = 1024
        var written1 = 0
        var written2 = 0

        while written1 < totalFrames || written2 < totalFrames {
            if written1 < totalFrames && input1.isReadyForMoreMediaData {
                let count = min(blockFrames, totalFrames - written1)
                let buf = try makePCMBuffer(frameCount: count, channels: 2, sampleRate: sampleRate, startFrame: written1, frequency: 0, amplitude: 0)
                input1.append(buf)
                written1 += count
            }
            if written2 < totalFrames && input2.isReadyForMoreMediaData {
                let count = min(blockFrames, totalFrames - written2)
                let buf = try makePCMBuffer(frameCount: count, channels: 1, sampleRate: sampleRate, startFrame: written2, frequency: 440, amplitude: 0.5)
                input2.append(buf)
                written2 += count
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        input1.markAsFinished()
        input2.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? NSError(domain: "TakeCaptionsTests", code: 1)
        }
    }

    private func makePCMBuffer(
        frameCount: Int,
        channels: Int,
        sampleRate: Double,
        startFrame: Int,
        frequency: Double,
        amplitude: Float
    ) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels * MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channels * MemoryLayout<Float>.size),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDesc: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDesc)

        var samples = [Float](repeating: 0, count: frameCount * channels)
        if amplitude > 0 && frequency > 0 {
            for f in 0..<frameCount {
                let t = Double(startFrame + f) / sampleRate
                let value = Float(sin(2.0 * .pi * frequency * t)) * amplitude
                for c in 0..<channels {
                    samples[f * channels + c] = value
                }
            }
        }

        let byteCount = samples.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &blockBuffer)
        samples.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: blockBuffer!, offsetIntoDestination: 0, dataLength: byteCount)
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(value: CMTimeValue(startFrame), timescale: CMTimeScale(sampleRate)),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        return sampleBuffer!
    }
}
