import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

// MARK: - Camera Recording Mode & Take Bundle

public enum CameraRecordingMode: String, Codable, CaseIterable, Sendable {
    /// Floating camera bubble composited directly into the screen recording (Loom style).
    case floatingBubble
    /// Separate full-resolution HEVC camera MP4 with synced audio; hides bubble from screen recording (Riverside style).
    case separateFullResFile

    public var label: String {
        switch self {
        case .floatingBubble: return "Loom Bubble"
        case .separateFullResFile: return "Separate 4K File"
        }
    }

    public var settingsLabel: String {
        switch self {
        case .floatingBubble: return "Floating Bubble (Loom style)"
        case .separateFullResFile: return "Separate Full-Res HEVC File (Clean Screen + Camera ISO)"
        }
    }

    public var symbol: String {
        switch self {
        case .floatingBubble: return "pip"
        case .separateFullResFile: return "film.stack"
        }
    }
}

public enum CameraAspectRatioPreference: String, Codable, CaseIterable, Sendable {
    /// Standard 16:9 widescreen aspect ratio (1920×1080 on Continuity Camera, 3840×2160 on 4K cameras).
    case widescreen16x9
    /// Largest full-sensor resolution available (including 4:3 / open-gate such as 1920×1440 or 4096×3072).
    case fullSensor

    public var label: String {
        switch self {
        case .widescreen16x9: return "16:9"
        case .fullSensor: return "Full Sensor"
        }
    }

    public var settingsLabel: String {
        switch self {
        case .widescreen16x9: return "16:9 Widescreen (1080p / 4K)"
        case .fullSensor: return "Full Sensor (Max / 4:3)"
        }
    }
}

public struct RecordedTakeBundle: Codable, Equatable, Sendable {
    public let primaryVideoURL: URL
    public let screenVideoURL: URL?
    public let cameraVideoURL: URL?
    public let cameraResolution: String?
    public let microphoneStemURL: URL?
    public let systemAudioStemURL: URL?
    public let takeDirectoryURL: URL?

    public init(
        primaryVideoURL: URL,
        screenVideoURL: URL? = nil,
        cameraVideoURL: URL? = nil,
        cameraResolution: String? = nil,
        microphoneStemURL: URL? = nil,
        systemAudioStemURL: URL? = nil,
        takeDirectoryURL: URL? = nil
    ) {
        self.primaryVideoURL = primaryVideoURL
        self.screenVideoURL = screenVideoURL
        self.cameraVideoURL = cameraVideoURL
        self.cameraResolution = cameraResolution
        self.microphoneStemURL = microphoneStemURL
        self.systemAudioStemURL = systemAudioStemURL
        self.takeDirectoryURL = takeDirectoryURL
    }

    public var hasMultipleAssets: Bool {
        var count = 0
        if screenVideoURL != nil { count += 1 }
        if cameraVideoURL != nil { count += 1 }
        if microphoneStemURL != nil { count += 1 }
        if systemAudioStemURL != nil { count += 1 }
        return count > 1
    }

    public var allAssetURLs: [URL] {
        var urls: [URL] = []
        if let screenVideoURL { urls.append(screenVideoURL) }
        if let cameraVideoURL, cameraVideoURL != screenVideoURL { urls.append(cameraVideoURL) }
        if let microphoneStemURL { urls.append(microphoneStemURL) }
        if let systemAudioStemURL { urls.append(systemAudioStemURL) }
        if urls.isEmpty { urls.append(primaryVideoURL) }
        return urls
    }
}

// MARK: - Max-Resolution Camera Format Selector

public struct CameraFormatCandidate: Equatable, Sendable {
    public let index: Int
    public let width: Int
    public let height: Int
    public let minFrameRate: Double
    public let maxFrameRate: Double
    public let mediaSubType: FourCharCode

    public init(
        index: Int,
        width: Int,
        height: Int,
        minFrameRate: Double,
        maxFrameRate: Double,
        mediaSubType: FourCharCode
    ) {
        self.index = index
        self.width = width
        self.height = height
        self.minFrameRate = minFrameRate
        self.maxFrameRate = maxFrameRate
        self.mediaSubType = mediaSubType
    }

    public var pixelCount: Int { width * height }

    public var resolutionLabel: String {
        if width >= 3840 || height >= 2160 {
            return "4K · \(width)×\(height)"
        }
        return "\(width)×\(height)"
    }
}

public struct SelectedCameraFormat: Equatable, Sendable {
    public let candidate: CameraFormatCandidate
    public let targetFrameRate: Double

    public var encodedWidth: Int { max(2, (candidate.width / 2) * 2) }
    public var encodedHeight: Int { max(2, (candidate.height / 2) * 2) }
    public var badgeText: String {
        "\(candidate.resolutionLabel) · \(Int(targetFrameRate.rounded()))fps"
    }
}

public enum CameraFormatSelector {
    /// Preferred uncompressed video pixel formats for fast hardware VideoToolbox HEVC encoding.
    private static let pixelFormatPreference: [FourCharCode] = [
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_422YpCbCr8,
        kCVPixelFormatType_422YpCbCr8_yuvs,
        kCVPixelFormatType_32BGRA
    ]

