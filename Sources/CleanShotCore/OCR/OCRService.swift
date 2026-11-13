import Foundation
import Vision
import AppKit

public struct OCRResult: Equatable, Sendable {
    public let recognizedText: String
    public let qrPayloads: [String]
    public let detectedLinks: [String]

    public var combinedClipboardText: String {
        if !qrPayloads.isEmpty && recognizedText.isEmpty {
            return qrPayloads.joined(separator: "\n")
        }
        return recognizedText
    }

    public init(recognizedText: String, qrPayloads: [String], detectedLinks: [String]) {
        self.recognizedText = recognizedText
        self.qrPayloads = qrPayloads
        self.detectedLinks = detectedLinks
    }
}

public final class OCRService {
    public static let shared = OCRService()

    public func captureTextFromScreen(rect: CGRect? = nil, displayIndex: Int? = nil, lineBreaks: Bool? = nil) {
        let screen = CaptureEngine.shared.resolveScreen(displayIndex: displayIndex)
        let settings = SettingsStore.shared
        let keepBreaks = lineBreaks ?? settings.ocrKeepLineBreaks

        if let rect, rect.width >= 2, rect.height >= 2 {
            let img = CaptureEngine.shared.captureRegionSync(rect: rect, on: screen)
            let result = recognizeTextAndQRCodes(
                in: img,
                language: settings.ocrLanguage,
                keepLineBreaks: keepBreaks,
                detectLinks: settings.ocrDetectLinks,
                copyToClipboard: true
            )
            showOCRToast(result)
            return
        }

        SelectionOverlayController.shared.beginAreaSelection(on: screen, frozenImage: nil, initialRect: nil) { [weak self] selected, _ in
            guard let self, let selected else { return }
            let img = CaptureEngine.shared.captureRegionSync(rect: selected, on: screen)
            let result = self.recognizeTextAndQRCodes(
                in: img,
                language: settings.ocrLanguage,
                keepLineBreaks: keepBreaks,
                detectLinks: settings.ocrDetectLinks,
                copyToClipboard: true
            )
            self.showOCRToast(result)
        }
    }

    public func captureTextFromFile(url: URL, lineBreaks: Bool? = nil) -> OCRResult? {
        guard let nsImage = NSImage(contentsOf: url),
              let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let settings = SettingsStore.shared
        let res = recognizeTextAndQRCodes(
            in: cg,
            language: settings.ocrLanguage,
            keepLineBreaks: lineBreaks ?? settings.ocrKeepLineBreaks,
            detectLinks: settings.ocrDetectLinks,
            copyToClipboard: true
        )
        showOCRToast(res)
        return res
    }

    public func recognizeTextAndQRCodes(
        in image: CGImage,
        language: String? = "auto",
        keepLineBreaks: Bool = true,
        detectLinks: Bool = true,
        copyToClipboard: Bool = false
    ) -> OCRResult {
        var qrPayloads: [String] = []
        let barcodeReq = VNDetectBarcodesRequest()
        barcodeReq.symbologies = [.qr]

        let textReq = VNRecognizeTextRequest()
        textReq.recognitionLevel = .accurate
        textReq.usesLanguageCorrection = true
        if let language, language != "auto", !language.isEmpty {
            textReq.recognitionLanguages = [language]
        } else {
            textReq.automaticallyDetectsLanguage = true
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([barcodeReq, textReq])

        if let barcodes = barcodeReq.results {
            qrPayloads = barcodes.compactMap(\.payloadStringValue)
        }

        let lines = (textReq.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let joined = lines.joined(separator: keepLineBreaks ? "\n" : " ")

        var links: [String] = []
        if detectLinks, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let fullRange = NSRange(joined.startIndex..., in: joined)
            for match in detector.matches(in: joined, options: [], range: fullRange) {
                if let url = match.url?.absoluteString {
                    links.append(url)
                }
            }
        }

        let result = OCRResult(recognizedText: joined, qrPayloads: qrPayloads, detectedLinks: links)
        if copyToClipboard && !result.combinedClipboardText.isEmpty {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(result.combinedClipboardText, forType: .string)
        }
        return result
    }

    private func showOCRToast(_ result: OCRResult) {
        DispatchQueue.main.async {
            let text = result.combinedClipboardText.isEmpty ? "No text recognized" : "Copied text to clipboard (\(result.combinedClipboardText.count) chars)"
            let screen = NSScreen.main ?? NSScreen.screens[0]
            let panel = NSPanel(
                contentRect: CGRect(x: screen.frame.midX - 180, y: screen.frame.maxY - 96, width: 360, height: 42),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            let label = NSTextField(labelWithString: text)
            label.alignment = .center
            label.textColor = .white
            label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            label.wantsLayer = true
            label.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
            label.layer?.cornerRadius = 10
            label.frame = CGRect(x: 0, y: 0, width: 360, height: 42)
            panel.contentView = label
            panel.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                panel.orderOut(nil)
            }
        }
    }
}
