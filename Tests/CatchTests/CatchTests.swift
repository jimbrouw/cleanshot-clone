import XCTest
import AppKit
import CoreGraphics
import AVFoundation
@testable import CatchCore

final class CatchTests: XCTestCase {

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
            pattern: "Catch %y-%m-%d (%n/%w) %t [%a] %H.%M.%S %p %r #%i",
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
            "catch://all-in-one?x=100&y=120&width=200&height=150&display=1",
            "catch://capture-area?action=annotate",
            "catch://capture-previous-area?action=copy",
            "catch://capture-fullscreen?action=save",
            "catch://capture-window?action=upload",
            "catch://self-timer?action=pin",
            "catch://scrolling-capture?x=10&y=20&width=300&height=400&start=true&autoscroll=true",
            "catch://pin?filepath=/tmp/test.png",
            "catch://record-screen?x=0&y=0&width=800&height=600&display=1",
            "catch://capture-text?filepath=/tmp/ocr.png&linebreaks=false",
            "catch://open-annotate?filepath=/tmp/img.png",
            "catch://open-from-clipboard",
            "catch://toggle-desktop-icons",
            "catch://hide-desktop-icons",
            "catch://show-desktop-icons",
            "catch://add-quick-access-overlay?filepath=/tmp/ov.png",
            "catch://open-history",
            "catch://restore-recently-closed",
            "catch://open-settings?tab=advanced"
        ]

        let defaults = UserDefaults(suiteName: "test.url.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        XCTAssertFalse(settings.allowURLSchemeAPI)
        XCTAssertFalse(settings.clipboardHistoryEnabled)
        XCTAssertFalse(URLSchemeRouter.execute(url: URL(string: "catch://capture-fullscreen")!, settings: settings, dryRun: true))
        settings.allowURLSchemeAPI = true

        for str in urls {
            let url = URL(string: str)!
            XCTAssertNotNil(URLSchemeRouter.parse(url: url), "Failed to parse \(str)")
            XCTAssertTrue(URLSchemeRouter.execute(url: url, settings: settings, dryRun: true))
        }

        // Verify security toggle disables execution
        settings.allowURLSchemeAPI = false
        XCTAssertFalse(URLSchemeRouter.execute(url: URL(string: "catch://capture-fullscreen")!, settings: settings, dryRun: true))
    }

    // 3. .catch document round-trip with all 13 tools, 7 text styles, and Background Tool
    func testCatchDocumentRoundTrip() throws {
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

        let layerData = CatchDocument.pngData(from: CaptureEngine.makeSyntheticImage(width: 60, height: 40, label: "Layer"))!
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

        let doc = CatchDocument(baseImage: baseImg, state: state)
        let bundleURL = FileManager.default.temporaryDirectory.appendingPathComponent("Test-\(UUID().uuidString).catch")
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        try doc.save(to: bundleURL)
        let loaded = try CatchDocument.load(from: bundleURL)

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
        XCTAssertNotEqual(CatchDocument.pngData(from: pixelatedA), CatchDocument.pngData(from: base))
        XCTAssertNotEqual(CatchDocument.pngData(from: pixelatedA), CatchDocument.pngData(from: pixelatedB))

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
        ("Catch OCR 2026\nhttps://catch.app" as NSString).draw(at: NSPoint(x: 24, y: 60), withAttributes: attrs)
        img.unlockFocus()

        let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let res = OCRService.shared.recognizeTextAndQRCodes(in: cg, language: "en-US", keepLineBreaks: true, detectLinks: true)
        XCTAssertTrue(res.recognizedText.contains("Catch"))
        XCTAssertTrue(res.detectedLinks.contains(where: { $0.contains("catch.app") }))
    }

    // 7. Capture History SQLite lifecycle
    func testHistoryStoreLifecycle() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("HistTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = HistoryStore(rootDirectory: dir)
        let img = CaptureEngine.makeSyntheticImage(width: 100, height: 80, label: "Hist")
        let png = CatchDocument.pngData(from: img)!

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
    func testCloudUploadAndCommentsServer() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CloudTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let cloud = CloudUploadService(storageDirectory: dir)
        let img = CaptureEngine.makeSyntheticImage(width: 120, height: 90, label: "Cloud")
        let png = CatchDocument.pngData(from: img)!

        let refused = await cloud.upload(image: img, data: png, title: "Private", password: "test-password")
        XCTAssertNil(refused)
        XCTAssertEqual(cloud.serverPort, 0)
        let result = await cloud.upload(image: img, data: png, title: "<script>bad()</script>", tags: ["review"])
        let uploaded = try XCTUnwrap(result)
        XCTAssertNotNil(UUID(uuidString: uploaded.id))
        XCTAssertTrue(uploaded.shareURL.contains("/s/\(uploaded.id)"))

        let comment = cloud.addComment(toShareID: uploaded.id, author: "Alex", text: "Looks sharp!", x: 45, y: 60)
        XCTAssertNotNil(comment)
        XCTAssertEqual(cloud.item(forShareID: uploaded.id)?.comments.count, 1)

        let url = try XCTUnwrap(URL(string: uploaded.shareURL))
        let (body, response) = try await URLSession.shared.data(from: url)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        let html = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertFalse(html.contains("<script>"))

        var post = URLRequest(url: url.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("api/comments/\(uploaded.id)"))
        post.httpMethod = "POST"
        let (_, denied) = try await URLSession.shared.data(for: post)
        XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 405)

        let indexURL = dir.appendingPathComponent("uploads.json")
        var oldIndex = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [[String: Any]])
        oldIndex[0]["passwordHash"] = "legacy-test-password"
        try JSONSerialization.data(withJSONObject: oldIndex).write(to: indexURL)

        let relaunch = CloudUploadService(storageDirectory: dir)
        XCTAssertEqual(relaunch.recentUploads.first?.id, uploaded.id)
        XCTAssertFalse(try String(contentsOf: indexURL, encoding: .utf8).contains("legacy-test-password"))
        let port = relaunch.ensureServerStarted()
        XCTAssertNotEqual(port, 0)
        let staleURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/s/\(uploaded.id)"))
        let (_, stale) = try await URLSession.shared.data(from: staleURL)
        XCTAssertEqual((stale as? HTTPURLResponse)?.statusCode, 404)
    }

    func testOnboardingAndPermissionsManager() {
        XCTAssertEqual(
            URLSchemeRouter.parse(url: URL(string: "catch://open-onboarding")!),
            .openOnboarding
        )

        let defaults = UserDefaults(suiteName: "CatchOnboardingTest-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        XCTAssertFalse(store.hasCompletedOnboarding)
        store.hasCompletedOnboarding = true
        XCTAssertTrue(SettingsStore(defaults: defaults).hasCompletedOnboarding)

        let manager = SystemPermissionsManager()
        manager.refreshStatus()
        // Smoke-check querying live system state never crashes under headless test runner
        _ = manager.hasScreenRecording
        _ = manager.hasAccessibility
        _ = SystemPermissionsManager.macOSScreenshotHotkeyIDs
        XCTAssertEqual(SystemPermissionsManager.macOSScreenshotHotkeyIDs, ["28", "29", "30", "31", "184"])
    }

    func testRaycastClipboardHistoryStoreAndDetectors() {
        // 1. URL scheme routing for clipboard actions
        XCTAssertEqual(
            URLSchemeRouter.parse(url: URL(string: "catch://open-clipboard")!),
            .openClipboard
        )
        XCTAssertEqual(
            URLSchemeRouter.parse(url: URL(string: "catch://paste-sequential")!),
            .pasteSequential
        )

        // 2. Smart detectors: Color hex + conversions, Links, Emails, JSON
        let colorDetect = ClipboardSmartDetector.detectCategories(for: "#FF6363")
        XCTAssertTrue(colorDetect.categories.contains(.color))
        XCTAssertEqual(colorDetect.normalizedHex, "#FF6363")

        let formats = Dictionary(uniqueKeysWithValues: ClipboardSmartDetector.colorFormats(fromHex: "#FF6363").map { ($0.label, $0.value) })
        XCTAssertEqual(formats["RGB"], "rgb(255, 99, 99)")
        XCTAssertEqual(formats["HSL"], "hsl(0, 100%, 69%)")

        XCTAssertTrue(ClipboardSmartDetector.detectCategories(for: "https://catch.app/screenshots").categories.contains(.link))
        XCTAssertTrue(ClipboardSmartDetector.detectCategories(for: "team@raycast.com").categories.contains(.email))
        let formattedJSON = ClipboardSmartDetector.prettyPrintedJSON(from: #"{"b":1,"a":2}"#)
        XCTAssertNotNil(formattedJSON)
        XCTAssertTrue(formattedJSON!.contains("\n"))

        // 3. Persistent ClipboardHistoryStore lifecycle: record, dedup, pin, tag, filter, sequential paste
        let suiteName = "CatchClipboardTest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let store = ClipboardHistoryStore(storageURL: tempFile, defaults: defaults)
        let first = store.recordText("First snippet", sourceAppName: "Xcode")
        let duplicate = store.recordText("First snippet", sourceAppName: "Xcode")
        XCTAssertEqual(first.id, duplicate.id)
        XCTAssertEqual(duplicate.copyCount, 2)

        let second = store.recordText("#FF6363", sourceAppName: "Figma")
        let third = store.recordText("https://raycast.com", sourceAppName: "Safari")
        XCTAssertEqual(store.entries.count, 3)

        // Pin & Tag
        store.togglePin(id: first.id)
        store.addTag(id: second.id, tag: "brand")
        XCTAssertEqual(store.filteredEntries(query: "", category: .color).map(\.id), [second.id])
        XCTAssertEqual(store.filteredEntries(query: "", category: .all, tag: "brand").map(\.id), [second.id])

        // Sequential paste without synthesizing CGEvent (pinned entries sort first in `entries`)
        let seq1 = store.pasteNextSequential(synthesizePaste: false)
        let seq2 = store.pasteNextSequential(synthesizePaste: false)
        XCTAssertNotNil(seq1)
        XCTAssertNotNil(seq2)
        XCTAssertEqual(seq1?.id, first.id)
        XCTAssertEqual(seq2?.id, third.id)
        store.resetSequentialPaste()
        let seqReset = store.pasteNextSequential(synthesizePaste: false)
        XCTAssertEqual(seqReset?.id, first.id)
    }

    @MainActor
    func testReadAloudServiceAndURLRouting() {
        XCTAssertEqual(
            URLSchemeRouter.parse(url: URL(string: "catch://read-aloud?x=10&y=20&width=300&height=120")!),
            .readAloud(rect: CGRect(x: 10, y: 20, width: 300, height: 120), display: nil)
        )

        let service = ReadAloudService.shared
        let slowRate = service.mappedAVSpeechRate(for: 0.8)
        let normalRate = service.mappedAVSpeechRate(for: 1.0)
        let fastRate = service.mappedAVSpeechRate(for: 2.0)
        XCTAssertLessThan(slowRate, normalRate)
        XCTAssertLessThan(normalRate, fastRate)
        XCTAssertFalse(service.availableVoices.isEmpty)
    }

    func testNSPasteboardPrivacyAndTransientConformance() {
        let pb = NSPasteboard(name: NSPasteboard.Name("CatchPrivacyTest-\(UUID().uuidString)"))
        let suiteName = "CatchPrivacyDefaults-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = ClipboardHistoryStore(storageURL: nil, defaults: defaults)

        func writeSample(_ text: String, extraTypes: [String: Any] = [:]) {
            pb.clearContents()
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            for (uti, value) in extraTypes {
                if let str = value as? String {
                    item.setString(str, forType: NSPasteboard.PasteboardType(uti))
                } else {
                    item.setData(Data(), forType: NSPasteboard.PasteboardType(uti))
                }
            }
            pb.writeObjects([item])
        }

        // 1. org.nspasteboard.ConcealedType (@ 0x100b70400)
        writeSample("s3cr3t-password", extraTypes: [RaycastBinaryEvidence.concealedTypeUTI: Data()])
        XCTAssertEqual(store.inspectPasteboardItem(pb), .reject(.concealedType))

        // 2. org.nspasteboard.TransientType (@ 0x100b6efc0)
        writeSample("temp-paste", extraTypes: [RaycastBinaryEvidence.transientTypeUTI: Data()])
        XCTAssertEqual(store.inspectPasteboardItem(pb), .reject(.transientType))

        // 3. org.nspasteboard.AutoGeneratedType (@ 0x100b703d0)
        writeSample("auto-gen", extraTypes: [RaycastBinaryEvidence.autoGeneratedTypeUTI: Data()])
        XCTAssertEqual(store.inspectPasteboardItem(pb), .reject(.autoGeneratedType))

        // 4. com.raycast.RestoredType (@ 0x100b6f350)
        writeSample("restored-item", extraTypes: [RaycastBinaryEvidence.restoredTypeUTI: Data()])
        XCTAssertEqual(store.inspectPasteboardItem(pb), .reject(.restoredType))

        // 5. org.nspasteboard.source (@ 0x100b70130) matching excluded password manager
        writeSample("1p-secret", extraTypes: [RaycastBinaryEvidence.sourceTypeUTI: "com.1password.1password"])
        XCTAssertEqual(store.inspectPasteboardItem(pb), .reject(.excludedSourceApp("com.1password.1password")))

        // 6. Universal Clipboard (com.apple.is-remote-clipboard @ 0x100b6f370)
        writeSample("from-iphone", extraTypes: [
            RaycastBinaryEvidence.remoteClipboardUTI: Data(),
            RaycastBinaryEvidence.sourceTypeUTI: "com.apple.notes"
        ])
        XCTAssertEqual(
            store.inspectPasteboardItem(pb),
            .allow(sourceBundleID: "com.apple.notes", isRemote: true)
        )

        // 7. Writing with markTransient=true stamps TransientType so Catch never re-ingests its own paste
        let entry = store.recordText("Hello Self-Paste", sourceAppName: "Xcode")
        store.writeEntryToPasteboard(entry, to: pb, markTransient: true)
        XCTAssertEqual(store.inspectPasteboardItem(pb), .reject(.transientType))
        XCTAssertEqual(store.entries.count, 1)
    }

    func testSQLiteTrigramFTS5AndFractionalPinPerformance() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ClipboardSQLiteTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let dbURL = dir.appendingPathComponent("clipboard.sqlite")
        let defaults = UserDefaults(suiteName: "CatchSQLitePerf-\(UUID().uuidString)")!
        let store = ClipboardHistoryStore(storageURL: dbURL, defaults: defaults, maxEntries: 2000)

        // Seed 1,000 text entries + 1 image blob into SQLite
        for i in 0..<999 {
            _ = store.recordText("Benchmark clipboard snippet #\(i) payload_token_\(i)", sourceAppName: "Terminal")
        }
        let targetEntry = store.recordText("ExactSubstrNeedle_RaycastFTS5_2026", sourceAppName: "Xcode")
        let sampleImg = CaptureEngine.makeSyntheticImage(width: 64, height: 64, label: "Blob")
        let imgEntry = store.recordImage(sampleImg, title: "BlobTest.png", sourceAppName: "Preview")

        XCTAssertEqual(store.entries.count, 1001)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))
        // Verify content-addressed image blob exists on disk
        let blobFiles = (try? FileManager.default.contentsOfDirectory(atPath: store.blobsDirectory!.path)) ?? []
        XCTAssertEqual(blobFiles.count, 1)

        // Verify Trigram FTS5 search latency over 1,000+ rows (< 50 ms generous CI margin; typically < 1 ms)
        let start = CFAbsoluteTimeGetCurrent()
        let hits = store.searchFTS(query: "RaycastFTS5")
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        XCTAssertEqual(hits.map(\.id), [targetEntry.id])
        XCTAssertLessThan(elapsedMs, 50.0)

        // Verify fractional pin indexing (1000.0, 2000.0, 3000.0 -> midpoint 1500.0)
        let p1 = store.recordText("Pin One")
        let p2 = store.recordText("Pin Two")
        let p3 = store.recordText("Pin Three")
        store.togglePin(id: p1.id)
        store.togglePin(id: p2.id)
        store.togglePin(id: p3.id)
        XCTAssertEqual(store.entries.first(where: { $0.id == p1.id })?.pinnedPosition, 1000.0)
        XCTAssertEqual(store.entries.first(where: { $0.id == p2.id })?.pinnedPosition, 2000.0)
        XCTAssertEqual(store.entries.first(where: { $0.id == p3.id })?.pinnedPosition, 3000.0)

        store.movePinned(id: p3.id, direction: .up)
        let movedPos = store.entries.first(where: { $0.id == p3.id })?.pinnedPosition
        XCTAssertEqual(movedPos, 1500.0)

        // Reload from SQLite and verify persistence + blob restoration + pin order
        let reloaded = ClipboardHistoryStore(storageURL: dbURL, defaults: defaults, maxEntries: 2000)
        XCTAssertEqual(reloaded.entries.count, 1004)
        XCTAssertEqual(reloaded.entries.prefix(3).map(\.id), [p1.id, p3.id, p2.id])
        XCTAssertNotNil(reloaded.entries.first(where: { $0.id == imgEntry.id })?.imagePNGData)
    }

    func testHistoryStoreFoldedOCRSearchAndWindowMetadataValidator() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryFoldTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = HistoryStore(rootDirectory: dir)
        let img = CaptureEngine.makeSyntheticImage(width: 120, height: 80, label: "OCR")
        let png = CatchDocument.pngData(from: img)!
        let item = store.recordCapture(image: img, imageData: png, title: "Café Receipt")
        store.updateOCRText(for: item.id, text: "Invoice #4821 Total $99.00")

        // Pending queue should match via fallback LIKE even before folding, then fold into entries_search
        XCTAssertEqual(store.pendingFoldCount(), 1)
        XCTAssertEqual(store.filteredItems(tab: .all, query: "4821").map(\.id), [item.id])

        store.flushPendingSearchFolding()
        XCTAssertEqual(store.pendingFoldCount(), 0)
        // Diacritic-insensitive folded match on title + OCR text
        XCTAssertEqual(store.filteredItems(tab: .all, query: "cafe").map(\.id), [item.id])
        XCTAssertEqual(store.filteredItems(tab: .all, query: "4821").map(\.id), [item.id])

        // Delete item and verify `entries_search_after_delete` trigger cleans entries_search
        store.deleteItem(id: item.id)
        XCTAssertTrue(store.filteredItems(tab: .all, query: "4821").isEmpty)

        // Validate 7-key CGWindow dictionary parser (0x100b8bb90..0x100b8bd76)
        let validDict: [String: Any] = [
            kCGWindowNumber as String: UInt32(42),
            kCGWindowOwnerPID as String: pid_t(1234),
            kCGWindowBounds as String: CGRect(x: 10, y: 20, width: 800, height: 600).dictionaryRepresentation as NSDictionary,
            kCGWindowStoreType as String: 2,
            kCGWindowLayer as String: 0,
            kCGWindowSharingState as String: 1,
            kCGWindowAlpha as String: 1.0,
            kCGWindowMemoryUsage as String: NSNumber(value: 1024)
        ]
        let parsed = CaptureEngine.WindowMetadataDescriptor(info: validDict)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.windowID, 42)
        XCTAssertEqual(parsed?.ownerPID, 1234)
        XCTAssertEqual(parsed?.bounds.width, 800)

        var incompleteDict = validDict
        incompleteDict.removeValue(forKey: kCGWindowMemoryUsage as String)
        XCTAssertNil(CaptureEngine.WindowMetadataDescriptor(info: incompleteDict))
    }

    func testLoomVideoStudioTeleprompterAndCameraBubble() {
        let teleprompter = TeleprompterController()
        XCTAssertTrue(teleprompter.hideFromCapture)
        teleprompter.scriptText = String(repeating: "word ", count: 130)
        teleprompter.wordsPerMinute = 130
        XCTAssertEqual(teleprompter.wordCount, 130)
        XCTAssertEqual(teleprompter.estimatedDurationSeconds, 60.0, accuracy: 0.5)

        teleprompter.play()
        XCTAssertTrue(teleprompter.isPlaying)
        teleprompter.pause()
        XCTAssertFalse(teleprompter.isPlaying)
        teleprompter.reset()
        XCTAssertEqual(teleprompter.scrollProgress, 0.0)

        let camera = CameraBubbleController()
        XCTAssertEqual(camera.shape, .circle)
        XCTAssertEqual(camera.bubbleSize, .medium)
        camera.toggleShape()
        XCTAssertEqual(camera.shape, .squircle)
        camera.cycleSize()
        XCTAssertEqual(camera.bubbleSize, .large)
        camera.cycleSize()
        XCTAssertEqual(camera.bubbleSize, .small)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("LoomTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let history = HistoryStore(rootDirectory: tempDir.appendingPathComponent("History", isDirectory: true))
        let studio = ScreenRecordingStudio()

        let exp = expectation(description: "Loom studio writes MP4 and records HistoryStore entry")
        studio.startRecording(outputDirectory: tempDir, headlessSynthetic: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            XCTAssertTrue(studio.state.isActive)
            studio.stopRecording(historyStore: history, presentQuickAccess: false) { url, item in
                XCTAssertNotNil(url)
                if let url {
                    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
                    XCTAssertEqual(url.pathExtension.lowercased(), "mp4")
                }
                XCTAssertEqual(item?.mediaType, .video)
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 6.0)
    }
    func testStudioStopDuringPreparationDoesNotPublishTake() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("CatchCancelled-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let studio = ScreenRecordingStudio()
        let finished = expectation(description: "Cancelled preparation finishes without a take")
        studio.startRecording(outputDirectory: tempDir, headlessSynthetic: true)
        XCTAssertEqual(studio.state, .preparing)
        studio.stopRecording(presentQuickAccess: false) { url, item in
            XCTAssertNil(url)
            XCTAssertNil(item)
            XCTAssertEqual(studio.state, .idle)
            XCTAssertNil(studio.lastRecordedVideoURL)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 6)
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: tempDir.path).isEmpty) ?? true)
    }

    @MainActor
    func testLocalMCPBridgeScriptAndDisabledBoundary() async throws {
        let bridge = LocalStudioBridge.shared
        let previousScript = TeleprompterController.shared.scriptText
        let previousNotes = bridge.editNotes
        defer {
            bridge.disable()
            TeleprompterController.shared.scriptText = previousScript
            bridge.editNotes = previousNotes
        }
        bridge.enable()
        XCTAssertTrue(bridge.enabled, bridge.error ?? "bridge did not start")
        bridge.beginCaptureSession()
        let captureKey = try XCTUnwrap(bridge.captureKey)
        let complete = expectation(description: "MCP client uses running bridge")
        let script = "First line\n[Silent cue]\nSecond line"
        let notes = "Cut after the cue."
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/catch-studio-mcp.py")
        DispatchQueue.global().async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [source.path]
            process.environment = ProcessInfo.processInfo.environment.merging(["CATCH_CAPTURE_KEY": captureKey]) { _, key in key }
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            do {
                try process.run()
                let messages: [[String: Any]] = [
                    ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]],
                    ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "load_script", "arguments": ["script": script, "edit_notes": notes]]],
                    ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "selected_take", "arguments": [:]]],
                    ["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": [1]],
                    ["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "status", "arguments": [:]]]
                ]
                for message in messages {
                    let data = try JSONSerialization.data(withJSONObject: message)
                    input.fileHandleForWriting.write(data + Data([10]))
                }
                try input.fileHandleForWriting.close()
                let result = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let lines = String(decoding: result, as: UTF8.self).split(separator: "\n")
                XCTAssertEqual(lines.count, 5)
                guard lines.count == 5 else { complete.fulfill(); return }
                XCTAssertTrue(lines[1].contains("isError"))
                XCTAssertTrue(lines[1].contains("false"))
                XCTAssertTrue(lines[2].contains("Select a finished take"))
                XCTAssertTrue(lines[3].contains("Tool params must be an object"))
                XCTAssertTrue(lines[4].contains("idle"))
            } catch { XCTFail("MCP client failed: \(error)") }
            complete.fulfill()
        }
        await fulfillment(of: [complete], timeout: 10)
        XCTAssertEqual(TeleprompterController.shared.scriptText, script)
        XCTAssertEqual(bridge.editNotes, notes)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = ScreenRecordingStudio()
        let history = HistoryStore(rootDirectory: dir.appendingPathComponent("History"))
        fixture.startRecording(outputDirectory: dir, headlessSynthetic: true)
        for _ in 0..<100 where !fixture.state.isActive {
            try await Task.sleep(for: .milliseconds(20))
        }
        let completedURL: URL? = await withCheckedContinuation { continuation in
            fixture.stopRecording(historyStore: history, presentQuickAccess: false) { url, _ in
                continuation.resume(returning: url)
            }
        }
        let url = try XCTUnwrap(completedURL)
        let sidecar = url.deletingPathExtension().appendingPathExtension("handoff.json")
        bridge.snapshotForTake()
        try bridge.saveHandoff(for: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        bridge.editNotes = notes
        bridge.includeNotesInNextTake = true
        bridge.snapshotForTake()
        try bridge.saveHandoff(for: url)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any])
        XCTAssertEqual(object["script"] as? String, script)
        XCTAssertEqual(object["edit_notes"] as? String, notes)
        let fake = dir.appendingPathComponent("fake.mp4")
        try Data("fixture-only".utf8).write(to: fake)
        bridge.includeNotesInNextTake = true
        bridge.snapshotForTake()
        try bridge.saveHandoff(for: fake)
        do {
            try await bridge.selectTake(fake)
            XCTFail("A non-playable MP4 was selected")
        } catch {}
        try await bridge.selectTake(url)
        bridge.endCaptureSession()
        let selected = expectation(description: "Editing client receives selected fixture")
        DispatchQueue.global().async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [source.path]
            process.environment = ProcessInfo.processInfo.environment.filter { $0.key != "CATCH_CAPTURE_KEY" }
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            do {
                try process.run()
                let request: [String: Any] = ["jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": ["name": "selected_take", "arguments": [:]]]
                input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: request) + Data([10]))
                try input.fileHandleForWriting.close()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let outer = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let result = try XCTUnwrap(outer["result"] as? [String: Any])
                let content = try XCTUnwrap(result["content"] as? [[String: Any]])
                let text = try XCTUnwrap(content.first?["text"] as? String)
                let take = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                XCTAssertEqual(take["mp4_path"] as? String, url.path)
                XCTAssertEqual(take["script"] as? String, script)
                XCTAssertEqual(take["edit_notes"] as? String, notes)
            } catch { XCTFail("Editing client failed: \(error)") }
            selected.fulfill()
        }
        await fulfillment(of: [selected], timeout: 10)
        bridge.disable()
        XCTAssertFalse(FileManager.default.fileExists(atPath: bridge.socketPath))
    }

    func testTrimExportWithExternalMediaFixture() async throws {
        guard let path = ProcessInfo.processInfo.environment["CATCH_TRIM_FIXTURE"] else { throw XCTSkip("No optional media fixture supplied") }
        let source = URL(fileURLWithPath: path)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("CatchTrim-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: destination) }
        let done = expectation(description: "Trim finished")
        TakeTrimmer.export(source: source, destination: destination, start: 1, end: 3) { result in
            if case .failure(let error) = result { XCTFail("Trim failed: \(error)") }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 15)
        let asset = AVURLAsset(url: destination)
        let duration = try await asset.load(.duration)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertGreaterThan(duration.seconds, 1.5)
        XCTAssertLessThan(duration.seconds, 2.5)
        XCTAssertEqual(video.count, 1)
        XCTAssertEqual(audio.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

}