    /// Picks the highest-resolution format (up to 4K or largest full-sensor aspect ratio)
    /// that can sustain smooth video frame rates (>= 24 fps when available).
    public static func selectBestFormat(
        from candidates: [CameraFormatCandidate],
        preferredFrameRate: Double = 30.0,
        aspectRatio: CameraAspectRatioPreference = .fullSensor
    ) -> SelectedCameraFormat? {
        let valid = candidates.filter { $0.width > 0 && $0.height > 0 && $0.maxFrameRate > 0 }
        guard !valid.isEmpty else { return nil }

        let desiredFPS = max(24.0, min(60.0, preferredFrameRate))
        let smoothVideoCandidates = valid.filter { $0.maxFrameRate >= 23.9 }
        let smoothPool = smoothVideoCandidates.isEmpty ? valid : smoothVideoCandidates

        let aspectPool: [CameraFormatCandidate]
        switch aspectRatio {
        case .widescreen16x9:
            let targetRatio = 16.0 / 9.0
            let widescreen = smoothPool.filter { candidate in
                let ratio = Double(candidate.width) / Double(candidate.height)
                return abs(ratio - targetRatio) <= 0.04
            }
            aspectPool = widescreen.isEmpty ? smoothPool : widescreen
        case .fullSensor:
            aspectPool = smoothPool
        }

        // Prefer standard uncompressed YUV/BGRA formats if available, falling back to any format.
        let standardPixelPool = aspectPool.filter { pixelFormatPreference.contains($0.mediaSubType) }
        let rankedPool = standardPixelPool.isEmpty ? aspectPool : standardPixelPool

        guard let best = rankedPool.max(by: { lhs, rhs in
            // 1. Largest total pixel area (4K 3840x2160 or full open-gate sensor resolution wins).
            if lhs.pixelCount != rhs.pixelCount {
                return lhs.pixelCount < rhs.pixelCount
            }
            // 2. Prefer format that can hit >= 30 fps (or preferredFPS) at that max resolution.
            let lhsMeets30 = lhs.maxFrameRate >= 29.9
            let rhsMeets30 = rhs.maxFrameRate >= 29.9
            if lhsMeets30 != rhsMeets30 {
                return !lhsMeets30 && rhsMeets30
            }
            let lhsMeetsPreferred = lhs.maxFrameRate >= desiredFPS - 0.1
            let rhsMeetsPreferred = rhs.maxFrameRate >= desiredFPS - 0.1
            if lhsMeetsPreferred != rhsMeetsPreferred {
                return !lhsMeetsPreferred && rhsMeetsPreferred
            }
            // 3. Higher max frame rate (capped at 60 fps so 240fps slo-mo doesn't beat 60fps).
            let lhsFPS = min(lhs.maxFrameRate, 60.0)
            let rhsFPS = min(rhs.maxFrameRate, 60.0)
            if abs(lhsFPS - rhsFPS) > 0.1 {
                return lhsFPS < rhsFPS
            }
            // 4. Preferred VideoToolbox pixel format.
            let lhsRank = pixelFormatPreference.firstIndex(of: lhs.mediaSubType) ?? pixelFormatPreference.count
            let rhsRank = pixelFormatPreference.firstIndex(of: rhs.mediaSubType) ?? pixelFormatPreference.count
            return lhsRank > rhsRank
        }) else {
            return nil
        }

        // For 4K+ formats, default to min(desiredFPS, best.maxFrameRate) clamped to supported range.
        let clampedFPS = max(best.minFrameRate, min(desiredFPS, best.maxFrameRate))
        return SelectedCameraFormat(candidate: best, targetFrameRate: clampedFPS)
    }

    public static func extractCandidates(from device: AVCaptureDevice) -> [CameraFormatCandidate] {
        device.formats.enumerated().compactMap { index, format in
            let desc = format.formatDescription
            guard CMFormatDescriptionGetMediaType(desc) == kCMMediaType_Video else { return nil }
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            guard dims.width > 0, dims.height > 0 else { return nil }
            let ranges = format.videoSupportedFrameRateRanges
            guard !ranges.isEmpty else { return nil }
            let minFPS = ranges.map(\.minFrameRate).min() ?? 15.0
            let maxFPS = ranges.map(\.maxFrameRate).max() ?? 30.0
            let subType = CMFormatDescriptionGetMediaSubType(desc)
            return CameraFormatCandidate(
                index: index,
                width: Int(dims.width),
                height: Int(dims.height),
                minFrameRate: minFPS,
                maxFrameRate: maxFPS,
                mediaSubType: subType
            )
        }
    }

    /// Configures the AVCaptureDevice with its highest-resolution video format and returns the chosen spec.
    @discardableResult
    public static func configureMaxResolution(
        for device: AVCaptureDevice,
        preferredFrameRate: Double = 30.0,
        aspectRatio: CameraAspectRatioPreference = .fullSensor
    ) -> SelectedCameraFormat? {
        let candidates = extractCandidates(from: device)
        guard let selected = selectBestFormat(
            from: candidates,
            preferredFrameRate: preferredFrameRate,
            aspectRatio: aspectRatio
        ),
              selected.candidate.index < device.formats.count else {
            return nil
        }

        let format = device.formats[selected.candidate.index]
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.activeFormat = format
            let timescale = CMTimeScale(max(1, Int32((selected.targetFrameRate * 1000).rounded())))
            let frameDuration = CMTime(value: 1000, timescale: timescale)
            // Ensure frameDuration lies within one of the format's supported ranges.
            if let matchingRange = format.videoSupportedFrameRateRanges.first(where: {
                selected.targetFrameRate >= $0.minFrameRate - 0.1 && selected.targetFrameRate <= $0.maxFrameRate + 0.1
            }) {
                let minDuration = CMTimeMaximum(matchingRange.minFrameDuration, frameDuration)
                let clamped = CMTimeMinimum(matchingRange.maxFrameDuration, minDuration)
                device.activeVideoMinFrameDuration = clamped
                device.activeVideoMaxFrameDuration = clamped
            }
            return selected
        } catch {
            return nil
        }
    }

    /// Calculates a crisp HEVC target bitrate scaled to resolution & frame rate.
    public static func recommendedHEVCBitrate(width: Int, height: Int, frameRate: Double) -> Int {
        let pixelsPerSecond = Double(max(320, width) * max(240, height)) * max(15.0, min(60.0, frameRate))
        // ~0.11 bits/pixel for HEVC yields ~27 Mbps at 4K 30fps and ~6.8 Mbps at 1080p 30fps.
        let estimated = Int(pixelsPerSecond * 0.11)
        return max(6_000_000, min(45_000_000, estimated))
    }
}

// MARK: - Dual-Track Sync Barrier (Shared Start PTS across Screen + Camera + Stems)

/// Coordinates sample-accurate session start across Screen and Camera streams.
/// Holds the earliest frame from each stream until both have arrived so every output file
/// (screen MP4, camera HEVC MP4, and WAV audio stems) starts at the exact same `sharedStartPTS`.
struct DualTrackSyncBarrier {
    private(set) var requiresScreen: Bool
    private(set) var requiresCamera: Bool
    private(set) var sharedStartPTS: CMTime?
    private(set) var pendingScreen: (sample: CMSampleBuffer, pts: CMTime)?
    private(set) var pendingCamera: (sample: CMSampleBuffer, pts: CMTime)?

    init(requiresScreen: Bool, requiresCamera: Bool) {
        self.requiresScreen = requiresScreen
        self.requiresCamera = requiresCamera
    }

    var isReady: Bool { sharedStartPTS != nil }

