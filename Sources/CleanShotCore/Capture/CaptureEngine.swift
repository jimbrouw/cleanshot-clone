import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit

public enum PostCaptureActionOverride: String, Codable, CaseIterable, Sendable {
    case copy
    case save
    case annotate
    case upload
    case pin
}

public struct CaptureResult: Sendable {
    public let id: UUID
    public let image: CGImage
    public let encodedData: Data
    public let fileName: String
    public let format: ScreenshotFormat
    public let capturedAt: Date
    public let sourceRect: CGRect
    public let displayScale: CGFloat

    public init(
        id: UUID = UUID(),
        image: CGImage,
        encodedData: Data,
        fileName: String,
        format: ScreenshotFormat,
        capturedAt: Date = Date(),
        sourceRect: CGRect,
        displayScale: CGFloat
    ) {
        self.id = id
        self.image = image
        self.encodedData = encodedData
        self.fileName = fileName
        self.format = format
        self.capturedAt = capturedAt
        self.sourceRect = sourceRect
        self.displayScale = displayScale
    }
}

public final class CaptureEngine: ObservableObject {
    public static let shared = CaptureEngine()

    public var lastCapturedRect: CGRect?
    public var lastCapturedDisplayIndex: Int?
    private var autoIncrementCounter: Int = 0
    private var timerWindow: NSWindow?

    public init() {}

    public func captureArea(
        rect: CGRect? = nil,
        displayIndex: Int? = nil,
        action: PostCaptureActionOverride? = nil
    ) {
        let settings = SettingsStore.shared
        let screen = resolveScreen(displayIndex: displayIndex)

        if let explicitRect = rect, explicitRect.width >= 2, explicitRect.height >= 2 {
            performAreaCapture(rect: explicitRect, on: screen, displayIndex: displayIndex, action: action)
            return
        }

        let frozenImage = settings.freezeScreenWhenCapturing ? captureDisplayCGImage(screen: screen, includeCursor: false) : nil
        SelectionOverlayController.shared.beginAreaSelection(
            on: screen,
            frozenImage: frozenImage,
            initialRect: settings.allInOneRememberLastSelection ? lastCapturedRect : nil
        ) { [weak self] selectedRect, shiftPressed in
            guard let self, let selectedRect else { return }
            self.performAreaCapture(
                rect: selectedRect,
                on: screen,
                displayIndex: displayIndex,
                bypassBackgroundPreset: shiftPressed,
                action: action
            )
        }
    }

    public func capturePreviousArea(action: PostCaptureActionOverride? = nil) {
        if let rect = lastCapturedRect {
            let screen = resolveScreen(displayIndex: lastCapturedDisplayIndex)
            performAreaCapture(rect: rect, on: screen, displayIndex: lastCapturedDisplayIndex, action: action)
        } else {
            captureArea(rect: nil, displayIndex: nil, action: action)
        }
    }

    public func captureFullscreen(displayIndex: Int? = nil, action: PostCaptureActionOverride? = nil) {
        let screen = resolveScreen(displayIndex: displayIndex)
        let settings = SettingsStore.shared
        withTemporaryHiddenIconsIfNeeded {
            let cg = self.captureDisplayCGImage(screen: screen, includeCursor: settings.showCursorOnScreenshots)
            self.finalizeCapture(
                rawImage: cg,
                sourceRect: screen.frame,
                displayScale: screen.backingScaleFactor,
                windowTitle: "Fullscreen",
                appName: "macOS",
                bypassBackgroundPreset: NSEvent.modifierFlags.contains(.shift),
                action: action
            )
        }
    }

