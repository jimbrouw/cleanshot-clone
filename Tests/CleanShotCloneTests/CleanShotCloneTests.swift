import XCTest
import AppKit
import CoreGraphics
@testable import CleanShotCore

final class CleanShotCloneTests: XCTestCase {

    // 1. Filename formatter tokens (%y, %m, %n, %d, %w, %t, %a, %H, %M, %S, %p, %r, %i)
    func testFileNameFormatterAllTokens() {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 8
        comps.day = 24
        comps.hour = 13
        comps.minute = 50
        comps.second = 1
        comps.timeZone = TimeZone(secondsFromGMT: 0)
        let date = Calendar(identifier: .gregorian).date(from: comps)!

        let formatted = FileNameFormatter.format(
            pattern: "CleanShot %y-%m-%d (%n/%w) %t [%a] %H.%M.%S %p %r #%i",
            date: date,
            windowTitle: "Report: Q3/Q4?",
            appName: "Safari",
            isRetina: true,
            add2xSuffix: true,
            useUTC: true,
            removeIllegalCharacters: true,
            autoIncrementCounter: 7,
            randomGenerator: { "abcd" }
        )

        XCTAssertTrue(formatted.contains("2026-08-24"))
        XCTAssertTrue(formatted.contains("01.50.01 PM"))
        XCTAssertTrue(formatted.contains("abcd"))
        XCTAssertTrue(formatted.contains("#7"))
        XCTAssertTrue(formatted.contains("[Safari]"))
        XCTAssertFalse(formatted.contains(":"))
        XCTAssertFalse(formatted.contains("/"))
        XCTAssertFalse(formatted.contains("?"))
        XCTAssertTrue(formatted.hasSuffix("@2x"))
    }

