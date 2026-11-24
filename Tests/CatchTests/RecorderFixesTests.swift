import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
import ScreenCaptureKit
@testable import CatchCore

final class RecorderFixesTests: XCTestCase {

    // MARK: - Sample Buffer Helpers

    private func makeVideoSampleBuffer(
        width: Int = 320,
        height: Int = 240,
        pts: CMTime,
        status: SCFrameStatus?,
        includePixelBuffer: Bool = true
    ) throws -> CMSampleBuffer {
        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        if includePixelBuffer {
            let pixelBuffer = try XCTUnwrap(ScreenRecordingStudio.makeSolidPixelBuffer(width: width, height: height))
            var formatDescription: CMVideoFormatDescription?
            let fmtStatus = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDescription
            )
            XCTAssertEqual(fmtStatus, noErr)
            let created = CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescription: try XCTUnwrap(formatDescription),
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer
            )
            XCTAssertEqual(created, noErr)
        } else {
            var formatDescription: CMVideoFormatDescription?
            let fmtStatus = CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                codecType: kCMVideoCodecType_422YpCbCr8,
                width: Int32(width),
                height: Int32(height),
                extensions: nil,
                formatDescriptionOut: &formatDescription
            )
            XCTAssertEqual(fmtStatus, noErr)
            let created = CMSampleBufferCreate(
                allocator: kCFAllocatorDefault,
                dataBuffer: nil,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: formatDescription,
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 0,
                sampleSizeArray: nil,
                sampleBufferOut: &sampleBuffer
            )
            XCTAssertEqual(created, noErr)
        }

        let buffer = try XCTUnwrap(sampleBuffer)
        if let status,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true) as? [CFMutableDictionary],
           let dict = attachments.first {
            let key = Unmanaged.passUnretained(SCStreamFrameInfo.status.rawValue as CFString).toOpaque()
            let value = Unmanaged.passUnretained(NSNumber(value: status.rawValue)).toOpaque()
            CFDictionarySetValue(dict, key, value)
        }
        return buffer
    }

    private func makeAudioSampleBuffer(pts: CMTime, frameCount: Int = 960) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        let fmtStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        XCTAssertEqual(fmtStatus, noErr)

        let byteCount = max(8, frameCount * Int(asbd.mBytesPerFrame))
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        XCTAssertEqual(blockStatus, noErr)
        if let block = blockBuffer {
            _ = CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let created = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        XCTAssertEqual(created, noErr)
        return try XCTUnwrap(sampleBuffer)
    }

    // MARK: - Bug #1a: ScreenCaptureKit Frame Validation

    func testScreenSampleBufferFilteringRejectsNonCompleteAndNilPixelBufferFrames() throws {
        let validPTS = CMTime(seconds: 1.0, preferredTimescale: 600)

        // Complete frame with pixel buffer is accepted.
        let complete = try makeVideoSampleBuffer(pts: validPTS, status: .complete, includePixelBuffer: true)
        XCTAssertTrue(ScreenRecordingStudio.shouldAcceptSampleBuffer(complete, of: .screen))

        // Every non-.complete SCFrameStatus must be rejected even if a pixel buffer were present.
        let rejectedStatuses: [SCFrameStatus] = [.idle, .blank, .suspended, .started, .stopped]
        for status in rejectedStatuses {
            let withBuffer = try makeVideoSampleBuffer(pts: validPTS, status: status, includePixelBuffer: true)
            XCTAssertFalse(
                ScreenRecordingStudio.shouldAcceptSampleBuffer(withBuffer, of: .screen),
                "Expected .screen buffer with status \(status.rawValue) to be rejected"
            )
            let withoutBuffer = try makeVideoSampleBuffer(pts: validPTS, status: status, includePixelBuffer: false)
            XCTAssertFalse(
                ScreenRecordingStudio.shouldAcceptSampleBuffer(withoutBuffer, of: .screen),
                "Expected nil-imageBuffer .screen buffer with status \(status.rawValue) to be rejected"
            )
        }

        // Complete status with nil CVPixelBuffer must be rejected.
        let completeNoPixelBuffer = try makeVideoSampleBuffer(pts: validPTS, status: .complete, includePixelBuffer: false)
        XCTAssertFalse(ScreenRecordingStudio.shouldAcceptSampleBuffer(completeNoPixelBuffer, of: .screen))

        // Missing SCStreamFrameInfo.status attachment must be rejected for .screen frames.
        let missingStatus = try makeVideoSampleBuffer(pts: validPTS, status: nil, includePixelBuffer: true)
        XCTAssertFalse(ScreenRecordingStudio.shouldAcceptSampleBuffer(missingStatus, of: .screen))

        // Invalid/non-numeric PTS must be rejected.
        let invalidPTSBuffer = try makeVideoSampleBuffer(pts: .invalid, status: .complete, includePixelBuffer: true)
        XCTAssertFalse(ScreenRecordingStudio.shouldAcceptSampleBuffer(invalidPTSBuffer, of: .screen))

        // Valid audio buffers without screen attachments are accepted; invalid PTS audio is rejected.
        let validAudio = try makeAudioSampleBuffer(pts: validPTS, frameCount: 960)
        XCTAssertTrue(ScreenRecordingStudio.shouldAcceptSampleBuffer(validAudio, of: .audio))

        let invalidAudio = try makeAudioSampleBuffer(pts: .indefinite, frameCount: 960)
        XCTAssertFalse(ScreenRecordingStudio.shouldAcceptSampleBuffer(invalidAudio, of: .audio))
    }

    // MARK: - Bug #1b: Monotonic PTS Guard

    func testMonotonicTimestampGuardRejectsDuplicatesAndOutOfOrderPTS() {
        var guardState = ScreenRecordingStudio.MonotonicTimestampGuard()
        let t0 = CMTime(seconds: 10.000, preferredTimescale: 600)
        let tBefore = CMTime(seconds: 9.950, preferredTimescale: 600)
        let t1 = CMTime(seconds: 10.033, preferredTimescale: 600)
        let t2 = CMTime(seconds: 10.066, preferredTimescale: 600)
        let tAudio1 = CMTime(seconds: 10.010, preferredTimescale: 600)
        let tAudio2 = CMTime(seconds: 10.030, preferredTimescale: 600)

        XCTAssertFalse(guardState.startSession(at: .invalid))
        XCTAssertTrue(guardState.startSession(at: t0))

        // Samples before sessionStartPTS are rejected on all tracks.
        XCTAssertFalse(guardState.shouldAccept(pts: tBefore, for: .screen))
        XCTAssertFalse(guardState.shouldAccept(pts: tBefore, for: .audio))

        // First screen frame at sessionStartPTS is accepted; until recorded, same PTS stays acceptable.
        XCTAssertTrue(guardState.shouldAccept(pts: t0, for: .screen))
        guardState.recordAppended(pts: t0, for: .screen)

        // Duplicate and backwards video PTS (e.g., pause/resume boundary) are rejected.
        XCTAssertFalse(guardState.shouldAccept(pts: t0, for: .screen))
        XCTAssertFalse(guardState.shouldAccept(pts: tBefore, for: .screen))

        // Strictly increasing video PTS is accepted.
        XCTAssertTrue(guardState.shouldAccept(pts: t1, for: .screen))
        guardState.recordAppended(pts: t1, for: .screen)

        // Audio timestamps are tracked independently from video, while still >= sessionStartPTS.
        XCTAssertTrue(guardState.shouldAccept(pts: tAudio1, for: .audio))
        guardState.recordAppended(pts: tAudio1, for: .audio)
        XCTAssertFalse(guardState.shouldAccept(pts: tAudio1, for: .audio))
        XCTAssertFalse(guardState.shouldAccept(pts: t0, for: .audio))
        XCTAssertTrue(guardState.shouldAccept(pts: tAudio2, for: .audio))
        guardState.recordAppended(pts: tAudio2, for: .audio)

        // Video continues accepting strictly increasing PTS.
        XCTAssertTrue(guardState.shouldAccept(pts: t2, for: .screen))
        guardState.recordAppended(pts: t2, for: .screen)
        XCTAssertFalse(guardState.shouldAccept(pts: t1, for: .screen))
    }

    // MARK: - Bug #1a+b Integration: Real AVAssetWriter Survives Idle & Duplicate PTS Frames

    func testAssetWriterSkipsIdleFramesAndDuplicatePTSWithoutFailing() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatchRecorderFix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputURL = tempDir.appendingPathComponent("valid-take.mp4")
        let studio = ScreenRecordingStudio()
        XCTAssertTrue(studio.setupAssetWriter(to: outputURL, width: 320, height: 240, includeAudio: false))
        studio.setWriterAcceptingSamples(true)

        // Feed idle/blank/nil-imageBuffer frames before and between valid complete frames,
        // plus duplicate and backwards timestamps that previously caused -11800 / -16122.
        studio.appendSampleBuffer(
            try makeVideoSampleBuffer(pts: CMTime(seconds: 0.90, preferredTimescale: 600), status: .started, includePixelBuffer: false),
            of: .screen
        )
        studio.appendSampleBuffer(
            try makeVideoSampleBuffer(pts: CMTime(seconds: 1.00, preferredTimescale: 600), status: .complete, includePixelBuffer: true),
            of: .screen
        )
        studio.appendSampleBuffer(
            try makeVideoSampleBuffer(pts: CMTime(seconds: 1.00, preferredTimescale: 600), status: .complete, includePixelBuffer: true),
            of: .screen
        )
        studio.appendSampleBuffer(
            try makeVideoSampleBuffer(pts: CMTime(seconds: 0.95, preferredTimescale: 600), status: .complete, includePixelBuffer: true),
            of: .screen
        )
        studio.appendSampleBuffer(
            try makeVideoSampleBuffer(pts: CMTime(seconds: 1.05, preferredTimescale: 600), status: .idle, includePixelBuffer: false),
            of: .screen
        )
        studio.appendSampleBuffer(
            try makeVideoSampleBuffer(pts: CMTime(seconds: 1.06, preferredTimescale: 600), status: .blank, includePixelBuffer: false),
            of: .screen
        )
        studio.appendSampleBuffer(
            try makeVideoSampleBuffer(pts: CMTime(seconds: 1.10, preferredTimescale: 600), status: .complete, includePixelBuffer: true),
            of: .screen
        )
        studio.appendSampleBuffer(
            try makeVideoSampleBuffer(pts: CMTime(seconds: 1.20, preferredTimescale: 600), status: .complete, includePixelBuffer: true),
            of: .screen
        )

        let result = await studio.finalizeWriter(fallbackSize: CGSize(width: 320, height: 240), fps: 30)
        XCTAssertNil(result.failure, "Writer should not fail when idle/duplicate frames are filtered")
        let playable = await ScreenRecordingStudio.isPlayableVideo(at: outputURL)
        XCTAssertTrue(playable, "Finalized MP4 should be playable")
    }

    // MARK: - Bug #1c: Failed Writer Cleanup & Interrupted Media Labelling

    func testFailedOutputRemovesCorruptUnplayableMP4() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatchCorruptCleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Simulate a partial/corrupt MP4 without a moov atom (as left by a failed AVAssetWriter).
        let corruptURL = tempDir.appendingPathComponent("Catch 2026-11-21 at 17.19.54-8D4FDA.mp4")
        try Data(repeating: 0xAB, count: 4096).write(to: corruptURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: corruptURL.path))

        // Even if interrupted recovery is allowed, an unplayable/corrupt MP4 must be deleted.
        let recovered = await ScreenRecordingStudio.resolveFailedOutput(at: corruptURL, allowInterruptedRecovery: true)
        XCTAssertNil(recovered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptURL.path))
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: tempDir.path)).isEmpty)
    }

    func testInterruptedStreamWithUsableFramesSavesExplicitlyLabelledInterruptedMP4() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatchInterruptedLabel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputURL = tempDir.appendingPathComponent("Catch 2026-11-21 at 17.19.54-8D4FDA.mp4")
        let studio = ScreenRecordingStudio()
        XCTAssertTrue(studio.setupAssetWriter(to: outputURL, width: 320, height: 240, includeAudio: false))
        studio.setWriterAcceptingSamples(true)

        studio.appendSampleBuffer(
            try makeVideoSampleBuffer(pts: CMTime(seconds: 1.00, preferredTimescale: 600), status: .complete, includePixelBuffer: true),
            of: .screen
        )
        studio.appendSampleBuffer(
            try makeVideoSampleBuffer(pts: CMTime(seconds: 1.10, preferredTimescale: 600), status: .complete, includePixelBuffer: true),
            of: .screen
        )
        studio.appendSampleBuffer(
            try makeVideoSampleBuffer(pts: CMTime(seconds: 1.20, preferredTimescale: 600), status: .complete, includePixelBuffer: true),
            of: .screen
        )

        // Simulate SCStreamDelegate reporting an unexpected mid-take stop while writer is still healthy.
        studio.streamStopped(with: NSError(domain: "SCStreamTest", code: -3808, userInfo: [NSLocalizedDescriptionKey: "Display disconnected"]))

        let result = await studio.finalizeWriter(fallbackSize: CGSize(width: 320, height: 240), fps: 30)
        XCTAssertNotNil(result.failure)
        XCTAssertTrue(result.allowInterruptedRecovery)

        let recoveredURL = await ScreenRecordingStudio.resolveFailedOutput(
            at: outputURL,
            allowInterruptedRecovery: result.allowInterruptedRecovery
        )
        let unwrappedRecovered = try XCTUnwrap(recoveredURL)
        XCTAssertEqual(unwrappedRecovered.lastPathComponent, "Catch 2026-11-21 at 17.19.54-8D4FDA-interrupted.mp4")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unwrappedRecovered.path))
        let isPlayable = await ScreenRecordingStudio.isPlayableVideo(at: unwrappedRecovered)
        XCTAssertTrue(isPlayable)
    }

    func testZeroFrameFailureLeavesNoOutputFileOnDisk() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatchZeroFrames-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputURL = tempDir.appendingPathComponent("empty-take.mp4")
        let studio = ScreenRecordingStudio()
        XCTAssertTrue(studio.setupAssetWriter(to: outputURL, width: 320, height: 240, includeAudio: false))
        studio.setWriterAcceptingSamples(true)

        // Only deliver an idle frame (no usable video frames).
        studio.appendSampleBuffer(
            try makeVideoSampleBuffer(pts: CMTime(seconds: 1.0, preferredTimescale: 600), status: .idle, includePixelBuffer: false),
            of: .screen
        )

        let result = await studio.finalizeWriter(fallbackSize: CGSize(width: 320, height: 240), fps: 30)
        XCTAssertNotNil(result.failure)
        XCTAssertFalse(result.allowInterruptedRecovery)

        let recovered = await ScreenRecordingStudio.resolveFailedOutput(
            at: outputURL,
            allowInterruptedRecovery: result.allowInterruptedRecovery
        )
        XCTAssertNil(recovered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    // MARK: - Bug #2: Dynamic Settings Sync for Record System Audio

    func testSystemAudioToggleSyncsDynamicallyWithoutRecreatingStudio() throws {
        let suiteName = "com.catchapp.tests.recorderfixes.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        XCTAssertTrue(settings.recordingRecordSystemAudio)

        let studio = ScreenRecordingStudio(settings: settings)
        XCTAssertTrue(studio.includeSystemAudio)

        // Toggling Settings -> updates existing studio instance immediately.
        settings.recordingRecordSystemAudio = false
        XCTAssertFalse(studio.includeSystemAudio)

        settings.recordingRecordSystemAudio = true
        XCTAssertTrue(studio.includeSystemAudio)

        // Mutating studio programmatically -> stays in sync with SettingsStore.
        studio.includeSystemAudio = false
        XCTAssertFalse(settings.recordingRecordSystemAudio)

        // Toggling Settings back -> updates studio again with no stale state.
        settings.recordingRecordSystemAudio = true
        XCTAssertTrue(studio.includeSystemAudio)
    }

    func testSharedStudioReactsLiveToSharedSettingsSystemAudioToggle() {
        let previous = SettingsStore.shared.recordingRecordSystemAudio
        defer { SettingsStore.shared.recordingRecordSystemAudio = previous }

        let studio = ScreenRecordingStudio.shared
        SettingsStore.shared.recordingRecordSystemAudio = false
        XCTAssertFalse(studio.includeSystemAudio)

        SettingsStore.shared.recordingRecordSystemAudio = true
        XCTAssertTrue(studio.includeSystemAudio)
    }
}