    struct Resolution {
        let startPTS: CMTime
        let initialScreen: (sample: CMSampleBuffer, pts: CMTime)?
        let initialCamera: (sample: CMSampleBuffer, pts: CMTime)?
    }

    mutating func reset(requiresScreen: Bool, requiresCamera: Bool) {
        self.requiresScreen = requiresScreen
        self.requiresCamera = requiresCamera
        self.sharedStartPTS = nil
        self.pendingScreen = nil
        self.pendingCamera = nil
    }

    /// Records an initial video sample before session start. Returns a `Resolution` the moment
    /// all required video sources have delivered at least one valid sample.
    mutating func ingestInitialScreen(_ sample: CMSampleBuffer, pts: CMTime) -> Resolution? {
        guard sharedStartPTS == nil, pts.isValid, pts.isNumeric else { return nil }
        pendingScreen = (sample, pts)
        return resolveIfReady()
    }

    mutating func ingestInitialCamera(_ sample: CMSampleBuffer, pts: CMTime) -> Resolution? {
        guard sharedStartPTS == nil, pts.isValid, pts.isNumeric else { return nil }
        pendingCamera = (sample, pts)
        return resolveIfReady()
    }

    private mutating func resolveIfReady() -> Resolution? {
        if requiresScreen && pendingScreen == nil { return nil }
        if requiresCamera && pendingCamera == nil { return nil }

        let startPTS: CMTime
        switch (pendingScreen?.pts, pendingCamera?.pts) {
        case let (s?, c?):
            startPTS = CMTimeMaximum(s, c)
        case let (s?, nil):
            startPTS = s
        case let (nil, c?):
            startPTS = c
        case (nil, nil):
            return nil
        }

        sharedStartPTS = startPTS
        // Retime the earlier stream's first frame to startPTS if it arrived slightly before the other,
        // or keep it as-is when equal so neither writer starts with an empty leading gap.
        let initialScreen: (CMSampleBuffer, CMTime)? = pendingScreen.flatMap { item in
            if CMTimeCompare(item.pts, startPTS) < 0,
               let shifted = SampleBufferTimingHelper.replacingPTS(startPTS, in: item.sample) {
                return (shifted, startPTS)
            }
            return item
        }
        let initialCamera: (CMSampleBuffer, CMTime)? = pendingCamera.flatMap { item in
            if CMTimeCompare(item.pts, startPTS) < 0,
               let shifted = SampleBufferTimingHelper.replacingPTS(startPTS, in: item.sample) {
                return (shifted, startPTS)
            }
            return item
        }
        pendingScreen = nil
        pendingCamera = nil
        return Resolution(startPTS: startPTS, initialScreen: initialScreen, initialCamera: initialCamera)
    }
}

// MARK: - Asset Writer Diagnostics & Audio Layout Helpers

enum AssetWriterDiagnostics {
    static func formatError(_ writer: AVAssetWriter, stage: String, fallback: String) -> String {
        guard let error = writer.error as NSError? else {
            return "\(stage): \(fallback)"
        }
        return formatNSError(error, stage: stage)
    }

