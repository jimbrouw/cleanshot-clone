import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
@testable import CatchCore

final class CameraStudioRecorderTests: XCTestCase {

    // MARK: - Helpers

    private func makeVideoBuffer(width: Int = 640, height: Int = 360, pts: CMTime) throws -> CMSampleBuffer {
        let pixelBuffer = try XCTUnwrap(ScreenRecordingStudio.makeSolidPixelBuffer(width: width, height: height))
        var formatDesc: CMVideoFormatDescription?
        let fmtStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc
        )
        XCTAssertEqual(fmtStatus, noErr)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: try XCTUnwrap(formatDesc),
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(sampleBuffer)
    }

    private func makeAudioBuffer(
        pts: CMTime,
        frameCount: Int = 1024,
        channels: UInt32 = 1,
        toneFrequency: Double = 0,
        amplitude: Float = 0.5,
        startSampleIndex: Int = 0
    ) throws -> CMSampleBuffer {
        let bytesPerFrame = channels * 4
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDesc: CMAudioFormatDescription?
        let fmtStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        XCTAssertEqual(fmtStatus, noErr)

        let byteCount = max(Int(bytesPerFrame), frameCount * Int(bytesPerFrame))
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
            if toneFrequency > 0 && amplitude > 0 {
                var samples = [Float](repeating: 0, count: frameCount * Int(channels))
                for f in 0..<frameCount {
                    let t = Double(startSampleIndex + f) / 48_000.0
                    let value = Float(sin(2.0 * .pi * toneFrequency * t)) * amplitude
                    for c in 0..<Int(channels) {
                        samples[f * Int(channels) + c] = value
                    }
                }
                samples.withUnsafeBytes { raw in
                    _ = CMBlockBufferReplaceDataBytes(
                        with: raw.baseAddress!,
                        blockBuffer: block,
                        offsetIntoDestination: 0,
                        dataLength: byteCount
                    )
                }
            } else {
                _ = CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
            }
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDesc,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(sampleBuffer)
    }

    // MARK: - Max Resolution Format Selection

    func testCameraFormatSelectorPicks4KAndLargestFullSensorResolution() throws {
        let candidates: [CameraFormatCandidate] = [
            CameraFormatCandidate(index: 0, width: 1280, height: 720, minFrameRate: 15, maxFrameRate: 60, mediaSubType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            CameraFormatCandidate(index: 1, width: 1920, height: 1080, minFrameRate: 15, maxFrameRate: 60, mediaSubType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            CameraFormatCandidate(index: 2, width: 3840, height: 2160, minFrameRate: 15, maxFrameRate: 30, mediaSubType: kCVPixelFormatType_32BGRA),
            CameraFormatCandidate(index: 3, width: 3840, height: 2160, minFrameRate: 15, maxFrameRate: 30, mediaSubType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            // Too slow for smooth video (15 fps) should lose to smooth 4K 30fps
            CameraFormatCandidate(index: 4, width: 4032, height: 3024, minFrameRate: 1, maxFrameRate: 15, mediaSubType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        ]

        let selected = try XCTUnwrap(CameraFormatSelector.selectBestFormat(from: candidates, preferredFrameRate: 60))
        XCTAssertEqual(selected.candidate.index, 3)
        XCTAssertEqual(selected.encodedWidth, 3840)
        XCTAssertEqual(selected.encodedHeight, 2160)
        XCTAssertEqual(selected.targetFrameRate, 30.0, accuracy: 0.01)
        XCTAssertTrue(selected.badgeText.contains("4K"))

        // If the sensor supports an even larger smooth open-gate 4:3 resolution at 30fps, prefer it.
        let openGateCandidates = candidates + [
            CameraFormatCandidate(index: 5, width: 4096, height: 3072, minFrameRate: 15, maxFrameRate: 30, mediaSubType: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        ]
        let openGate = try XCTUnwrap(CameraFormatSelector.selectBestFormat(from: openGateCandidates, preferredFrameRate: 30))
        XCTAssertEqual(openGate.candidate.index, 5)
        XCTAssertEqual(openGate.encodedWidth, 4096)
        XCTAssertEqual(openGate.encodedHeight, 3072)

        // Verify HEVC bitrate scales sensibly for 4K vs 1080p.
        let bitrate4K = CameraFormatSelector.recommendedHEVCBitrate(width: 3840, height: 2160, frameRate: 30)
        let bitrate1080 = CameraFormatSelector.recommendedHEVCBitrate(width: 1920, height: 1080, frameRate: 30)
        XCTAssertGreaterThanOrEqual(bitrate4K, 20_000_000)
        XCTAssertGreaterThan(bitrate4K, bitrate1080 * 2)
    }

    func testCameraFormatSelectorAspectRatioPreference() throws {
        // 1. iPhone Continuity Camera formats: 1920×1440 (4:3) vs 1920×1080 (16:9)
        let continuityFormats: [CameraFormatCandidate] = [
            CameraFormatCandidate(index: 0, width: 1280, height: 720, minFrameRate: 15, maxFrameRate: 60, mediaSubType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            CameraFormatCandidate(index: 1, width: 1920, height: 1080, minFrameRate: 15, maxFrameRate: 60, mediaSubType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            CameraFormatCandidate(index: 2, width: 1920, height: 1440, minFrameRate: 15, maxFrameRate: 60, mediaSubType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        ]

        let continuity16x9 = try XCTUnwrap(CameraFormatSelector.selectBestFormat(
            from: continuityFormats,
            preferredFrameRate: 60,
            aspectRatio: .widescreen16x9
        ))
        XCTAssertEqual(continuity16x9.candidate.index, 1)
        XCTAssertEqual(continuity16x9.encodedWidth, 1920)
        XCTAssertEqual(continuity16x9.encodedHeight, 1080)

        let continuityFull = try XCTUnwrap(CameraFormatSelector.selectBestFormat(
            from: continuityFormats,
            preferredFrameRate: 60,
            aspectRatio: .fullSensor
        ))
        XCTAssertEqual(continuityFull.candidate.index, 2)
        XCTAssertEqual(continuityFull.encodedWidth, 1920)
        XCTAssertEqual(continuityFull.encodedHeight, 1440)

        // 2. 4K + open-gate formats: 3840×2160 (16:9) vs 4096×3072 (4:3 open-gate)
        let fourKFormats: [CameraFormatCandidate] = [
            CameraFormatCandidate(index: 0, width: 1920, height: 1080, minFrameRate: 15, maxFrameRate: 60, mediaSubType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            CameraFormatCandidate(index: 1, width: 3840, height: 2160, minFrameRate: 15, maxFrameRate: 30, mediaSubType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            CameraFormatCandidate(index: 2, width: 4096, height: 3072, minFrameRate: 15, maxFrameRate: 30, mediaSubType: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        ]

        let fourK16x9 = try XCTUnwrap(CameraFormatSelector.selectBestFormat(
            from: fourKFormats,
            preferredFrameRate: 30,
            aspectRatio: .widescreen16x9
        ))
        XCTAssertEqual(fourK16x9.candidate.index, 1)
        XCTAssertEqual(fourK16x9.encodedWidth, 3840)
        XCTAssertEqual(fourK16x9.encodedHeight, 2160)

        let fourKFull = try XCTUnwrap(CameraFormatSelector.selectBestFormat(
            from: fourKFormats,
            preferredFrameRate: 30,
            aspectRatio: .fullSensor
        ))
        XCTAssertEqual(fourKFull.candidate.index, 2)
        XCTAssertEqual(fourKFull.encodedWidth, 4096)
        XCTAssertEqual(fourKFull.encodedHeight, 3072)

        // 3. Fallback to highest pixel area when camera exposes no 16:9 format
        let fourByThreeOnly: [CameraFormatCandidate] = [
            CameraFormatCandidate(index: 0, width: 640, height: 480, minFrameRate: 15, maxFrameRate: 30, mediaSubType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            CameraFormatCandidate(index: 1, width: 1600, height: 1200, minFrameRate: 15, maxFrameRate: 30, mediaSubType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            CameraFormatCandidate(index: 2, width: 1920, height: 1440, minFrameRate: 15, maxFrameRate: 30, mediaSubType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        ]

        let fallback = try XCTUnwrap(CameraFormatSelector.selectBestFormat(
            from: fourByThreeOnly,
            preferredFrameRate: 30,
            aspectRatio: .widescreen16x9
        ))
        XCTAssertEqual(fallback.candidate.index, 2)
        XCTAssertEqual(fallback.encodedWidth, 1920)
        XCTAssertEqual(fallback.encodedHeight, 1440)

        // 4. Verify labels
        XCTAssertEqual(CameraAspectRatioPreference.widescreen16x9.label, "16:9")
        XCTAssertEqual(CameraAspectRatioPreference.widescreen16x9.settingsLabel, "16:9 Widescreen (1080p / 4K)")
        XCTAssertEqual(CameraAspectRatioPreference.fullSensor.label, "Full Sensor")
        XCTAssertEqual(CameraAspectRatioPreference.fullSensor.settingsLabel, "Full Sensor (Max / 4:3)")
    }

    // MARK: - Output Plan for All Three Modes + Stems

    func testTakeOutputPlanCoversLoomDualTrackAndCameraPodcastModes() {
        let root = URL(fileURLWithPath: "/tmp/CatchPlanTest", isDirectory: true)

        // 1. Standard Loom Bubble without WAV stems -> single flat MP4
        let loomFlat = ScreenRecordingStudio.makeTakeOutputPlan(
            rootDirectory: root,
            baseName: "Take-001",
            captureMode: .fullscreen,
            cameraRecordingMode: .floatingBubble,
            includeCamera: true,
            includeMicrophone: true,
            includeSystemAudio: true,
            exportAudioStems: false
        )
        XCTAssertNil(loomFlat.takeDirectoryURL)
        XCTAssertEqual(loomFlat.primaryVideoURL.lastPathComponent, "Take-001.mp4")
        XCTAssertEqual(loomFlat.screenVideoURL, loomFlat.primaryVideoURL)
        XCTAssertNil(loomFlat.cameraVideoURL)
        XCTAssertNil(loomFlat.microphoneStemURL)
        XCTAssertNil(loomFlat.systemAudioStemURL)

        // 2. Dual-Track ISO (Screen + Separate 4K File + WAV stems) -> take folder with all 4 synced files
        let dualISO = ScreenRecordingStudio.makeTakeOutputPlan(
            rootDirectory: root,
            baseName: "Take-002",
            captureMode: .fullscreen,
            cameraRecordingMode: .separateFullResFile,
            includeCamera: true,
            includeMicrophone: true,
            includeSystemAudio: true,
            exportAudioStems: true
        )
        XCTAssertEqual(dualISO.takeDirectoryURL?.lastPathComponent, "Take-002")
        XCTAssertEqual(dualISO.screenVideoURL?.lastPathComponent, "Take-002-screen.mp4")
        XCTAssertEqual(dualISO.cameraVideoURL?.lastPathComponent, "Take-002-camera.mp4")
        XCTAssertEqual(dualISO.microphoneStemURL?.lastPathComponent, "Take-002-mic.wav")
        XCTAssertEqual(dualISO.systemAudioStemURL?.lastPathComponent, "Take-002-system-audio.wav")
        XCTAssertEqual(dualISO.primaryVideoURL, dualISO.screenVideoURL)

        // 3. Camera-Only Podcast mode without stems -> flat camera MP4, no screen
        let podcastFlat = ScreenRecordingStudio.makeTakeOutputPlan(
            rootDirectory: root,
            baseName: "Take-003",
            captureMode: .cameraOnly,
            cameraRecordingMode: .floatingBubble,
            includeCamera: false,
            includeMicrophone: true,
            includeSystemAudio: true,
            exportAudioStems: false
        )
        XCTAssertNil(podcastFlat.takeDirectoryURL)
        XCTAssertNil(podcastFlat.screenVideoURL)
        XCTAssertEqual(podcastFlat.cameraVideoURL?.lastPathComponent, "Take-003-camera.mp4")
        XCTAssertEqual(podcastFlat.primaryVideoURL, podcastFlat.cameraVideoURL)
        XCTAssertNil(podcastFlat.microphoneStemURL)
        XCTAssertNil(podcastFlat.systemAudioStemURL)

        // 4. Camera-Only Podcast mode with stems -> take folder with camera MP4 + mic WAV (no system audio stem)
        let podcastStems = ScreenRecordingStudio.makeTakeOutputPlan(
            rootDirectory: root,
            baseName: "Take-004",
            captureMode: .cameraOnly,
            cameraRecordingMode: .separateFullResFile,
            includeCamera: true,
            includeMicrophone: true,
            includeSystemAudio: true,
            exportAudioStems: true
        )
        XCTAssertEqual(podcastStems.takeDirectoryURL?.lastPathComponent, "Take-004")
        XCTAssertNil(podcastStems.screenVideoURL)
        XCTAssertEqual(podcastStems.cameraVideoURL?.lastPathComponent, "Take-004-camera.mp4")
        XCTAssertEqual(podcastStems.microphoneStemURL?.lastPathComponent, "Take-004-mic.wav")
        XCTAssertNil(podcastStems.systemAudioStemURL)
    }

    // MARK: - Dual-Track Sync Barrier

    func testDualTrackSyncBarrierWaitsForBothStreamsAndAlignsStartPTS() throws {
        var barrier = DualTrackSyncBarrier(requiresScreen: true, requiresCamera: true)
        let tScreen = CMTime(value: 6000, timescale: 600) // 10.00s exact
        let tCamera = CMTime(value: 6024, timescale: 600) // 10.04s exact

        let screenSample = try makeVideoBuffer(pts: tScreen)
        let cameraSample = try makeVideoBuffer(pts: tCamera)

        // Screen arrives first -> holds until camera arrives.
        XCTAssertNil(barrier.ingestInitialScreen(screenSample, pts: tScreen))
        XCTAssertFalse(barrier.isReady)

        // Camera arrives slightly later -> resolves at max(tScreen, tCamera) and aligns both initial frames.
        let resolution = try XCTUnwrap(barrier.ingestInitialCamera(cameraSample, pts: tCamera))
        XCTAssertTrue(barrier.isReady)
        XCTAssertEqual(CMTimeGetSeconds(resolution.startPTS), 10.04, accuracy: 0.0001)
        XCTAssertEqual(CMTimeGetSeconds(try XCTUnwrap(resolution.initialScreen?.pts)), 10.04, accuracy: 0.0001)
        XCTAssertEqual(CMTimeGetSeconds(try XCTUnwrap(resolution.initialCamera?.pts)), 10.04, accuracy: 0.0001)
        let retimedScreenPTS = CMSampleBufferGetPresentationTimeStamp(try XCTUnwrap(resolution.initialScreen?.sample))
        XCTAssertEqual(CMTimeGetSeconds(retimedScreenPTS), 10.04, accuracy: 0.0001)
    }

    // MARK: - Real HEVC Camera Writer + 48 kHz 24-bit WAV Stem Writer

    func testCameraTrackWriterProducesPlayableHEVCMP4WithSyncedAudioAndWAVStem() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatchCameraHEVC-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cameraURL = tempDir.appendingPathComponent("podcast-camera.mp4")
        let micStemURL = tempDir.appendingPathComponent("podcast-mic.wav")

        let camWriter = try XCTUnwrap(CameraTrackWriter(
            outputURL: cameraURL,
            width: 640,
            height: 360,
            frameRate: 30,
            includeMicrophoneAudio: true,
            preferHEVC: true
        ))
        XCTAssertEqual(camWriter.codec, .hevc)

        let stemWriter = try XCTUnwrap(AudioStemWriter(outputURL: micStemURL, channelCount: 1, sampleRate: 48_000))

        let startPTS = CMTime(seconds: 5.0, preferredTimescale: 600)
        XCTAssertTrue(camWriter.startSession(at: startPTS))
        XCTAssertTrue(stemWriter.startSession(at: startPTS))

        // Write 0.5 seconds of video (15 frames at 30 fps) + matching 48 kHz PCM audio buffers
        for i in 0..<15 {
            let pts = CMTimeAdd(startPTS, CMTime(value: CMTimeValue(i), timescale: 30))
            camWriter.appendVideo(try makeVideoBuffer(width: 640, height: 360, pts: pts))
        }
        for i in 0..<24 {
            let audioOffset = CMTime(value: CMTimeValue(i * 1024), timescale: 48_000)
            let pts = CMTimeAdd(startPTS, audioOffset)
            let audio = try makeAudioBuffer(pts: pts, frameCount: 1024, channels: 1)
            camWriter.appendAudio(audio)
            stemWriter.append(audio)
        }

        let camResult = await camWriter.finish()
        XCTAssertNil(camResult.failure, camResult.failure ?? "")
        let finalizedCameraURL = try XCTUnwrap(camResult.url)
        let stemResult = await stemWriter.finish()
        let finalizedStemURL = try XCTUnwrap(stemResult)

        // Verify HEVC MP4 is playable with both video and synced audio tracks.
        let videoAsset = AVURLAsset(url: finalizedCameraURL)
        let isPlayable = try await videoAsset.load(.isPlayable)
        XCTAssertTrue(isPlayable)
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        let audioTracks = try await videoAsset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 1)
        let videoDuration = try await videoAsset.load(.duration).seconds
        XCTAssertGreaterThan(videoDuration, 0.35)

        // Verify codec is HEVC (hvc1).
        let formatDescs = try await videoTracks[0].load(.formatDescriptions)
        let codecSubType = CMFormatDescriptionGetMediaSubType(try XCTUnwrap(formatDescs.first))
        XCTAssertEqual(codecSubType, kCMVideoCodecType_HEVC)

        // Verify WAV stem is readable 48 kHz PCM with matching duration.
        let audioFile = try AVAudioFile(forReading: finalizedStemURL)
        XCTAssertEqual(audioFile.fileFormat.sampleRate, 48_000, accuracy: 1.0)
        XCTAssertEqual(audioFile.fileFormat.channelCount, 1)
        let wavDuration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
        XCTAssertGreaterThan(wavDuration, 0.35)
        XCTAssertEqual(wavDuration, videoDuration, accuracy: 0.15)
    }

    // MARK: - Settings Live Sync + Bundle Discovery + Handoff

    func testCameraModeAndAudioStemsSettingsSyncDynamically() throws {
        let suiteName = "com.catchapp.tests.cameramode.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.recordingCameraMode, .floatingBubble)
        XCTAssertFalse(settings.recordingExportAudioStems)

        let studio = ScreenRecordingStudio(settings: settings)
        XCTAssertEqual(studio.cameraRecordingMode, .floatingBubble)
        XCTAssertFalse(studio.exportAudioStems)

        settings.recordingCameraMode = .separateFullResFile
        settings.recordingExportAudioStems = true
        XCTAssertEqual(studio.cameraRecordingMode, .separateFullResFile)
        XCTAssertTrue(studio.exportAudioStems)

        studio.cameraRecordingMode = .floatingBubble
        studio.exportAudioStems = false
        XCTAssertEqual(settings.recordingCameraMode, .floatingBubble)
        XCTAssertFalse(settings.recordingExportAudioStems)
    }

    func testCameraAspectRatioSettingSyncsDynamicallyAndPersists() throws {
        let suiteName = "com.catchapp.tests.cameraaspect.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.recordingCameraAspectRatio, .widescreen16x9)

        let studio = ScreenRecordingStudio(settings: settings)
        XCTAssertEqual(studio.cameraAspectRatio, .widescreen16x9)

        // SettingsStore -> ScreenRecordingStudio
        settings.recordingCameraAspectRatio = .fullSensor
        XCTAssertEqual(studio.cameraAspectRatio, .fullSensor)

        // ScreenRecordingStudio -> SettingsStore
        studio.cameraAspectRatio = .widescreen16x9
        XCTAssertEqual(settings.recordingCameraAspectRatio, .widescreen16x9)

        // Persistence round-trip via UserDefaults
        studio.cameraAspectRatio = .fullSensor
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.recordingCameraAspectRatio, .fullSensor)
    }

    func testTakeBundleDiscoveryAndHandoffIncludeCompanionTracks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatchBundle-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Take-4K", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let screenURL = folder.appendingPathComponent("Take-4K-screen.mp4")
        let cameraURL = folder.appendingPathComponent("Take-4K-camera.mp4")
        let micURL = folder.appendingPathComponent("Take-4K-mic.wav")
        let sysURL = folder.appendingPathComponent("Take-4K-system-audio.wav")
        for url in [screenURL, cameraURL, micURL, sysURL] {
            try Data("stub".utf8).write(to: url)
        }

        let discovered = TakeReviewWindowController.discoverBundle(for: screenURL)
        XCTAssertEqual(discovered.takeDirectoryURL?.standardizedFileURL, folder.standardizedFileURL)
        XCTAssertEqual(discovered.screenVideoURL?.lastPathComponent, "Take-4K-screen.mp4")
        XCTAssertEqual(discovered.cameraVideoURL?.lastPathComponent, "Take-4K-camera.mp4")
        XCTAssertEqual(discovered.microphoneStemURL?.lastPathComponent, "Take-4K-mic.wav")
        XCTAssertEqual(discovered.systemAudioStemURL?.lastPathComponent, "Take-4K-system-audio.wav")
        XCTAssertTrue(discovered.hasMultipleAssets)

        // Verify handoff JSON captures companion track filenames alongside script & edit notes.
        let bridge = LocalStudioBridge.shared
        let prevNotes = bridge.editNotes
        defer {
            bridge.editNotes = prevNotes
            bridge.includeNotesInNextTake = false
        }
        bridge.editNotes = "Cut to 4K camera on intro"
        bridge.includeNotesInNextTake = true
        bridge.snapshotForTake()
        try bridge.saveHandoff(for: screenURL, bundle: discovered)

        let handoffURL = screenURL.deletingPathExtension().appendingPathExtension("handoff.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: handoffURL)) as? [String: Any])
        XCTAssertEqual(json["camera_mp4"] as? String, "Take-4K-camera.mp4")
        XCTAssertEqual(json["screen_mp4"] as? String, "Take-4K-screen.mp4")
        XCTAssertEqual(json["mic_wav"] as? String, "Take-4K-mic.wav")
        XCTAssertEqual(json["system_audio_wav"] as? String, "Take-4K-system-audio.wav")
        XCTAssertEqual(json["edit_notes"] as? String, "Cut to 4K camera on intro")
    }

    // MARK: - Clock Epoch Alignment, Zero-Frame Jump Recovery & Captions Extraction

    func testStreamClockNormalizerHandlesZeroInitialFrameAndOffEpochStreams() throws {
        let hostClock = CMClockGetHostTimeClock()

        // 1. Exact 164E2E failure mode: frame 0 arrives with bogus PTS=0.0 while host time is ~85,290s,
        //    and frame 1+ arrives on HostTimeClock (~85,290.178s).
        var normalizer = StreamClockNormalizer()
        let t0 = try XCTUnwrap(normalizer.normalizePTS(
            rawPTS: .zero,
            sessionClock: hostClock,
            portClock: hostClock,
            hostClock: hostClock,
            hostNow: CMTime(seconds: 85_290.140, preferredTimescale: 1_000_000_000)
        ))
        let t1 = try XCTUnwrap(normalizer.normalizePTS(
            rawPTS: CMTime(seconds: 85_290.178, preferredTimescale: 1_000_000_000),
            sessionClock: hostClock,
            portClock: hostClock,
            hostClock: hostClock,
            hostNow: CMTime(seconds: 85_290.190, preferredTimescale: 1_000_000_000)
        ))
        let t2 = try XCTUnwrap(normalizer.normalizePTS(
            rawPTS: CMTime(seconds: 85_290.220, preferredTimescale: 1_000_000_000),
            sessionClock: hostClock,
            portClock: hostClock,
            hostClock: hostClock,
            hostNow: CMTime(seconds: 85_290.232, preferredTimescale: 1_000_000_000)
        ))

        XCTAssertEqual(t0.seconds, 85_290.140, accuracy: 0.005)
        XCTAssertEqual(t1.seconds, 85_290.178, accuracy: 0.005)
        XCTAssertEqual(t2.seconds, 85_290.220, accuracy: 0.005)
        XCTAssertEqual(t2.seconds - t0.seconds, 0.080, accuracy: 0.01)

        // 2. Off-epoch device stream (e.g., video at t=1357s while host clock is at t=85327s)
        //    rebases smoothly onto host time and preserves exact inter-frame spacing.
        var offEpoch = StreamClockNormalizer()
        let o0 = try XCTUnwrap(offEpoch.normalizePTS(
            rawPTS: CMTime(seconds: 1_357.000, preferredTimescale: 600),
            sessionClock: nil,
            portClock: nil,
            hostClock: hostClock,
            hostNow: CMTime(seconds: 85_327.000, preferredTimescale: 600)
        ))
        let o1 = try XCTUnwrap(offEpoch.normalizePTS(
            rawPTS: CMTime(seconds: 1_357.033, preferredTimescale: 600),
            sessionClock: nil,
            portClock: nil,
            hostClock: hostClock,
            hostNow: CMTime(seconds: 85_327.040, preferredTimescale: 600)
        ))
        let o2 = try XCTUnwrap(offEpoch.normalizePTS(
            rawPTS: CMTime(seconds: 1_357.066, preferredTimescale: 600),
            sessionClock: nil,
            portClock: nil,
            hostClock: hostClock,
            hostNow: CMTime(seconds: 85_327.070, preferredTimescale: 600)
        ))
        XCTAssertEqual(o0.seconds, 85_327.000, accuracy: 0.005)
        XCTAssertEqual(o1.seconds - o0.seconds, 0.033, accuracy: 0.002)
        XCTAssertEqual(o2.seconds - o1.seconds, 0.033, accuracy: 0.002)
    }

    func testCameraTrackWriterAndStemRecoverFromMismatchedVideoAndAudioClockEpochs() async throws {
        // Test BOTH directions:
        // (1) Video at 1357s, Audio at 85327s (previously created an ~83,970s MP4!)
        // (2) Video at 85327s, Audio at 1357s (previously dropped 100% of audio and failed!)
        let scenarios: [(name: String, videoStart: Double, audioStart: Double)] = [
            ("video1357-audio85327", 1_357.4, 85_327.4),
            ("video85327-audio1357", 85_327.4, 1_357.4)
        ]

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatchEpochMismatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for scenario in scenarios {
            let cameraURL = tempDir.appendingPathComponent("\(scenario.name)-camera.mp4")
            let micStemURL = tempDir.appendingPathComponent("\(scenario.name)-mic.wav")

            let camWriter = try XCTUnwrap(CameraTrackWriter(
                outputURL: cameraURL,
                width: 640,
                height: 360,
                frameRate: 30,
                includeMicrophoneAudio: true,
                preferHEVC: true
            ))
            let stemWriter = try XCTUnwrap(AudioStemWriter(outputURL: micStemURL, channelCount: 1, sampleRate: 48_000))

            let videoBase = CMTime(seconds: scenario.videoStart, preferredTimescale: 600)
            let audioBase = CMTime(seconds: scenario.audioStart, preferredTimescale: 48_000)

            XCTAssertTrue(camWriter.startSession(at: videoBase))
            XCTAssertTrue(stemWriter.startSession(at: videoBase))

            // 0.6s of video (18 frames at 30fps) + 0.6s of 440Hz mono audio (28 * 1024 samples at 48kHz).
            for i in 0..<18 {
                let pts = CMTimeAdd(videoBase, CMTime(value: CMTimeValue(i), timescale: 30))
                camWriter.appendVideo(try makeVideoBuffer(width: 640, height: 360, pts: pts))
            }
            for i in 0..<28 {
                let audioOffset = CMTime(value: CMTimeValue(i * 1024), timescale: 48_000)
                let pts = CMTimeAdd(audioBase, audioOffset)
                let audio = try makeAudioBuffer(
                    pts: pts,
                    frameCount: 1024,
                    channels: 1,
                    toneFrequency: 440,
                    amplitude: 0.45,
                    startSampleIndex: i * 1024
                )
                camWriter.appendAudio(audio)
                stemWriter.append(audio)
            }

            let camResult = await camWriter.finish()
            XCTAssertNil(camResult.failure, "[\(scenario.name)] unexpected failure: \(camResult.failure ?? "")")
            let finalizedCameraURL = try XCTUnwrap(camResult.url)
            let stemFinished = await stemWriter.finish()
            let finalizedStemURL = try XCTUnwrap(stemFinished)

            // Verify short, synchronized, immediately playable HEVC MP4.
            let asset = AVURLAsset(url: finalizedCameraURL)
            let isPlayable = try await asset.load(.isPlayable)
            XCTAssertTrue(isPlayable, "[\(scenario.name)] MP4 should be playable")
            let duration = try await asset.load(.duration).seconds
            XCTAssertGreaterThan(duration, 0.45, "[\(scenario.name)] duration too short")
            XCTAssertLessThan(duration, 1.5, "[\(scenario.name)] duration exploded to \(duration)s!")

            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            XCTAssertEqual(videoTracks.count, 1)
            XCTAssertEqual(audioTracks.count, 1)
            let audioSegments = try await audioTracks[0].load(.segments)
            let firstNonEmptyAudio = try XCTUnwrap(audioSegments.first(where: { !$0.isEmpty }))
            XCTAssertLessThan(firstNonEmptyAudio.timeMapping.target.start.seconds, 0.25, "[\(scenario.name)] audio should start near 0s")

            // Verify 48kHz WAV stem matches video duration.
            let wavFile = try AVAudioFile(forReading: finalizedStemURL)
            XCTAssertEqual(wavFile.fileFormat.sampleRate, 48_000, accuracy: 1.0)
            let wavDuration = Double(wavFile.length) / wavFile.fileFormat.sampleRate
            XCTAssertEqual(wavDuration, duration, accuracy: 0.2)

            // Verify caption audio extraction succeeds cleanly on BOTH HEVC MP4 and WAV stem.
            let extractedMP4 = try await TakeCaptions.extractMixedMonoAudio(from: finalizedCameraURL)
            let extractedMP4Duration = Double(extractedMP4.count) / TakeCaptions.recognitionSampleRate
            XCTAssertEqual(extractedMP4Duration, duration, accuracy: 0.25)
            XCTAssertGreaterThan(extractedMP4.reduce(Float(0)) { max($0, abs($1)) }, 0.2)

            let extractedWAV = try await TakeCaptions.extractMixedMonoAudio(from: finalizedStemURL)
            let extractedWAVDuration = Double(extractedWAV.count) / TakeCaptions.recognitionSampleRate
            XCTAssertEqual(extractedWAVDuration, wavDuration, accuracy: 0.25)
            XCTAssertGreaterThan(extractedWAV.reduce(Float(0)) { max($0, abs($1)) }, 0.2)
        }
    }

    func testCameraTrackWriterRecoversFromZeroInitialFrameToHostClockJump() async throws {
        // Direct reproduction of the 164E2E-camera.mp4 packet pattern:
        // Frame 0 at PTS=0.0s, Frames 1..15 at 85290.178s+ (24fps), Audio at 85290.200s+ (48kHz).
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatchZeroJump-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cameraURL = tempDir.appendingPathComponent("zero-jump-camera.mp4")
        let micStemURL = tempDir.appendingPathComponent("zero-jump-mic.wav")

        let camWriter = try XCTUnwrap(CameraTrackWriter(
            outputURL: cameraURL,
            width: 640,
            height: 360,
            frameRate: 24,
            includeMicrophoneAudio: true,
            preferHEVC: true
        ))
        let stemWriter = try XCTUnwrap(AudioStemWriter(outputURL: micStemURL, channelCount: 1, sampleRate: 48_000))

        XCTAssertTrue(camWriter.startSession(at: .zero))
        XCTAssertTrue(stemWriter.startSession(at: .zero))

        // Bogus frame 0 at t=0.0s
        camWriter.appendVideo(try makeVideoBuffer(width: 640, height: 360, pts: .zero))

        // Subsequent frames jump to host clock ~85,290.178s at 24fps
        let hostEpoch = CMTime(seconds: 85_290.178, preferredTimescale: 600)
        for i in 0..<15 {
            let pts = CMTimeAdd(hostEpoch, CMTime(value: CMTimeValue(i), timescale: 24))
            camWriter.appendVideo(try makeVideoBuffer(width: 640, height: 360, pts: pts))
        }
        for i in 0..<30 {
            let pts = CMTimeAdd(hostEpoch, CMTime(value: CMTimeValue(i * 1024), timescale: 48_000))
            let audio = try makeAudioBuffer(
                pts: pts,
                frameCount: 1024,
                channels: 1,
                toneFrequency: 440,
                amplitude: 0.4,
                startSampleIndex: i * 1024
            )
            camWriter.appendAudio(audio)
            stemWriter.append(audio)
        }

        let camResult = await camWriter.finish()
        XCTAssertNil(camResult.failure, camResult.failure ?? "")
        let finalizedCameraURL = try XCTUnwrap(camResult.url)
        let stemFinished = await stemWriter.finish()
        let finalizedStemURL = try XCTUnwrap(stemFinished)

        let asset = AVURLAsset(url: finalizedCameraURL)
        let isPlayable = try await asset.load(.isPlayable)
        XCTAssertTrue(isPlayable)
        let duration = try await asset.load(.duration).seconds
        XCTAssertGreaterThan(duration, 0.5)
        XCTAssertLessThan(duration, 1.5, "Frame-0 jump must NOT produce a 23.7-hour MP4 (got \(duration)s)")

        let extracted = try await TakeCaptions.extractMixedMonoAudio(from: finalizedCameraURL)
        let extractedDuration = Double(extracted.count) / TakeCaptions.recognitionSampleRate
        XCTAssertGreaterThan(extractedDuration, 0.5)
        XCTAssertLessThan(extractedDuration, 1.5)
        XCTAssertGreaterThan(extracted.reduce(Float(0)) { max($0, abs($1)) }, 0.2)

        let wavFile = try AVAudioFile(forReading: finalizedStemURL)
        let wavDuration = Double(wavFile.length) / wavFile.fileFormat.sampleRate
        XCTAssertEqual(wavDuration, duration, accuracy: 0.25)
    }

    func testPauseResumeProducesContinuousDurationAcrossVideoAudioAndWAVStem() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatchPauseResume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cameraURL = tempDir.appendingPathComponent("pause-camera.mp4")
        let micStemURL = tempDir.appendingPathComponent("pause-mic.wav")

        var simulatedWall = CMTime(seconds: 10_000.0, preferredTimescale: 600)
        let camWriter = try XCTUnwrap(CameraTrackWriter(
            outputURL: cameraURL,
            width: 640,
            height: 360,
            frameRate: 30,
            includeMicrophoneAudio: true,
            preferHEVC: true,
            nowProvider: { simulatedWall }
        ))
        let stemWriter = try XCTUnwrap(AudioStemWriter(
            outputURL: micStemURL,
            channelCount: 1,
            sampleRate: 48_000,
            nowProvider: { simulatedWall }
        ))

        let startPTS = simulatedWall
        XCTAssertTrue(camWriter.startSession(at: startPTS))
        XCTAssertTrue(stemWriter.startSession(at: startPTS))

        // Segment 1: 0.4s (12 video frames, 19 audio buffers)
        for i in 0..<12 {
            let pts = CMTimeAdd(startPTS, CMTime(value: CMTimeValue(i), timescale: 30))
            simulatedWall = pts
            camWriter.appendVideo(try makeVideoBuffer(width: 640, height: 360, pts: pts))
        }
        for i in 0..<19 {
            let pts = CMTimeAdd(startPTS, CMTime(value: CMTimeValue(i * 1024), timescale: 48_000))
            simulatedWall = pts
            let audio = try makeAudioBuffer(pts: pts, frameCount: 1024, channels: 1)
            camWriter.appendAudio(audio)
            stemWriter.append(audio)
        }

        // Simulate a 15-second pause while wall clock advances by 15s and pause offset removes 15s.
        let pauseDuration = CMTime(seconds: 15.0, preferredTimescale: 600)
        let resumeBase = CMTimeAdd(CMTimeAdd(startPTS, CMTime(seconds: 0.4, preferredTimescale: 600)), pauseDuration)

        // Segment 2: 0.4s after resuming
        for i in 0..<12 {
            let livePTS = CMTimeAdd(resumeBase, CMTime(value: CMTimeValue(i), timescale: 30))
            simulatedWall = livePTS
            let raw = try makeVideoBuffer(width: 640, height: 360, pts: livePTS)
            let adjusted = try XCTUnwrap(SampleBufferTimingHelper.subtractingOffset(pauseDuration, from: raw))
            camWriter.appendVideo(adjusted)
        }
        for i in 0..<19 {
            let livePTS = CMTimeAdd(resumeBase, CMTime(value: CMTimeValue(i * 1024), timescale: 48_000))
            simulatedWall = livePTS
            let raw = try makeAudioBuffer(pts: livePTS, frameCount: 1024, channels: 1)
            let adjusted = try XCTUnwrap(SampleBufferTimingHelper.subtractingOffset(pauseDuration, from: raw))
            camWriter.appendAudio(adjusted)
            stemWriter.append(adjusted)
        }

        let camResult = await camWriter.finish()
        XCTAssertNil(camResult.failure, camResult.failure ?? "")
        let finalizedCameraURL = try XCTUnwrap(camResult.url)
        let stemFinished = await stemWriter.finish()
        let finalizedStemURL = try XCTUnwrap(stemFinished)

        let asset = AVURLAsset(url: finalizedCameraURL)
        let isPlayable = try await asset.load(.isPlayable)
        XCTAssertTrue(isPlayable)
        let videoDuration = try await asset.load(.duration).seconds
        XCTAssertEqual(videoDuration, 0.8, accuracy: 0.2)

        let wavFile = try AVAudioFile(forReading: finalizedStemURL)
        let wavDuration = Double(wavFile.length) / wavFile.fileFormat.sampleRate
        XCTAssertEqual(wavDuration, 0.8, accuracy: 0.2)
    }

    func testTakeCaptionsExtractMixedMonoAudioSurvivesHugeEmptyLeadingGap() async throws {
        // Build a corrupted MP4 mimicking 164E2E-camera.mp4 where AAC audio begins after an 85,290s empty edit gap.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatchHugeGap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let corruptURL = tempDir.appendingPathComponent("huge-leading-gap.mp4")
        let writer = try AVAssetWriter(outputURL: corruptURL, fileType: .mp4)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000
        ])
        audioInput.expectsMediaDataInRealTime = false
        writer.add(audioInput)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let hugeOffset = CMTime(seconds: 85_290.7, preferredTimescale: 48_000)
        for i in 0..<24 {
            while !audioInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            let pts = CMTimeAdd(hugeOffset, CMTime(value: CMTimeValue(i * 1024), timescale: 48_000))
            let buf = try makeAudioBuffer(
                pts: pts,
                frameCount: 1024,
                channels: 1,
                toneFrequency: 440,
                amplitude: 0.5,
                startSampleIndex: i * 1024
            )
            audioInput.append(buf)
        }
        audioInput.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)

        // Extraction must NOT allocate 5.5 GB of silence or hang; it must promptly extract the ~0.5s audio.
        let extracted = try await TakeCaptions.extractMixedMonoAudio(from: corruptURL)
        let extractedDuration = Double(extracted.count) / TakeCaptions.recognitionSampleRate
        XCTAssertGreaterThan(extractedDuration, 0.35)
        XCTAssertLessThan(extractedDuration, 1.5)
        XCTAssertGreaterThan(extracted.reduce(Float(0)) { max($0, abs($1)) }, 0.2)
    }

    // MARK: - Continuity Camera Burst, Unknown Audio Layout & Diagnostics Regressions

    private func makeVideoBufferWithNumericDTS(
        width: Int = 640,
        height: Int = 360,
        pts: CMTime,
        dts: CMTime,
        duration: CMTime = CMTime(value: 1667, timescale: 100_000)
    ) throws -> CMSampleBuffer {
        let pixelBuffer = try XCTUnwrap(ScreenRecordingStudio.makeSolidPixelBuffer(width: width, height: height))
        var formatDesc: CMVideoFormatDescription?
        let fmtStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc
        )
        XCTAssertEqual(fmtStatus, noErr)
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: pts,
            decodeTimeStamp: dts
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: try XCTUnwrap(formatDesc),
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(sampleBuffer)
    }

    private func makeAudioBufferWithUnknownChannelLayout(
        pts: CMTime,
        frameCount: Int = 512,
        channels: UInt32 = 2
    ) throws -> CMSampleBuffer {
        let bytesPerFrame = channels * 4
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var layout = AudioChannelLayout(
            mChannelLayoutTag: kAudioChannelLayoutTag_Unknown | channels,
            mChannelBitmap: [],
            mNumberChannelDescriptions: 0,
            mChannelDescriptions: AudioChannelDescription()
        )
        var formatDesc: CMAudioFormatDescription?
        let fmtStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: MemoryLayout<AudioChannelLayout>.size,
            layout: &layout,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        XCTAssertEqual(fmtStatus, noErr)

        let byteCount = Int(bytesPerFrame) * frameCount
        var blockBuffer: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        ), noErr)
        if let block = blockBuffer {
            _ = CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDesc,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ), noErr)
        return try XCTUnwrap(sampleBuffer)
    }

    func testStreamClockNormalizerSubMillisecondContinuityBurstNeverCollapsesToDuplicatePTS() throws {
        // Continuity Camera delivers initial buffered frames 0.6ms-0.9ms apart in wall time.
        // Previously `CMTime(seconds: max(0.001, wallDelta), preferredTimescale: 600)` truncated
        // to `0/600`, collapsing jump-clamped frames to identical PTS (triggering AVAssetWriter -11800 / -16364).
        let hostClock = CMClockGetHostTimeClock()
        var normalizer = StreamClockNormalizer()

        let t0 = try XCTUnwrap(normalizer.normalizePTS(
            rawPTS: CMTime(value: 8_757_354_649, timescale: 100_000),
            sessionClock: hostClock,
            portClock: hostClock,
            hostClock: hostClock,
            hostNow: CMTime(seconds: 87_573.8694, preferredTimescale: 1_000_000_000)
        ))
        // Simulate an abrupt jump (> 10s) arriving only 0.7ms later in host wall time.
        let t1 = try XCTUnwrap(normalizer.normalizePTS(
            rawPTS: CMTime(seconds: 87_595.0, preferredTimescale: 100_000),
            sessionClock: nil,
            portClock: nil,
            hostClock: hostClock,
            hostNow: CMTime(seconds: 87_573.8701, preferredTimescale: 1_000_000_000)
        ))
        XCTAssertGreaterThan(CMTimeCompare(t1, t0), 0, "Jump-clamped burst frame must strictly advance beyond previous PTS")

        // Verify replacingPTS clears numeric DTS on uncompressed capture frames and sets PTS directly.
        let rawPTS = CMTime(value: 26_272_068_947, timescale: 300_000)
        let sample = try makeVideoBufferWithNumericDTS(pts: rawPTS, dts: rawPTS)
        let target = CMTime(value: 16_666_670, timescale: 1_000_000_000)
        let rebased = try XCTUnwrap(SampleBufferTimingHelper.replacingPTS(target, in: sample, clearDecodeTimeStamp: true))
        XCTAssertEqual(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(rebased), target), 0)
        XCTAssertFalse(CMSampleBufferGetDecodeTimeStamp(rebased).isValid)
    }

    func testCameraTrackWriterAndWAVStemSanitizeUnknownAudioChannelLayoutAndContinuityVideoTiming() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatchUnknownLayout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // First prove that raw AVAssetWriter fails with AVFoundationErrorDomain -11800 / OSStatus 560360820
        // when fed kAudioChannelLayoutTag_Unknown without sanitization.
        let rawURL = tempDir.appendingPathComponent("raw-fail.mp4")
        let rawWriter = try AVAssetWriter(outputURL: rawURL, fileType: .mp4)
        let rawAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 160_000
        ])
        rawAudioInput.expectsMediaDataInRealTime = true
        rawWriter.add(rawAudioInput)
        XCTAssertTrue(rawWriter.startWriting())
        rawWriter.startSession(atSourceTime: .zero)
        let rawSample = try makeAudioBufferWithUnknownChannelLayout(pts: .zero, channels: 2)
        XCTAssertFalse(rawAudioInput.append(rawSample))
        let formattedErr = AssetWriterDiagnostics.formatError(rawWriter, stage: "Camera audio append", fallback: "Rejected")
        XCTAssertTrue(formattedErr.contains("Camera audio append:"))
        XCTAssertTrue(formattedErr.contains("AVFoundationErrorDomain -11800"), "Expected domain/code in: \(formattedErr)")
        XCTAssertTrue(formattedErr.contains("560360820"), "Expected underlying OSStatus in: \(formattedErr)")
        rawWriter.cancelWriting()

        // Now verify CameraTrackWriter + AudioStemWriter sanitize unknown channel layout AND handle
        // Continuity Camera numeric DTS + mixed 100_000 / 300_000 timescales cleanly!
        let cameraURL = tempDir.appendingPathComponent("sanitized-camera.mp4")
        let micStemURL = tempDir.appendingPathComponent("sanitized-mic.wav")

        let camWriter = try XCTUnwrap(CameraTrackWriter(
            outputURL: cameraURL,
            width: 640,
            height: 360,
            frameRate: 60,
            includeMicrophoneAudio: true,
            preferHEVC: true
        ))
        let stemWriter = try XCTUnwrap(AudioStemWriter(outputURL: micStemURL, channelCount: 1, sampleRate: 48_000))

        let baseSec = 87_573.54649
        let startPTS = CMTime(seconds: baseSec, preferredTimescale: 1_000_000_000)
        XCTAssertTrue(camWriter.startSession(at: startPTS))
        XCTAssertTrue(stemWriter.startSession(at: startPTS))

        // Feed 15 Continuity-Camera-style frames with numeric DTS == PTS and alternating 100k/300k timescales
        for i in 0..<15 {
            let ts: CMTimeScale = (i % 2 == 0) ? 100_000 : 300_000
            let pts = CMTime(value: CMTimeValue((baseSec + Double(i) / 30.0) * Double(ts)), timescale: ts)
            let frame = try makeVideoBufferWithNumericDTS(pts: pts, dts: pts)
            camWriter.appendVideo(frame)
        }
        // Feed 30 stereo audio buffers carrying kAudioChannelLayoutTag_Unknown
        for i in 0..<30 {
            let pts = CMTimeAdd(startPTS, CMTime(value: CMTimeValue(i * 512), timescale: 48_000))
            let audio = try makeAudioBufferWithUnknownChannelLayout(pts: pts, frameCount: 512, channels: 2)
            camWriter.appendAudio(audio)
            stemWriter.append(audio)
        }

        let camResult = await camWriter.finish()
        XCTAssertNil(camResult.failure, camResult.failure ?? "")
        let finalCameraURL = try XCTUnwrap(camResult.url)
        let stemFinished = await stemWriter.finish()
        let finalStemURL = try XCTUnwrap(stemFinished)

        let asset = AVURLAsset(url: finalCameraURL)
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
        let duration = try await asset.load(.duration).seconds
        XCTAssertGreaterThan(duration, 0.25)
        XCTAssertLessThan(duration, 1.5)

        let wavFile = try AVAudioFile(forReading: finalStemURL)
        XCTAssertEqual(wavFile.fileFormat.sampleRate, 48_000, accuracy: 1.0)
        XCTAssertEqual(wavFile.fileFormat.channelCount, 1)
    }

    func testAssetWriterDiagnosticsFormatsStageDomainCodeAndUnderlyingOSStatus() {
        let underlying = NSError(domain: NSOSStatusErrorDomain, code: -16364, userInfo: nil)
        let top = NSError(
            domain: AVFoundationErrorDomain,
            code: -11800,
            userInfo: [
                NSLocalizedDescriptionKey: "The operation could not be completed",
                NSLocalizedFailureReasonErrorKey: "An unknown error occurred (-16364)",
                NSUnderlyingErrorKey: underlying
            ]
        )
        let formatted = AssetWriterDiagnostics.formatNSError(top, stage: "Camera finishWriting")
        XCTAssertTrue(formatted.contains("Camera finishWriting:"))
        XCTAssertTrue(formatted.contains("AVFoundationErrorDomain -11800"))
        XCTAssertTrue(formatted.contains("NSOSStatusErrorDomain -16364"))
        XCTAssertTrue(formatted.contains("An unknown error occurred (-16364)"))
    }
}