    public func captureWindow(windowID: CGWindowID? = nil, shiftPressedForTransparent: Bool = false, action: PostCaptureActionOverride? = nil) {
        let settings = SettingsStore.shared
        let screen = resolveScreen(displayIndex: nil)
        let isTransparent = shiftPressedForTransparent || NSEvent.modifierFlags.contains(.shift) || settings.windowScreenshotBackgroundMode == .transparent

        if let targetID = windowID ?? findFrontmostAppWindowID() {
            let rawWindow = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                targetID,
                settings.captureWindowShadow ? [.boundsIgnoreFraming] : [.boundsIgnoreFraming, .nominalResolution]
            ) ?? Self.makeSyntheticImage(width: 960, height: 640, label: "Window Capture")

            let mode: WindowBackgroundMode = isTransparent ? .transparent : .withWallpaper
            let wallpaper = mode == .withWallpaper ? DesktopIconsManager.shared.resolveBackdropImage(for: screen) : nil
            let rendered = ImagePostProcessor.renderWindowCapture(
                windowImage: rawWindow,
                mode: mode,
                wallpaper: wallpaper,
                plainColor: CodableColor(hex: settings.customWallpaperColorHex).nsColor,
                padding: CGFloat(settings.windowScreenshotPadding),
                includeShadow: settings.captureWindowShadow
            )

            finalizeCapture(
                rawImage: rendered,
                sourceRect: CGRect(x: 0, y: 0, width: rendered.width, height: rendered.height),
                displayScale: screen.backingScaleFactor,
                windowTitle: NSWorkspace.shared.frontmostApplication?.localizedName,
                appName: NSWorkspace.shared.frontmostApplication?.localizedName,
                bypassBackgroundPreset: isTransparent,
                action: action
            )
        } else {
            captureFullscreen(displayIndex: nil, action: action)
        }
    }

    public func captureWithSelfTimer(seconds: Int? = nil, action: PostCaptureActionOverride? = nil) {
        let interval = max(1, seconds ?? SettingsStore.shared.selfTimerIntervalSeconds)
        let screen = resolveScreen(displayIndex: nil)
        SelectionOverlayController.shared.beginAreaSelection(on: screen, frozenImage: nil, initialRect: nil) { [weak self] selectedRect, shiftPressed in
            guard let self, let selectedRect else { return }
            self.runCountdown(seconds: interval, on: screen) {
                self.performAreaCapture(
                    rect: selectedRect,
                    on: screen,
                    displayIndex: nil,
                    includeCursor: SettingsStore.shared.showCursorOnScreenshots,
                    bypassBackgroundPreset: shiftPressed,
                    action: action
                )
            }
        }
    }

    public func performAreaCapture(
        rect: CGRect,
        on screen: NSScreen,
        displayIndex: Int? = nil,
        includeCursor: Bool = false,
        bypassBackgroundPreset: Bool = false,
        action: PostCaptureActionOverride? = nil
    ) {
        lastCapturedRect = rect
        lastCapturedDisplayIndex = displayIndex

        withTemporaryHiddenIconsIfNeeded {
            let full = self.captureDisplayCGImage(screen: screen, includeCursor: includeCursor)
            let scale = CGFloat(full.width) / max(1, screen.frame.width)
            let cropRect = CGRect(
                x: max(0, (rect.minX - screen.frame.minX) * scale),
                y: max(0, (screen.frame.maxY - rect.maxY) * scale),
                width: max(2, rect.width * scale),
                height: max(2, rect.height * scale)
            ).intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))

            let cropped = full.cropping(to: cropRect) ?? full
            self.finalizeCapture(
                rawImage: cropped,
                sourceRect: rect,
                displayScale: screen.backingScaleFactor,
                windowTitle: NSWorkspace.shared.frontmostApplication?.localizedName,
                appName: NSWorkspace.shared.frontmostApplication?.localizedName,
                bypassBackgroundPreset: bypassBackgroundPreset,
                action: action
            )
        }
    }

    public func captureRegionSync(rect: CGRect, on screen: NSScreen? = nil) -> CGImage {
        let targetScreen = screen ?? resolveScreen(displayIndex: nil)
        let full = captureDisplayCGImage(screen: targetScreen, includeCursor: false)
        let scale = CGFloat(full.width) / max(1, targetScreen.frame.width)
        let cropRect = CGRect(
            x: max(0, (rect.minX - targetScreen.frame.minX) * scale),
            y: max(0, (targetScreen.frame.maxY - rect.maxY) * scale),
            width: max(2, rect.width * scale),
            height: max(2, rect.height * scale)
        ).intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))
        return full.cropping(to: cropRect) ?? full
    }

    public func captureDisplayCGImage(screen: NSScreen, includeCursor: Bool) -> CGImage {
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        if let cgImage = CGDisplayCreateImage(displayID) {
            return cgImage
        }
        return Self.makeSyntheticImage(
            width: max(100, Int(screen.frame.width)),
            height: max(100, Int(screen.frame.height)),
            label: "CleanShot Capture"
        )
    }

    public func finalizeCapture(
        rawImage: CGImage,
        sourceRect: CGRect,
        displayScale: CGFloat,
        windowTitle: String?,
        appName: String?,
        bypassBackgroundPreset: Bool = false,
        action: PostCaptureActionOverride? = nil
    ) {
        let settings = SettingsStore.shared
        autoIncrementCounter += 1
        playShutterSoundIfEnabled()

        let processed = ImagePostProcessor.applySettingsPipeline(
            to: rawImage,
            scaleFactor: displayScale,
            settings: settings,
            bypassBackgroundPreset: bypassBackgroundPreset
        )

        let fileName = FileNameFormatter.format(
            pattern: settings.fileNameFormat,
            date: Date(),
            windowTitle: windowTitle,
            appName: appName,
            isRetina: displayScale > 1.5 && !settings.scaleRetinaTo1x,
            add2xSuffix: settings.add2xSuffixToRetina,
            useUTC: settings.useUTCTimeZone,
            removeIllegalCharacters: settings.removeIllegalCharacters,
            autoIncrementCounter: autoIncrementCounter
        )

        let encoded = ImagePostProcessor.encode(image: processed, format: settings.outputFormat)
            ?? CleanShotDocument.pngData(from: processed)
            ?? Data()

        let result = CaptureResult(
            image: processed,
            encodedData: encoded,
            fileName: fileName,
            format: settings.outputFormat,
            sourceRect: sourceRect,
            displayScale: displayScale
        )

        let historyItem = HistoryStore.shared.recordCapture(
            image: processed,
            imageData: encoded,
            title: fileName,
            mediaType: .screenshot,
            fileExtension: settings.outputFormat.fileExtension,
            documentState: AnnotationDocumentState()
        )

        DispatchQueue.main.async {
            if let overrideAction = action {
                self.routeSingleAction(overrideAction, result: result, historyItem: historyItem)
                return
            }

            let configured = settings.afterCaptureActions
            if configured.isEmpty || configured.contains(.showQuickAccessOverlay) {
                QuickAccessOverlayManager.shared.present(result: result, historyItem: historyItem)
            }
            if configured.contains(.copyToClipboard) {
                self.copyToClipboard(result: result)
            }
            if configured.contains(.save) {
                _ = self.saveCapture(result: result, askDestination: false)
            }
            if configured.contains(.openAnnotate) {
                AnnotateWindowController.open(image: processed, title: fileName, historyItem: historyItem)
            }
            if configured.contains(.pinToScreen) {
                PinnedScreenshotController.shared.pin(image: processed, title: fileName)
            }
            if configured.contains(.uploadToCloud) {
                Task { @MainActor in
                    _ = await CloudUploadService.shared.upload(image: processed, data: encoded, title: fileName)
                }
            }
        }
    }

    private func routeSingleAction(_ action: PostCaptureActionOverride, result: CaptureResult, historyItem: CaptureHistoryItem) {
        switch action {
        case .copy:
            copyToClipboard(result: result)
        case .save:
            _ = saveCapture(result: result, askDestination: false)
        case .annotate:
            AnnotateWindowController.open(image: result.image, title: result.fileName, historyItem: historyItem)
        case .pin:
            PinnedScreenshotController.shared.pin(image: result.image, title: result.fileName)
        case .upload:
            Task { @MainActor in
                _ = await CloudUploadService.shared.upload(image: result.image, data: result.encodedData, title: result.fileName)
            }
        }
    }

    public func copyToClipboard(result: CaptureResult) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let mode = SettingsStore.shared.clipboardCopyMode
        let nsImage = NSImage(cgImage: result.image, size: NSSize(width: result.image.width, height: result.image.height))

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(result.fileName).\(result.format.fileExtension)")
        try? result.encodedData.write(to: tempURL)

        switch mode {
        case .fileAndImage:
            pb.writeObjects([nsImage, tempURL as NSURL])
        case .imageOnly:
            pb.writeObjects([nsImage])
        case .fileOnly:
            pb.writeObjects([tempURL as NSURL])
        }
    }

    @discardableResult
    public func saveCapture(result: CaptureResult, askDestination: Bool) -> URL? {
        let settings = SettingsStore.shared
        let defaultName = "\(result.fileName).\(result.format.fileExtension)"

        if askDestination || settings.askForNameAfterCapture {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = defaultName
            panel.directoryURL = settings.exportLocationURL
            if panel.runModal() == .OK, let url = panel.url {
                try? result.encodedData.write(to: url)
                return url
            }
            return nil
        }

        try? FileManager.default.createDirectory(at: settings.exportLocationURL, withIntermediateDirectories: true)
        var targetURL = settings.exportLocationURL.appendingPathComponent(defaultName)
        var suffix = 2
        while FileManager.default.fileExists(atPath: targetURL.path) {
            targetURL = settings.exportLocationURL.appendingPathComponent("\(result.fileName) \(suffix).\(result.format.fileExtension)")
            suffix += 1
        }
        try? result.encodedData.write(to: targetURL)
        return targetURL
    }

    public func resolveScreen(displayIndex: Int?) -> NSScreen {
        if let displayIndex, displayIndex >= 1, displayIndex <= NSScreen.screens.count {
            return NSScreen.screens[displayIndex - 1]
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func findFrontmostAppWindowID() -> CGWindowID? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in list {
            if let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
               ownerPID == pid,
               let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
               let wid = info[kCGWindowNumber as String] as? CGWindowID {
                return wid
            }
        }
        return nil
    }

    private func withTemporaryHiddenIconsIfNeeded(_ block: @escaping () -> Void) {
        let settings = SettingsStore.shared
        let shouldHide = settings.hideDesktopIconsWhileCapturing && !DesktopIconsManager.shared.iconsHidden
        if shouldHide {
            DesktopIconsManager.shared.hideDesktopIcons()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                block()
                DesktopIconsManager.shared.showDesktopIcons()
            }
        } else {
            block()
        }
    }

    private func runCountdown(seconds: Int, on screen: NSScreen, completion: @escaping () -> Void) {
        DispatchQueue.main.async {
            var remaining = seconds
            let panel = NSPanel(
                contentRect: CGRect(x: screen.frame.midX - 60, y: screen.frame.midY - 60, width: 120, height: 120),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .screenSaver
            panel.backgroundColor = .clear
            panel.isOpaque = false

            let label = NSTextField(labelWithString: "\(remaining)")
            label.font = NSFont.systemFont(ofSize: 54, weight: .bold)
            label.textColor = .white
            label.alignment = .center
            label.wantsLayer = true
            label.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
            label.layer?.cornerRadius = 24
            label.frame = CGRect(x: 0, y: 0, width: 120, height: 120)
            panel.contentView = label
            panel.orderFrontRegardless()
            self.timerWindow = panel

            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
                remaining -= 1
                if remaining <= 0 {
                    timer.invalidate()
                    panel.orderOut(nil)
                    self.timerWindow = nil
                    completion()
                } else {
                    label.stringValue = "\(remaining)"
                }
            }
        }
    }

    private func playShutterSoundIfEnabled() {
        guard SettingsStore.shared.playSounds else { return }
        NSSound(named: "Tink")?.play()
    }

    public static func makeSyntheticImage(width: Int, height: Int, label: String) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("Failed to create CGContext")
        }
        ctx.setFillColor(CGColor(srgbRed: 0.96, green: 0.97, blue: 0.99, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(srgbRed: 0.05, green: 0.27, blue: 0.91, alpha: 1.0))
        ctx.fill(CGRect(x: 32, y: height - 96, width: width - 64, height: 64))
        return ctx.makeImage()!
    }
}
