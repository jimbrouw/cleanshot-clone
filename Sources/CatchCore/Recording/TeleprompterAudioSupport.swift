import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import NaturalLanguage
import Speech

/// CoreAudio device routing, multi-channel mono downmix tap formatting, and RMS metering
/// for Catch's teleprompter audio engines.
///
/// Audio routing and tap formatting patterns adapted in part from Textream
/// (MIT License, Copyright (c) 2026 Fatih Kadir Akin).
enum TeleprompterAudioRouting {
    private static let captureBuffersPerSecond = 40.0

    /// Returns a mono capture format preserving the hardware sample rate so multi-channel
    /// USB interfaces never trigger an uncaught AVFAudio sample-rate mismatch exception.
    static func monoCaptureFormat(for hardwareFormat: AVAudioFormat) -> AVAudioFormat? {
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else { return nil }
        guard hardwareFormat.channelCount > 1 else { return hardwareFormat }
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: hardwareFormat.sampleRate,
            channels: 1,
            interleaved: false
        )
    }

    static func captureBufferSize(for format: AVAudioFormat) -> AVAudioFrameCount {
        AVAudioFrameCount(max(1024, format.sampleRate / captureBuffersPerSecond))
    }

    /// Resolves an AVCaptureDevice uniqueID / CoreAudio UID to its AudioDeviceID if it has input streams.
    static func coreAudioInputDeviceID(forUID targetUID: String) -> AudioDeviceID? {
        guard !targetUID.isEmpty else { return nil }

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            0,
            nil,
            &dataSize
        ) == noErr, dataSize > 0 else {
            return nil
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        ) == noErr else {
            return nil
        }

        for deviceID in deviceIDs {
            var streamsAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &streamsAddress, 0, nil, &streamSize) == noErr,
                  streamSize > 0 else { continue }

            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var cfUID: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            let status = withUnsafeMutablePointer(to: &cfUID) { ptr in
                AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, ptr)
            }
            if status == noErr, (cfUID as String) == targetUID {
                return deviceID
            }
        }
        return nil
    }

    /// Binds `engine.inputNode` to the selected microphone UID when present and available.
    /// Returns true if an explicit device override was applied.
    @discardableResult
    static func applyPreferredInputDevice(to engine: AVAudioEngine, preferredUID: String?) -> Bool {
        guard let preferredUID,
              !preferredUID.isEmpty,
              let deviceID = coreAudioInputDeviceID(forUID: preferredUID),
              let audioUnit = engine.inputNode.audioUnit else {
            return false
        }
        var mutableID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { return false }
        AudioUnitUninitialize(audioUnit)
        AudioUnitInitialize(audioUnit)
        return true
    }

    /// Computes a normalized [0, 1] RMS audio level from a Float32 PCM buffer.
    static func rmsLevel(from buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<frameCount {
            let sample = channelData[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameCount))
        return CGFloat(min(1.0, max(0.0, rms * 5.0)))
    }
}

/// Detects the dominant spoken language of a teleprompter script (ignoring bracketed stage cues)
/// and maps it to a supported speech recognition locale.
enum TeleprompterLanguageDetector {
    static func preferredLocale(
        for script: String,
        supportedLocales: Set<Locale> = SFSpeechRecognizer.supportedLocales(),
        fallback: Locale = Locale(identifier: "en-US")
    ) -> Locale {
        let scrubbed = script.replacingOccurrences(
            of: "\\[[^\\[\\]]*\\]",
            with: " ",
            options: .regularExpression
        )
        let sample = String(scrubbed.prefix(4_000))
        guard sample.lazy.filter(\.isLetter).prefix(20).count == 20 else {
            return closestSupportedLocale(to: fallback, in: supportedLocales) ?? fallback
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let dominant = recognizer.dominantLanguage,
              dominant != .undetermined,
              let confidence = recognizer.languageHypotheses(withMaximum: 3)[dominant],
              confidence >= 0.72 else {
            return closestSupportedLocale(to: fallback, in: supportedLocales) ?? fallback
        }

        let detected = Locale(identifier: dominant.rawValue)
        return closestSupportedLocale(to: detected, in: supportedLocales) ?? fallback
    }

    static func closestSupportedLocale(to desired: Locale, in supported: Set<Locale>) -> Locale? {
        guard !supported.isEmpty else { return nil }
        let normalizedTarget = desired.identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        let sorted = supported.sorted { $0.identifier < $1.identifier }
        if let exact = sorted.first(where: {
            $0.identifier.replacingOccurrences(of: "_", with: "-").lowercased() == normalizedTarget
        }) {
            return exact
        }
        guard let targetCode = desired.language.languageCode?.identifier else { return nil }
        let candidates = sorted.filter { $0.language.languageCode?.identifier == targetCode }
        guard !candidates.isEmpty else { return nil }

        let currentRegion = Locale.current.region?.identifier
        let desiredRegion = desired.region?.identifier
        return candidates.max { lhs, rhs in
            score(lhs, desiredRegion: desiredRegion, currentRegion: currentRegion)
                < score(rhs, desiredRegion: desiredRegion, currentRegion: currentRegion)
        }
    }

    private static func score(_ locale: Locale, desiredRegion: String?, currentRegion: String?) -> Int {
        var total = 0
        if let desiredRegion, locale.region?.identifier == desiredRegion { total += 100 }
        if let currentRegion, locale.region?.identifier == currentRegion { total += 50 }
        if locale.region?.identifier == "US" { total += 10 }
        return total
    }
}