    static func formatNSError(_ error: NSError, stage: String) -> String {
        var details = "\(error.domain) \(error.code)"
        var current: NSError? = error.userInfo[NSUnderlyingErrorKey] as? NSError
        var depth = 0
        while let underlying = current, depth < 4 {
            details += " — \(underlying.domain) \(underlying.code)"
            current = underlying.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        let reasonSuffix: String
        if let reason = error.localizedFailureReason,
           !reason.isEmpty,
           !error.localizedDescription.contains(reason) {
            reasonSuffix = " \(reason)"
        } else {
            reasonSuffix = ""
        }
        return "\(stage): \(error.localizedDescription)\(reasonSuffix) (\(details))"
    }

    static func channelLayoutData(for channelCount: Int) -> Data? {
        let tag: AudioChannelLayoutTag
        switch channelCount {
        case 1:
            tag = kAudioChannelLayoutTag_Mono
        case 2:
            tag = kAudioChannelLayoutTag_Stereo
        default:
            return nil
        }
        var layout = AudioChannelLayout(
            mChannelLayoutTag: tag,
            mChannelBitmap: [],
            mNumberChannelDescriptions: 0,
            mChannelDescriptions: AudioChannelDescription()
        )
        return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
    }
}

// MARK: - Sample Buffer Timing & Clock Normalization Helpers

enum SampleBufferTimingHelper {
    /// Shifts all valid numeric timestamps in `sample` by `delta` (positive or negative).
    static func shiftingTiming(by delta: CMTime, in sample: CMSampleBuffer) -> CMSampleBuffer? {
        guard delta.isValid, delta.isNumeric else { return nil }
        if CMTimeCompare(delta, .zero) == 0 { return sample }
        var count = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr,
              count > 0 else { return nil }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count) == noErr else {
            return nil
        }
        for i in timings.indices {
            if timings[i].presentationTimeStamp.isValid && timings[i].presentationTimeStamp.isNumeric {
                timings[i].presentationTimeStamp = CMTimeAdd(timings[i].presentationTimeStamp, delta)
            }
            if timings[i].decodeTimeStamp.isValid && timings[i].decodeTimeStamp.isNumeric {
                let shiftedDTS = CMTimeAdd(timings[i].decodeTimeStamp, delta)
                if timings[i].presentationTimeStamp.isValid && timings[i].presentationTimeStamp.isNumeric,
                   CMTimeCompare(shiftedDTS, timings[i].presentationTimeStamp) > 0 {
                    timings[i].decodeTimeStamp = timings[i].presentationTimeStamp
                } else {
                    timings[i].decodeTimeStamp = shiftedDTS
                }
            }
        }
        var adjusted: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timings,
            sampleBufferOut: &adjusted
        ) == noErr else { return nil }
        return adjusted
    }

    /// Converts a sample buffer's timestamps from `sourceClock` to `targetClock`.
    static func convertClock(
        of sampleBuffer: CMSampleBuffer,
        from sourceClock: CMClock,
        to targetClock: CMClock
    ) -> CMSampleBuffer? {
        if sourceClock === targetClock { return sampleBuffer }
        var count = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr,
              count > 0 else { return nil }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count) == noErr else {
            return nil
        }
        for i in timings.indices {
            if timings[i].presentationTimeStamp.isValid && timings[i].presentationTimeStamp.isNumeric {
                timings[i].presentationTimeStamp = CMSyncConvertTime(
                    timings[i].presentationTimeStamp,
                    from: sourceClock,
                    to: targetClock
                )
            }
            if timings[i].decodeTimeStamp.isValid && timings[i].decodeTimeStamp.isNumeric {
                timings[i].decodeTimeStamp = CMSyncConvertTime(
                    timings[i].decodeTimeStamp,
                    from: sourceClock,
                    to: targetClock
                )
            }
        }
        var converted: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timings,
            sampleBufferOut: &converted
        ) == noErr else { return nil }
        return converted
    }

    static func subtractingOffset(_ offset: CMTime, from sample: CMSampleBuffer) -> CMSampleBuffer? {
        guard offset.isValid, offset.isNumeric else { return nil }
        guard CMTimeCompare(offset, .zero) != 0 else { return sample }
        return shiftingTiming(by: CMTimeSubtract(.zero, offset), in: sample)
    }

    /// Replaces the presentation timestamp of `sample` with `newPTS`.
    /// For single-timing-entry buffers (all live AVCapture video/audio buffers), sets
    /// `presentationTimeStamp = newPTS` directly to avoid mixed-timescale double rounding
    /// (`CMTimeSubtract` + `CMTimeAdd`), and optionally clears `decodeTimeStamp` to `.invalid`
    /// so uncompressed capture frames (which have no B-frames) never carry skewed or negative DTS.
    static func replacingPTS(
        _ newPTS: CMTime,
        in sample: CMSampleBuffer,
        clearDecodeTimeStamp: Bool = false
    ) -> CMSampleBuffer? {
        guard newPTS.isValid, newPTS.isNumeric else { return nil }
        let currentPTS = CMSampleBufferGetPresentationTimeStamp(sample)
        guard currentPTS.isValid, currentPTS.isNumeric else { return nil }

        var count = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr,
              count > 0 else { return nil }

        if count == 1 {
            var timing = CMSampleTimingInfo()
            guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 1, arrayToFill: &timing, entriesNeededOut: &count) == noErr else {
                return nil
            }
            let dtsNeedsClear = clearDecodeTimeStamp && timing.decodeTimeStamp.isValid
            if CMTimeCompare(newPTS, currentPTS) == 0 && !dtsNeedsClear {
                return sample
            }
            timing.presentationTimeStamp = newPTS
            if clearDecodeTimeStamp {
                timing.decodeTimeStamp = .invalid
            } else if timing.decodeTimeStamp.isValid && timing.decodeTimeStamp.isNumeric {
                let dtsOffset = CMTimeSubtract(timing.decodeTimeStamp, currentPTS)
                let adjustedDTS = CMTimeAdd(newPTS, dtsOffset)
                timing.decodeTimeStamp = CMTimeCompare(adjustedDTS, newPTS) > 0 ? newPTS : adjustedDTS
            }
            var adjusted: CMSampleBuffer?
            guard CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: sample,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleBufferOut: &adjusted
            ) == noErr else { return nil }
            return adjusted
        }

        let delta = CMTimeSubtract(newPTS, currentPTS)
        return shiftingTiming(by: delta, in: sample)
    }

    /// Rebuilds an uncompressed PCM audio `CMSampleBuffer` when its `CMAudioFormatDescription`
    /// advertises `kAudioChannelLayoutTag_Unknown` (which causes `AVAssetWriter` / `AudioConverter`
    /// to fail with `AVFoundationErrorDomain -11800` / `OSStatus 560360820` (`'!dat'`)).
    static func sanitizingAudioChannelLayoutIfNeeded(_ sample: CMSampleBuffer) -> CMSampleBuffer {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sample),
              CMFormatDescriptionGetMediaType(formatDesc) == kCMMediaType_Audio,
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return sample
        }
        var layoutSize = 0
        guard let layoutPtr = CMAudioFormatDescriptionGetChannelLayout(formatDesc, sizeOut: &layoutSize),
              layoutSize >= MemoryLayout<AudioChannelLayoutTag>.size else {
            return sample
        }
        let tag = layoutPtr.pointee.mChannelLayoutTag
        let isUnknownTag = (tag & 0xFFFF_0000) == kAudioChannelLayoutTag_Unknown
        guard isUnknownTag else { return sample }

        var asbd = asbdPtr.pointee
        var magicCookieSize = 0
        let magicCookie = CMAudioFormatDescriptionGetMagicCookie(formatDesc, sizeOut: &magicCookieSize)
        var sanitizedFormat: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: magicCookieSize,
            magicCookie: magicCookie,
            extensions: nil,
            formatDescriptionOut: &sanitizedFormat
        ) == noErr, let cleanFormat = sanitizedFormat else {
            return sample
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sample) else { return sample }
        let numSamples = CMSampleBufferGetNumSamples(sample)
        guard numSamples > 0 else { return sample }

        var timingCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &timingCount) == noErr,
              timingCount > 0 else {
            return sample
        }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: timingCount)
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: timingCount, arrayToFill: &timings, entriesNeededOut: &timingCount) == noErr else {
            return sample
        }

        var sizeCount = 0
        var sampleSizes: [Int] = []
        if CMSampleBufferGetSampleSizeArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &sizeCount) == noErr,
           sizeCount > 0 {
            sampleSizes = [Int](repeating: 0, count: sizeCount)
            if CMSampleBufferGetSampleSizeArray(sample, entryCount: sizeCount, arrayToFill: &sampleSizes, entriesNeededOut: &sizeCount) != noErr {
                sampleSizes = []
            }
        }

        var sanitizedBuffer: CMSampleBuffer?
        let status: OSStatus = sampleSizes.withUnsafeBufferPointer { sizesPtr in
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                formatDescription: cleanFormat,
                sampleCount: numSamples,
                sampleTimingEntryCount: timingCount,
                sampleTimingArray: &timings,
                sampleSizeEntryCount: sampleSizes.count,
                sampleSizeArray: sampleSizes.isEmpty ? nil : sizesPtr.baseAddress,
                sampleBufferOut: &sanitizedBuffer
            )
        }
        return (status == noErr ? sanitizedBuffer : nil) ?? sample
    }
}

