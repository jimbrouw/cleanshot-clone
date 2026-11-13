import Foundation
import AppKit
import AVFoundation
import CoreGraphics

/// Available voice option for Read Aloud, sorted with Premium/Enhanced macOS voices first.
public struct ReadAloudVoiceOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let language: String
    public let qualityLabel: String
    public let isHighQuality: Bool

    public init(id: String, name: String, language: String, qualityLabel: String, isHighQuality: Bool) {
        self.id = id
        self.name = name
        self.language = language
        self.qualityLabel = qualityLabel
        self.isHighQuality = isHighQuality
    }
}

/// On-device OCR-to-Speech controller for reading unselectable screen text aloud.
@MainActor
public final class ReadAloudService: NSObject, ObservableObject {
    public static let shared = ReadAloudService()

    @Published public private(set) var isSpeaking: Bool = false
    @Published public private(set) var isPaused: Bool = false
    @Published public private(set) var currentText: String = ""
    @Published public private(set) var spokenRange: NSRange?
    @Published public private(set) var statusMessage: String?
    @Published public var playbackMultiplier: Double = 1.15
    @Published public var selectedVoiceIdentifier: String = ""
    @Published public private(set) var availableVoices: [ReadAloudVoiceOption] = []

    private let synthesizer = AVSpeechSynthesizer()
    private let voiceDefaultsKey = "com.catchapp.readaloud.voiceIdentifier"
    private let rateDefaultsKey = "com.catchapp.readaloud.playbackMultiplier"

    private override init() {
        super.init()
        synthesizer.delegate = self
        if let savedRate = UserDefaults.standard.object(forKey: rateDefaultsKey) as? Double, savedRate >= 0.7, savedRate <= 2.5 {
            playbackMultiplier = savedRate
        }
        reloadVoices()
    }

    /// Reloads available system voices, prioritizing Premium and Enhanced voices over default voices.
    public func reloadVoices() {
        let systemVoices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix("en") }

        let mapped = systemVoices.map { voice -> ReadAloudVoiceOption in
            let qualityLabel: String
            let highQuality: Bool
            switch voice.quality {
            case .premium:
                qualityLabel = "Premium"
                highQuality = true
            case .enhanced:
                qualityLabel = "Enhanced"
                highQuality = true
            default:
                qualityLabel = "Standard"
                highQuality = false
            }
            return ReadAloudVoiceOption(
                id: voice.identifier,
                name: voice.name,
                language: voice.language,
                qualityLabel: qualityLabel,
                isHighQuality: highQuality
            )
        }
        .sorted { lhs, rhs in
            if lhs.isHighQuality != rhs.isHighQuality {
                return lhs.isHighQuality && !rhs.isHighQuality
            }
            if lhs.qualityLabel != rhs.qualityLabel {
                return lhs.qualityLabel == "Premium"
            }
            return lhs.name < rhs.name
        }

        availableVoices = mapped