    // 2. URL scheme router all 19 endpoints + security gating
    func testURLSchemeRouterAll19Endpoints() {
        let urls = [
            "cleanshot://all-in-one?x=100&y=120&width=200&height=150&display=1",
            "cleanshot://capture-area?action=annotate",
            "cleanshot://capture-previous-area?action=copy",
            "cleanshot://capture-fullscreen?action=save",
            "cleanshot://capture-window?action=upload",
            "cleanshot://self-timer?action=pin",
            "cleanshot://scrolling-capture?x=10&y=20&width=300&height=400&start=true&autoscroll=true",
            "cleanshot://pin?filepath=/tmp/test.png",
            "cleanshot://record-screen?x=0&y=0&width=800&height=600&display=1",
            "cleanshot://capture-text?filepath=/tmp/ocr.png&linebreaks=false",
            "cleanshot://open-annotate?filepath=/tmp/img.png",
            "cleanshot://open-from-clipboard",
            "cleanshot://toggle-desktop-icons",
            "cleanshot://hide-desktop-icons",
            "cleanshot://show-desktop-icons",
            "cleanshot://add-quick-access-overlay?filepath=/tmp/ov.png",
            "cleanshot://open-history",
            "cleanshot://restore-recently-closed",
            "cleanshot://open-settings?tab=advanced"
        ]

        let defaults = UserDefaults(suiteName: "test.url.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)

        for str in urls {
            let url = URL(string: str)!
            XCTAssertNotNil(URLSchemeRouter.parse(url: url), "Failed to parse \(str)")
            XCTAssertTrue(URLSchemeRouter.execute(url: url, settings: settings, dryRun: true))
        }

        // Verify security toggle disables execution
        settings.allowURLSchemeAPI = false
        XCTAssertFalse(URLSchemeRouter.execute(url: URL(string: "cleanshot://capture-fullscreen")!, settings: settings, dryRun: true))
    }

    // 3. .cleanshot document round-trip with all 13 tools, 7 text styles, and Background Tool
    func testCleanShotDocumentRoundTrip() throws {
        let baseImg = CaptureEngine.makeSyntheticImage(width: 400, height: 300, label: "Base")
        var annotations: [AnnotationItem] = []

        for style in TextAnnotationStyle.allCases {
            annotations.append(AnnotationItem(kind: .text, rect: CodableRect(x: 20, y: 20, width: 120, height: 32), text: style.rawValue, textStyle: style))
        }
        annotations.append(AnnotationItem(kind: .arrow, startPoint: CodablePoint(x: 10, y: 10), endPoint: CodablePoint(x: 100, y: 100), arrowStyle: .curved))
        annotations.append(AnnotationItem(kind: .rectangle, rect: CodableRect(x: 30, y: 40, width: 80, height: 50)))
        annotations.append(AnnotationItem(kind: .filledRectangle, rect: CodableRect(x: 50, y: 50, width: 40, height: 40)))
        annotations.append(AnnotationItem(kind: .ellipse, rect: CodableRect(x: 120, y: 80, width: 60, height: 40)))
        annotations.append(AnnotationItem(kind: .line, startPoint: CodablePoint(x: 15, y: 200), endPoint: CodablePoint(x: 200, y: 200)))
        annotations.append(AnnotationItem(kind: .pencil, points: [CodablePoint(x: 10, y: 10), CodablePoint(x: 40, y: 30), CodablePoint(x: 70, y: 20)]))
        annotations.append(AnnotationItem(kind: .highlighter, points: [CodablePoint(x: 20, y: 100), CodablePoint(x: 180, y: 100)]))
        annotations.append(AnnotationItem(kind: .counter, rect: CodableRect(x: 200, y: 60, width: 32, height: 32), counterNumber: 1))
        annotations.append(AnnotationItem(kind: .spotlight, rect: CodableRect(x: 80, y: 80, width: 100, height: 80)))
        annotations.append(AnnotationItem(kind: .pixelate, rect: CodableRect(x: 40, y: 120, width: 100, height: 40), randomSeed: 99))
        annotations.append(AnnotationItem(kind: .blur, rect: CodableRect(x: 160, y: 120, width: 100, height: 40), blurMode: .secure))

        let layerData = CleanShotDocument.pngData(from: CaptureEngine.makeSyntheticImage(width: 60, height: 40, label: "Layer"))!
        let state = AnnotationDocumentState(
            annotations: annotations,
            combinedImages: [CombinedImageLayer(pngData: layerData, frame: CodableRect(x: 250, y: 20, width: 60, height: 40))],
            cropRect: nil,
            rotationQuarterTurns: 0,
            flipHorizontal: false,
            flipVertical: false,
            background: BackgroundToolConfig(mode: .gradient, selectedBuiltInIndex: 3, padding: 32, aspectRatioPreset: .r16_9, autoBalanceEnabled: true),
            autoExpandCanvas: true
        )

        let doc = CleanShotDocument(baseImage: baseImg, state: state)
        let bundleURL = FileManager.default.temporaryDirectory.appendingPathComponent("Test-\(UUID().uuidString).cleanshot")
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        try doc.save(to: bundleURL)
        let loaded = try CleanShotDocument.load(from: bundleURL)

        XCTAssertEqual(loaded.manifest.documentState.annotations.count, annotations.count)
        XCTAssertEqual(loaded.manifest.documentState.combinedImages.count, 1)
        XCTAssertEqual(loaded.manifest.documentState.background.selectedBuiltInIndex, 3)
        XCTAssertEqual(loaded.baseImage.width, 400)
        XCTAssertEqual(loaded.baseImage.height, 300)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("preview.png").path))
    }

    // 4. Auto-Expand Canvas, Auto-Balance, Randomized Pixelate, 20 Backgrounds & ImagePostProcessor
    func testAnnotationRendererAndBackgroundTool() {
        XCTAssertEqual(BackgroundToolConfig.builtInBackgrounds.count, 20)

        let base = CaptureEngine.makeSyntheticImage(width: 200, height: 150, label: "Render")
        let expandedState = AnnotationDocumentState(
            annotations: [AnnotationItem(kind: .rectangle, rect: CodableRect(x: 180, y: 120, width: 100, height: 80))],
            autoExpandCanvas: true
        )
        let expandedComposite = AnnotationRenderer.renderComposite(baseImage: base, state: expandedState)
        XCTAssertGreaterThan(expandedComposite.width, 200)
        XCTAssertGreaterThan(expandedComposite.height, 150)

        let pixelatedA = AnnotationRenderer.applyRandomizedPixelation(to: base, blockSize: 10, seed: 123)
        let pixelatedB = AnnotationRenderer.applyRandomizedPixelation(to: base, blockSize: 10, seed: 456)
        XCTAssertEqual(pixelatedA.width, 200)
        XCTAssertNotEqual(CleanShotDocument.pngData(from: pixelatedA), CleanShotDocument.pngData(from: base))
        XCTAssertNotEqual(CleanShotDocument.pngData(from: pixelatedA), CleanShotDocument.pngData(from: pixelatedB))

        let scaled = ImagePostProcessor.scaleTo1x(base, scaleFactor: 2.0)
        XCTAssertEqual(scaled.width, 100)
        XCTAssertEqual(scaled.height, 75)

        let bordered = ImagePostProcessor.add1pxBorder(base)
        XCTAssertEqual(bordered.width, 200)
        XCTAssertEqual(bordered.height, 150)

        let winImg = ImagePostProcessor.renderWindowCapture(windowImage: base, mode: .transparent, padding: 20, includeShadow: true)
        XCTAssertGreaterThan(winImg.width, 200)
    }

    // 5. Scrolling Capture vertical stitcher
    func testScrollingCaptureStitcher() {
        let width = 120
        let fullHeight = 300
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: fullHeight, bitsPerComponent: 8, bytesPerRow: width * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for band in 0..<15 {
            let shade = CGFloat(band) / 15.0
            ctx.setFillColor(red: shade, green: 0.3, blue: 1.0 - shade, alpha: 1.0)
            ctx.fill(CGRect(x: 0, y: band * 20, width: width, height: 20))
        }
        let tallSource = ctx.makeImage()!
        let f1 = tallSource.cropping(to: CGRect(x: 0, y: 0, width: width, height: 140))!
        let f2 = tallSource.cropping(to: CGRect(x: 0, y: 70, width: width, height: 140))!
        let f3 = tallSource.cropping(to: CGRect(x: 0, y: 140, width: width, height: 140))!

        let stitched = ScrollingStitcher.stitchVertical(frames: [f1, f2, f3])
        XCTAssertNotNil(stitched)
        XCTAssertEqual(stitched?.width, width)
        XCTAssertGreaterThan(stitched?.height ?? 0, 200)
    }

    // 6. On-Device Apple Vision OCR & Link Detection
    func testOCRAndQRRecognition() {
        let size = NSSize(width: 640, height: 180)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 32, weight: .bold),
            .foregroundColor: NSColor.black
        ]
        ("CleanShot OCR 2026\nhttps://cleanshot.com" as NSString).draw(at: NSPoint(x: 24, y: 60), withAttributes: attrs)
        img.unlockFocus()

        let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let res = OCRService.shared.recognizeTextAndQRCodes(in: cg, language: "en-US", keepLineBreaks: true, detectLinks: true)
        XCTAssertTrue(res.recognizedText.contains("CleanShot"))
        XCTAssertTrue(res.detectedLinks.contains(where: { $0.contains("cleanshot.com") }))
    }

    // 7. Capture History SQLite lifecycle
    func testHistoryStoreLifecycle() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("HistTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = HistoryStore(rootDirectory: dir)
        let img = CaptureEngine.makeSyntheticImage(width: 100, height: 80, label: "Hist")
        let png = CleanShotDocument.pngData(from: img)!

        let now = Date()
        let item1 = store.recordCapture(image: img, imageData: png, title: "Shot 1", mediaType: .screenshot, createdAt: now)
        _ = store.recordCapture(image: img, imageData: png, title: "Old Shot", mediaType: .gif, createdAt: now.addingTimeInterval(-10 * 24 * 3600))

        XCTAssertEqual(store.filteredItems(tab: .all).count, 2)
        XCTAssertEqual(store.filteredItems(tab: .screenshots).count, 1)
        XCTAssertEqual(store.filteredItems(tab: .gifs).count, 1)

        store.markClosed(id: item1.id, at: now)
        let restored = store.restoreMostRecentlyClosed()
        XCTAssertEqual(restored?.id, item1.id)

        let pruned = store.pruneExpiredItems(retention: .sevenDays, now: now)
        XCTAssertEqual(pruned, 1)
        XCTAssertEqual(store.filteredItems(tab: .all).count, 1)
    }

    // 8. Cloud Upload & Contextual Comments Server
    @MainActor
    func testCloudUploadAndCommentsServer() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CloudTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let cloud = CloudUploadService(storageDirectory: dir)
        let img = CaptureEngine.makeSyntheticImage(width: 120, height: 90, label: "Cloud")
        let png = CleanShotDocument.pngData(from: img)!

        let uploaded = await cloud.upload(image: img, data: png, title: "Cloud Shot", tags: ["review"])
        XCTAssertNotNil(uploaded)
        XCTAssertTrue(uploaded!.shareURL.contains("/s/\(uploaded!.id)"))

        let comment = cloud.addComment(toShareID: uploaded!.id, author: "Alex", text: "Looks sharp!", x: 45, y: 60)
        XCTAssertNotNil(comment)
        XCTAssertEqual(cloud.item(forShareID: uploaded!.id)?.comments.count, 1)
    }
}