/// Normalizes timestamps from a live capture stream onto a single common clock
/// (`CMClockGetHostTimeClock()`). Handles:
/// - CoreMedia clock conversion (`sessionClock` / `portClock` -> `hostClock`),
/// - Uninitialized/bogus initial frame timestamps (such as CMIO frame-0 `PTS = 0.0`
///   followed by `HostTimeClock` timestamps on subsequent frames),
/// - Off-epoch capture devices (virtual/USB cameras or microphones with their own epoch),
/// - Absurd mid-stream clock-epoch jumps relative to elapsed host wall time.
struct StreamClockNormalizer {
    static let hostMatchToleranceSeconds: Double = 5.0
    static let maxAllowedJumpSeconds: Double = 10.0

    private var fallbackEpochOffset: CMTime?
    private var lastOutputPTS: CMTime?
    private var lastWallHostTime: CMTime?

    mutating func reset() {
        fallbackEpochOffset = nil
        lastOutputPTS = nil
        lastWallHostTime = nil
    }

    /// Evaluates authoritative clocks (`sessionClock`, `portClock`, and raw `hostClock`) against `hostNow`.
    static func resolveClockConvertedPTS(
        rawPTS: CMTime,
        sessionClock: CMClock?,
        portClock: CMClock?,
        hostClock: CMClock = CMClockGetHostTimeClock(),
        hostNow: CMTime
    ) -> CMTime? {
        guard rawPTS.isValid, rawPTS.isNumeric, hostNow.isValid, hostNow.isNumeric else { return nil }
        let nowSeconds = hostNow.seconds

        // 1. Prefer session.synchronizationClock when it converts cleanly near hostNow.
        if let sessionClock {
            let converted = (sessionClock === hostClock)
                ? rawPTS
                : CMSyncConvertTime(rawPTS, from: sessionClock, to: hostClock)
            if converted.isValid, converted.isNumeric,
               abs(converted.seconds - nowSeconds) <= hostMatchToleranceSeconds {
                return converted
            }
        }

        // 2. Fallback to the connection's input port clock.
        if let portClock, portClock !== sessionClock {
            let converted = (portClock === hostClock)
                ? rawPTS
                : CMSyncConvertTime(rawPTS, from: portClock, to: hostClock)
            if converted.isValid, converted.isNumeric,
               abs(converted.seconds - nowSeconds) <= hostMatchToleranceSeconds {
                return converted
            }
        }

        // 3. Finally check if rawPTS is already stamped directly on hostClock.
        if abs(rawPTS.seconds - nowSeconds) <= hostMatchToleranceSeconds {
            return rawPTS
        }

        return nil
    }

    /// Computes a normalized PTS on `hostClock` for an incoming sample buffer.
    mutating func normalizePTS(
        rawPTS: CMTime,
        sessionClock: CMClock?,
        portClock: CMClock?,
        hostClock: CMClock = CMClockGetHostTimeClock(),
        hostNow: CMTime? = nil
    ) -> CMTime? {
        guard rawPTS.isValid, rawPTS.isNumeric else { return nil }
        let now = hostNow ?? CMClockGetTime(hostClock)
        guard now.isValid, now.isNumeric else { return rawPTS }

        var targetPTS: CMTime
        if let direct = Self.resolveClockConvertedPTS(
            rawPTS: rawPTS,
            sessionClock: sessionClock,
            portClock: portClock,
            hostClock: hostClock,
            hostNow: now
        ) {
            fallbackEpochOffset = nil
            targetPTS = direct
        } else {
            if let offset = fallbackEpochOffset {
                let shifted = CMTimeAdd(rawPTS, offset)
                if shifted.isValid, shifted.isNumeric,
                   abs(shifted.seconds - now.seconds) <= Self.hostMatchToleranceSeconds {
                    targetPTS = shifted
                } else {
                    fallbackEpochOffset = CMTimeSubtract(now, rawPTS)
                    targetPTS = now
                }
            } else {
                fallbackEpochOffset = CMTimeSubtract(now, rawPTS)
                targetPTS = now
            }
        }

        if let lastPTS = lastOutputPTS, let lastWall = lastWallHostTime {
            let ptsDelta = targetPTS.seconds - lastPTS.seconds
            let wallDelta = max(0.0, now.seconds - lastWall.seconds)
            if abs(ptsDelta - wallDelta) > Self.maxAllowedJumpSeconds {
                // Note: CMTime(seconds: 0.001, preferredTimescale: 600) truncates to 0/600!
                // Use a high-precision timescale and clamp >= 1ms so sub-millisecond Continuity Camera
                // bursts never collapse to a duplicate timestamp (AVFoundationErrorDomain -11800 / -16364).
                let minStep = CMTime(value: 1, timescale: 1_000)
                let computed = CMTime(seconds: max(0.001, wallDelta), preferredTimescale: 60_000)
                let step = CMTimeMaximum(minStep, computed)
                targetPTS = CMTimeAdd(lastPTS, step)
            }
        }

        lastOutputPTS = targetPTS
        lastWallHostTime = now
        return targetPTS
    }

    mutating func normalizeSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        sessionClock: CMClock?,
        portClock: CMClock?,
        hostClock: CMClock = CMClockGetHostTimeClock(),
        hostNow: CMTime? = nil
    ) -> CMSampleBuffer? {
        let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard let targetPTS = normalizePTS(
            rawPTS: rawPTS,
            sessionClock: sessionClock,
            portClock: portClock,
            hostClock: hostClock,
            hostNow: hostNow
        ) else {
            return nil
        }
        return SampleBufferTimingHelper.replacingPTS(targetPTS, in: sampleBuffer, clearDecodeTimeStamp: true)
    }
}

// MARK: - Uncompressed 48 kHz 24-bit WAV Audio Stem Writer

final class AudioStemWriter: @unchecked Sendable {
    static let maxEpochDivergenceSeconds: Double = 5.0
    static let maxMidStreamJumpSeconds: Double = 10.0

    let outputURL: URL
    let channelCount: Int
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let nowProvider: () -> CMTime
    private var sessionStarted = false
    private var sessionStartPTS: CMTime?
    private var audioOriginPTS: CMTime?
    private var lastRelativePTS: CMTime?
    private var lastWallTime: CMTime?
    private(set) var appendedSamples = 0
    private(set) var failure: String?