        if let savedID = UserDefaults.standard.string(forKey: voiceDefaultsKey),
           mapped.contains(where: { $0.id == savedID }) {
            selectedVoiceIdentifier = savedID
        } else if let best = mapped.first {
            selectedVoiceIdentifier = best.id
        }
    }

    public var hasHighQualityVoiceInstalled: Bool {
        availableVoices.contains(where: \.isHighQuality)
    }

    /// Captures a screen region (or interactive area selection), runs Vision OCR, and reads the text aloud.
    public func captureAndReadAloud(rect: CGRect? = nil, displayIndex: Int? = nil) {
        let screen = CaptureEngine.shared.resolveScreen(displayIndex: displayIndex)
        let settings = SettingsStore.shared

        if let rect, rect.width >= 2, rect.height >= 2 {
            let img = CaptureEngine.shared.captureRegionSync(rect: rect, on: screen)
            let result = OCRService.shared.recognizeTextAndQRCodes(
                in: img,
                language: settings.ocrLanguage,
                keepLineBreaks: false,
                detectLinks: settings.ocrDetectLinks,
                copyToClipboard: false
            )
            readOCRResult(result)
            return
        }

        SelectionOverlayController.shared.beginAreaSelection(on: screen, frozenImage: nil, initialRect: nil) { [weak self] selected, _ in
            guard let self, let selected else { return }
            let img = CaptureEngine.shared.captureRegionSync(rect: selected, on: screen)
            let result = OCRService.shared.recognizeTextAndQRCodes(
                in: img,
                language: settings.ocrLanguage,
                keepLineBreaks: false,
                detectLinks: settings.ocrDetectLinks,
                copyToClipboard: false
            )
            Task { @MainActor in
                self.readOCRResult(result)
            }
        }
    }

    public func readOCRResult(_ result: OCRResult) {
        let text = result.combinedClipboardText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            statusMessage = "No readable text found in selection."
            ReadAloudPlayerController.shared.show()
            return
        }
        readText(text)
    }

    /// Speaks arbitrary text immediately using the selected voice and speed.
    public func readText(_ text: String) {
        let cleaned = normalizeTextForSpeech(text)
        guard !cleaned.isEmpty else { return }

        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }

        currentText = cleaned
        spokenRange = nil
        statusMessage = nil

        let utterance = AVSpeechUtterance(string: cleaned)
        if !selectedVoiceIdentifier.isEmpty,
           let voice = AVSpeechSynthesisVoice(identifier: selectedVoiceIdentifier) {
            utterance.voice = voice
        }
        utterance.rate = mappedAVSpeechRate(for: playbackMultiplier)
        utterance.pitchMultiplier = 1.0
        utterance.preUtteranceDelay = 0.05

        isSpeaking = true
        isPaused = false
        ReadAloudPlayerController.shared.show()
        synthesizer.speak(utterance)
    }

    public func togglePlayPause() {
        if synthesizer.isPaused {
            synthesizer.continueSpeaking()
            isPaused = false
            isSpeaking = true
        } else if synthesizer.isSpeaking {
            synthesizer.pauseSpeaking(at: .word)
            isPaused = true
        } else if !currentText.isEmpty {
            readText(currentText)
        }
    }

    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        isPaused = false
        spokenRange = nil
    }

    public func setPlaybackMultiplier(_ multiplier: Double) {
        playbackMultiplier = multiplier
        UserDefaults.standard.set(multiplier, forKey: rateDefaultsKey)
        // Restart from current text so rate change takes effect cleanly.
        if (isSpeaking || isPaused), !currentText.isEmpty {
            let textToReplay = remainingTextFromCurrentPosition() ?? currentText
            readText(textToReplay)
        }
    }

    public func selectVoice(identifier: String) {
        selectedVoiceIdentifier = identifier
        UserDefaults.standard.set(identifier, forKey: voiceDefaultsKey)
        if (isSpeaking || isPaused), !currentText.isEmpty {
            let textToReplay = remainingTextFromCurrentPosition() ?? currentText
            readText(textToReplay)
        }
    }

    public func copyCurrentText() {
        guard !currentText.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(currentText, forType: .string)
        statusMessage = "Copied text to clipboard"
    }

    private func remainingTextFromCurrentPosition() -> String? {
        guard let range = spokenRange,
              let swiftRange = Range(range, in: currentText) else {
            return nil
        }
        let tail = String(currentText[swiftRange.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? nil : tail
    }

    /// Maps a human speed multiplier (0.8x–2.0x) to AVSpeechUtterance's 0.0–1.0 scale.
    public func mappedAVSpeechRate(for multiplier: Double) -> Float {
        let clamped = min(max(multiplier, 0.7), 2.2)
        let scaled = Float(AVSpeechUtteranceDefaultSpeechRate) * Float(0.78 + (clamped - 1.0) * 0.28)
        return min(max(scaled, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    }

    private func normalizeTextForSpeech(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension ReadAloudService: AVSpeechSynthesizerDelegate {
    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.spokenRange = characterRange
        }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.isPaused = false
            self.spokenRange = nil
        }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.isPaused = false
        }
    }
}