    init?(
        outputURL: URL,
        channelCount: Int = 1,
        sampleRate: Double = 48_000,
        nowProvider: @escaping () -> CMTime = { CMClockGetTime(CMClockGetHostTimeClock()) }
    ) {
        self.outputURL = outputURL
        self.channelCount = max(1, channelCount)
        self.nowProvider = nowProvider
        try? FileManager.default.removeItem(at: outputURL)
        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .wav) else {
            return nil
        }
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: self.channelCount,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        if let layoutData = AssetWriterDiagnostics.channelLayoutData(for: self.channelCount) {
            settings[AVChannelLayoutKey] = layoutData
        }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        self.writer = writer
        self.input = input
    }

    @discardableResult
    func startSession(at pts: CMTime) -> Bool {
        guard !sessionStarted, pts.isValid, pts.isNumeric else { return sessionStarted }
        guard writer.startWriting() else {
            failure = AssetWriterDiagnostics.formatError(
                writer,
                stage: "WAV startWriting",
                fallback: "Could not start WAV stem writer."
            )
            return false
        }
        writer.startSession(atSourceTime: .zero)
        sessionStartPTS = pts
        audioOriginPTS = nil
        lastRelativePTS = nil
        lastWallTime = nil
        sessionStarted = true
        return true
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard sessionStarted, failure == nil, let sessionStartPTS else { return }
        guard writer.status == .writing else {
            if writer.status == .failed {
                failure = AssetWriterDiagnostics.formatError(
                    writer,
                    stage: "WAV audio append",
                    fallback: "WAV stem writer stopped unexpectedly."
                )
            }
            return
        }
        let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard rawPTS.isValid, rawPTS.isNumeric else { return }
        let now = nowProvider()

        if audioOriginPTS == nil {
            let rawDelta = rawPTS.seconds - sessionStartPTS.seconds
            if rawDelta < 0 && rawDelta >= -0.5 {
                // Slightly pre-session audio on the same clock; drop until >= sessionStartPTS.
                return
            } else if rawDelta >= 0 && rawDelta <= Self.maxEpochDivergenceSeconds {
                audioOriginPTS = sessionStartPTS
            } else {
                // Mismatched clock epoch relative to sessionStartPTS; rebase cleanly to 0.
                audioOriginPTS = rawPTS
            }
        }

        guard let origin = audioOriginPTS else { return }
        var relativePTS = CMTimeSubtract(rawPTS, origin)

        if let lastPTS = lastRelativePTS {
            let ptsDelta = relativePTS.seconds - lastPTS.seconds
            let wallDelta = lastWallTime.map { max(0.0, now.seconds - $0.seconds) } ?? 0.0
            if ptsDelta > max(Self.maxMidStreamJumpSeconds, wallDelta + Self.maxMidStreamJumpSeconds)
                || ptsDelta < -Self.maxEpochDivergenceSeconds {
                let sampleDur = CMSampleBufferGetDuration(sampleBuffer)
                let fallbackStep = (sampleDur.isValid && sampleDur.isNumeric && sampleDur.seconds > 0)
                    ? sampleDur.seconds
                    : 0.02
                let step = CMTimeMaximum(
                    CMTime(value: 1, timescale: 48_000),
                    CMTime(seconds: max(fallbackStep, min(wallDelta, 1.0)), preferredTimescale: 48_000)
                )
                let targetRelative = CMTimeAdd(lastPTS, step)
                audioOriginPTS = CMTimeSubtract(rawPTS, targetRelative)
                relativePTS = targetRelative
            } else if CMTimeCompare(relativePTS, lastPTS) <= 0 {
                return
            }
        } else if CMTimeCompare(relativePTS, .zero) < 0 {
            if relativePTS.seconds >= -0.005 {
                relativePTS = .zero
            } else {
                return
            }
        }

        guard input.isReadyForMoreMediaData else { return }
        let sanitized = SampleBufferTimingHelper.sanitizingAudioChannelLayoutIfNeeded(sampleBuffer)
        guard let rebased = SampleBufferTimingHelper.replacingPTS(relativePTS, in: sanitized, clearDecodeTimeStamp: true) else { return }
        let actualPTS = CMSampleBufferGetPresentationTimeStamp(rebased)
        guard actualPTS.isValid, actualPTS.isNumeric, CMTimeCompare(actualPTS, .zero) >= 0 else { return }
        if let lastPTS = lastRelativePTS, CMTimeCompare(actualPTS, lastPTS) <= 0 { return }

        if input.append(rebased) {
            lastRelativePTS = actualPTS
            lastWallTime = now
            appendedSamples += 1
        } else {
            failure = AssetWriterDiagnostics.formatError(
                writer,
                stage: "WAV audio append",
                fallback: "WAV stem writer rejected an audio sample."
            )
        }
    }

    func finish() async -> URL? {
        guard sessionStarted, appendedSamples > 0, writer.status == .writing else {
            if writer.status == .failed && failure == nil {
                failure = AssetWriterDiagnostics.formatError(
                    writer,
                    stage: "WAV finishWriting",
                    fallback: "WAV stem writer failed before finishing."
                )
            }
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }
        input.markAsFinished()
        return await withCheckedContinuation { continuation in
            writer.finishWriting {
                if self.writer.status == .completed {
                    continuation.resume(returning: self.outputURL)
                } else {
                    if self.failure == nil {
                        self.failure = AssetWriterDiagnostics.formatError(
                            self.writer,
                            stage: "WAV finishWriting",
                            fallback: "Could not finish WAV stem."
                        )
                    }
                    try? FileManager.default.removeItem(at: self.outputURL)
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    func cancel() {
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: outputURL)
    }
}

// MARK: - Full-Resolution HEVC Camera MP4 Writer (with Synced Audio)

final class CameraTrackWriter: @unchecked Sendable {
    static let maxEpochDivergenceSeconds: Double = 5.0
    static let maxMidStreamJumpSeconds: Double = 10.0

    let outputURL: URL
    let width: Int
    let height: Int
    let codec: AVVideoCodecType
    private let expectedFrameDurationSeconds: Double
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let nowProvider: () -> CMTime
    private var sessionStarted = false
    private var sessionStartPTS: CMTime?
    private var sessionStartWallTime: CMTime?
    private var videoOriginPTS: CMTime?
    private var audioOriginPTS: CMTime?
    private var lastVideoRelativePTS: CMTime?
    private var lastAudioRelativePTS: CMTime?
    private var lastVideoWallTime: CMTime?
    private var lastAudioWallTime: CMTime?
    private(set) var appendedVideoFrames = 0
    private(set) var appendedAudioSamples = 0
    private(set) var failure: String?

    var expectsAudio: Bool { audioInput != nil }

    init?(
        outputURL: URL,
        width: Int,
        height: Int,
        frameRate: Double = 30.0,
        includeMicrophoneAudio: Bool,
        preferHEVC: Bool = true,
        nowProvider: @escaping () -> CMTime = { CMClockGetTime(CMClockGetHostTimeClock()) }
    ) {
        self.outputURL = outputURL
        let evenW = max(2, (width / 2) * 2)
        let evenH = max(2, (height / 2) * 2)
        self.width = evenW
        self.height = evenH
        self.expectedFrameDurationSeconds = 1.0 / max(15.0, min(60.0, frameRate))
        self.nowProvider = nowProvider

        try? FileManager.default.removeItem(at: outputURL)
        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else {
            return nil
        }

        let bitrate = CameraFormatSelector.recommendedHEVCBitrate(width: evenW, height: evenH, frameRate: frameRate)
        let selectedCodec: AVVideoCodecType = preferHEVC ? .hevc : .h264

        func makeVideoInput(codec: AVVideoCodecType) -> AVAssetWriterInput {
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: codec == .hevc ? bitrate : min(50_000_000, Int(Double(bitrate) * 1.35)),
                AVVideoAllowFrameReorderingKey: false
            ]
            if codec == .h264 {
                compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            }
            let settings: [String: Any] = [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: evenW,
                AVVideoHeightKey: evenH,
                AVVideoCompressionPropertiesKey: compression
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            return input
        }

        let primaryInput = makeVideoInput(codec: selectedCodec)
        if writer.canAdd(primaryInput) {
            writer.add(primaryInput)
            self.videoInput = primaryInput
            self.codec = selectedCodec
        } else if selectedCodec == .hevc {
            let fallbackInput = makeVideoInput(codec: .h264)
            guard writer.canAdd(fallbackInput) else { return nil }
            writer.add(fallbackInput)
            self.videoInput = fallbackInput
            self.codec = .h264
        } else {
            return nil
        }

        if includeMicrophoneAudio {
            var audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 160_000
            ]
            if let layoutData = AssetWriterDiagnostics.channelLayoutData(for: 1) {
                audioSettings[AVChannelLayoutKey] = layoutData
            }
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(aInput) else { return nil }
            writer.add(aInput)
            self.audioInput = aInput
        } else {
            self.audioInput = nil
        }

        self.writer = writer
    }

    @discardableResult
    func startSession(at pts: CMTime) -> Bool {
        guard !sessionStarted, pts.isValid, pts.isNumeric else { return sessionStarted }
        guard writer.startWriting() else {
            failure = AssetWriterDiagnostics.formatError(
                writer,
                stage: "Camera startWriting",
                fallback: "Could not start the camera video encoder."
            )
            return false
        }
        writer.startSession(atSourceTime: .zero)
        sessionStartPTS = pts
        sessionStartWallTime = nowProvider()
        videoOriginPTS = pts
        audioOriginPTS = nil
        lastVideoRelativePTS = nil
        lastAudioRelativePTS = nil
        lastVideoWallTime = nil
        lastAudioWallTime = nil
        sessionStarted = true
        return true
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard sessionStarted, failure == nil, let origin = videoOriginPTS else { return }
        guard writer.status == .writing else {
            if writer.status == .failed {
                failure = AssetWriterDiagnostics.formatError(
                    writer,
                    stage: "Camera video append",
                    fallback: "Camera video writer stopped unexpectedly."
                )
            }
            return
        }
        let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard rawPTS.isValid, rawPTS.isNumeric else { return }
        let now = nowProvider()

        var relativePTS = CMTimeSubtract(rawPTS, origin)

        if let lastPTS = lastVideoRelativePTS {
            let ptsDelta = relativePTS.seconds - lastPTS.seconds
            let wallDelta = lastVideoWallTime.map { max(0.0, now.seconds - $0.seconds) } ?? 0.0
            if ptsDelta > max(Self.maxMidStreamJumpSeconds, wallDelta + Self.maxMidStreamJumpSeconds)
                || ptsDelta < -Self.maxEpochDivergenceSeconds {
                // Mid-stream video clock epoch jump (e.g. frame 0 at 0.0s, frame 1 at host uptime).
                // Re-anchor videoOriginPTS cleanly so we never emit a multi-hour frozen frame.
                let stepSeconds = max(expectedFrameDurationSeconds, min(wallDelta, 1.0))
                let step = CMTimeMaximum(
                    CMTime(value: 1, timescale: 600),
                    CMTime(seconds: stepSeconds, preferredTimescale: 600)
                )
                let targetRelative = CMTimeAdd(lastPTS, step)
                videoOriginPTS = CMTimeSubtract(rawPTS, targetRelative)
                relativePTS = targetRelative
            } else if CMTimeCompare(relativePTS, lastPTS) <= 0 {
                return
            }
        } else if CMTimeCompare(relativePTS, .zero) < 0 {
            if relativePTS.seconds >= -0.005 {
                relativePTS = .zero
            } else {
                return
            }
        }

        guard videoInput.isReadyForMoreMediaData else { return }
        guard let rebased = SampleBufferTimingHelper.replacingPTS(relativePTS, in: sampleBuffer, clearDecodeTimeStamp: true) else { return }
        let actualPTS = CMSampleBufferGetPresentationTimeStamp(rebased)
        guard actualPTS.isValid, actualPTS.isNumeric, CMTimeCompare(actualPTS, .zero) >= 0 else { return }
        if let lastPTS = lastVideoRelativePTS, CMTimeCompare(actualPTS, lastPTS) <= 0 { return }

        if videoInput.append(rebased) {
            lastVideoRelativePTS = actualPTS
            lastVideoWallTime = now
            appendedVideoFrames += 1
        } else {
            failure = AssetWriterDiagnostics.formatError(
                writer,
                stage: "Camera video append",
                fallback: "Camera video writer rejected a frame."
            )
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard sessionStarted, failure == nil, let audioInput, let sessionStartPTS else { return }
        guard writer.status == .writing else {
            if writer.status == .failed {
                failure = AssetWriterDiagnostics.formatError(
                    writer,
                    stage: "Camera audio append",
                    fallback: "Camera audio writer stopped unexpectedly."
                )
            }
            return
        }
        let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard rawPTS.isValid, rawPTS.isNumeric else { return }
        let now = nowProvider()

        if audioOriginPTS == nil {
            let currentVideoSeconds = lastVideoRelativePTS?.seconds ?? 0.0
            let upperWindow = max(Self.maxEpochDivergenceSeconds, currentVideoSeconds + Self.maxEpochDivergenceSeconds)

            // Check against current videoOriginPTS first (handles frame-0 jump onto real clock),
            // then against original sessionStartPTS.
            if let vOrigin = videoOriginPTS {
                let vDelta = rawPTS.seconds - vOrigin.seconds
                if vDelta < 0 && vDelta >= -0.5 {
                    return
                } else if vDelta >= 0 && vDelta <= upperWindow {
                    audioOriginPTS = vOrigin
                }
            }
            if audioOriginPTS == nil {
                let sDelta = rawPTS.seconds - sessionStartPTS.seconds
                if sDelta < 0 && sDelta >= -0.5 {
                    return
                } else if sDelta >= 0 && sDelta <= upperWindow {
                    audioOriginPTS = sessionStartPTS
                } else {
                    // Audio is on a different clock epoch from video (e.g. device clock vs host clock).
                    // Anchor cleanly to elapsed live session time (clamped to current video timeline).
                    let wallElapsed = sessionStartWallTime.map { max(0.0, now.seconds - $0.seconds) } ?? 0.0
                    let anchorSeconds = max(0.0, min(currentVideoSeconds, wallElapsed))
                    let anchorTime = CMTime(seconds: anchorSeconds, preferredTimescale: 48_000)
                    audioOriginPTS = CMTimeSubtract(rawPTS, anchorTime)
                }
            }
        }

        guard let origin = audioOriginPTS else { return }
        var relativePTS = CMTimeSubtract(rawPTS, origin)

        if let lastPTS = lastAudioRelativePTS {
            let ptsDelta = relativePTS.seconds - lastPTS.seconds
            let wallDelta = lastAudioWallTime.map { max(0.0, now.seconds - $0.seconds) } ?? 0.0
            if ptsDelta > max(Self.maxMidStreamJumpSeconds, wallDelta + Self.maxMidStreamJumpSeconds)
                || ptsDelta < -Self.maxEpochDivergenceSeconds {
                let sampleDur = CMSampleBufferGetDuration(sampleBuffer)
                let fallbackStep = (sampleDur.isValid && sampleDur.isNumeric && sampleDur.seconds > 0)
                    ? sampleDur.seconds
                    : 0.02
                let step = CMTimeMaximum(
                    CMTime(value: 1, timescale: 48_000),
                    CMTime(seconds: max(fallbackStep, min(wallDelta, 1.0)), preferredTimescale: 48_000)
                )
                let targetRelative = CMTimeAdd(lastPTS, step)
                audioOriginPTS = CMTimeSubtract(rawPTS, targetRelative)
                relativePTS = targetRelative
            } else if CMTimeCompare(relativePTS, lastPTS) <= 0 {
                return
            }
        } else if CMTimeCompare(relativePTS, .zero) < 0 {
            if relativePTS.seconds >= -0.005 {
                relativePTS = .zero
            } else {
                return
            }
        }

        guard audioInput.isReadyForMoreMediaData else { return }
        let sanitized = SampleBufferTimingHelper.sanitizingAudioChannelLayoutIfNeeded(sampleBuffer)
        guard let rebased = SampleBufferTimingHelper.replacingPTS(relativePTS, in: sanitized, clearDecodeTimeStamp: true) else { return }
        let actualPTS = CMSampleBufferGetPresentationTimeStamp(rebased)
        guard actualPTS.isValid, actualPTS.isNumeric, CMTimeCompare(actualPTS, .zero) >= 0 else { return }
        if let lastPTS = lastAudioRelativePTS, CMTimeCompare(actualPTS, lastPTS) <= 0 { return }

        if audioInput.append(rebased) {
            lastAudioRelativePTS = actualPTS
            lastAudioWallTime = now
            appendedAudioSamples += 1
        } else {
            failure = AssetWriterDiagnostics.formatError(
                writer,
                stage: "Camera audio append",
                fallback: "Camera audio writer rejected a sample."
            )
        }
    }

    struct FinishResult: Sendable {
        let url: URL?
        let failure: String?
        let allowInterruptedRecovery: Bool
    }

    func finish(interrupted: Bool = false) async -> FinishResult {
        let existingFailure = failure
        let hasAudioIfExpected = (audioInput == nil || appendedAudioSamples > 0)
        if let existingFailure, !(interrupted && writer.status == .writing && sessionStarted && appendedVideoFrames > 0 && hasAudioIfExpected) {
            if writer.status == .writing { writer.cancelWriting() }
            return FinishResult(url: nil, failure: existingFailure, allowInterruptedRecovery: false)
        }
        guard sessionStarted, appendedVideoFrames > 0 else {
            if writer.status == .writing { writer.cancelWriting() }
            return FinishResult(url: nil, failure: existingFailure ?? "Catch received no usable camera frames.", allowInterruptedRecovery: false)
        }
        guard hasAudioIfExpected else {
            if writer.status == .writing { writer.cancelWriting() }
            return FinishResult(url: nil, failure: "Catch received no audio from the selected microphone for the camera recording.", allowInterruptedRecovery: false)
        }
        guard writer.status == .writing else {
            let msg = existingFailure ?? AssetWriterDiagnostics.formatError(
                writer,
                stage: "Camera writer status",
                fallback: "The camera writer stopped unexpectedly."
            )
            return FinishResult(url: nil, failure: msg, allowInterruptedRecovery: false)
        }

        videoInput.markAsFinished()
        audioInput?.markAsFinished()

        return await withCheckedContinuation { continuation in
            writer.finishWriting {
                let completed = self.writer.status == .completed
                if let existingFailure {
                    continuation.resume(returning: FinishResult(
                        url: nil,
                        failure: existingFailure,
                        allowInterruptedRecovery: completed
                    ))
                } else if completed {
                    continuation.resume(returning: FinishResult(
                        url: self.outputURL,
                        failure: nil,
                        allowInterruptedRecovery: false
                    ))
                } else {
                    let msg = AssetWriterDiagnostics.formatError(
                        self.writer,
                        stage: "Camera finishWriting",
                        fallback: "Catch could not finish the camera MP4."
                    )
                    continuation.resume(returning: FinishResult(
                        url: nil,
                        failure: msg,
                        allowInterruptedRecovery: false
                    ))
                }
            }
        }
    }

    func cancel() {
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: outputURL)
    }
}
