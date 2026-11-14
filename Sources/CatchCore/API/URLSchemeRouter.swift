import Foundation
import CoreGraphics

public enum URLCommand: Equatable, Sendable {
    case allInOne(rect: CGRect?, display: Int?)
    case captureArea(rect: CGRect?, display: Int?, action: PostCaptureActionOverride?)
    case capturePreviousArea(action: PostCaptureActionOverride?)
    case captureFullscreen(action: PostCaptureActionOverride?)
    case captureWindow(action: PostCaptureActionOverride?)
    case selfTimer(action: PostCaptureActionOverride?)
    case scrollingCapture(rect: CGRect?, display: Int?, start: Bool, autoscroll: Bool)
    case pin(filepath: String?)
    case recordScreen(rect: CGRect?, display: Int?)
    case captureText(filepath: String?, rect: CGRect?, display: Int?, linebreaks: Bool?)
    case openAnnotate(filepath: String?)
    case openFromClipboard
    case toggleDesktopIcons
    case hideDesktopIcons
    case showDesktopIcons
    case addQuickAccessOverlay(filepath: String)
    case openHistory
    case restoreRecentlyClosed
    case openSettings(tab: SettingsTab?)
    case openOnboarding
    case openClipboard
    case pasteSequential
    case readAloud(rect: CGRect?, display: Int?)
}

public enum URLSchemeRouter {
    public static func parse(url: URL) -> URLCommand? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "catch" else {
            return nil
        }

        let commandName = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let params = Dictionary(
            (components?.queryItems ?? []).compactMap { item in
                item.value.map { (item.name.lowercased(), $0) }
            },
            uniquingKeysWith: { _, latest in latest }
        )

        let rect: CGRect? = {
            if let xStr = params["x"], let yStr = params["y"],
               let wStr = params["width"], let hStr = params["height"],
               let x = Double(xStr), let y = Double(yStr),
               let w = Double(wStr), let h = Double(hStr),
               x.isFinite, y.isFinite, w.isFinite, h.isFinite, w > 0, h > 0 {
                return CGRect(x: x, y: y, width: w, height: h)
            }
            return nil
        }()
        let display = params["display"].flatMap(Int.init)
        let action = params["action"].flatMap { PostCaptureActionOverride(rawValue: $0.lowercased()) }

        switch commandName {
        case "all-in-one":
            return .allInOne(rect: rect, display: display)
        case "capture-area":
            return .captureArea(rect: rect, display: display, action: action)
        case "capture-previous-area":
            return .capturePreviousArea(action: action)
        case "capture-fullscreen":
            return .captureFullscreen(action: action)
        case "capture-window":
            return .captureWindow(action: action)
        case "self-timer":
            return .selfTimer(action: action)
        case "scrolling-capture":
            let start = params["start"]?.lowercased() == "true"
            let autoscroll = params["autoscroll"]?.lowercased() == "true"
            return .scrollingCapture(rect: rect, display: display, start: start, autoscroll: autoscroll)
        case "pin":
            return .pin(filepath: params["filepath"])
        case "record-screen":
            return .recordScreen(rect: rect, display: display)
        case "capture-text":
            let linebreaks = params["linebreaks"].map { $0.lowercased() == "true" }
            return .captureText(filepath: params["filepath"], rect: rect, display: display, linebreaks: linebreaks)
        case "open-annotate":
            return .openAnnotate(filepath: params["filepath"])
        case "open-from-clipboard":
            return .openFromClipboard
        case "toggle-desktop-icons":
            return .toggleDesktopIcons
        case "hide-desktop-icons":
            return .hideDesktopIcons
        case "show-desktop-icons":
            return .showDesktopIcons
        case "add-quick-access-overlay":
            guard let fp = params["filepath"], !fp.isEmpty else { return nil }
            return .addQuickAccessOverlay(filepath: fp)
        case "open-history":
            return .openHistory
        case "restore-recently-closed":
            return .restoreRecentlyClosed
        case "open-settings":
            let tab = params["tab"].flatMap { SettingsTab(rawValue: $0.lowercased()) }
            return .openSettings(tab: tab)
        case "open-onboarding":
            return .openOnboarding
        case "open-clipboard":
            return .openClipboard
        case "paste-sequential":
            return .pasteSequential
        case "read-aloud":
            return .readAloud(rect: rect, display: display)
        default:
            return nil
        }
    }

    @discardableResult
    public static func execute(url: URL, settings: SettingsStore = .shared, dryRun: Bool = false) -> Bool {
        guard settings.allowURLSchemeAPI, let command = parse(url: url) else {
            return false
        }
        if dryRun {
            return true
        }

        switch command {
        case .allInOne(let rect, let display):
            AllInOneHUDController.shared.show(initialRect: rect, displayIndex: display)
        case .captureArea(let rect, let display, let action):
            CaptureEngine.shared.captureArea(rect: rect, displayIndex: display, action: action)
        case .capturePreviousArea(let action):
            CaptureEngine.shared.capturePreviousArea(action: action)
        case .captureFullscreen(let action):
            CaptureEngine.shared.captureFullscreen(action: action)
        case .captureWindow(let action):
            CaptureEngine.shared.captureWindow(action: action)
        case .selfTimer(let action):
            CaptureEngine.shared.captureWithSelfTimer(action: action)
        case .scrollingCapture(let rect, let display, let start, let autoscroll):
            ScrollingCaptureController.shared.beginScrollingCapture(rect: rect, displayIndex: display, autoStart: start, autoScroll: autoscroll)
        case .pin(let filepath):
            if let filepath {
                PinnedScreenshotController.shared.pinFromFile(url: URL(fileURLWithPath: filepath))
            } else {
                CatchAppRunner.shared.openFileForPin()
            }
        case .recordScreen(let rect, let display):
            ScreenRecordingStudio.shared.presentStudio(initialRect: rect, displayIndex: display)
        case .captureText(let filepath, let rect, let display, let linebreaks):
            if let filepath {
                _ = OCRService.shared.captureTextFromFile(url: URL(fileURLWithPath: filepath), lineBreaks: linebreaks)
            } else {
                OCRService.shared.captureTextFromScreen(rect: rect, displayIndex: display, lineBreaks: linebreaks)
            }
        case .openAnnotate(let filepath):
            if let filepath {
                AnnotateWindowController.openFile(url: URL(fileURLWithPath: filepath))
            } else {
                CatchAppRunner.shared.openFileForAnnotate()
            }
        case .openFromClipboard:
            AnnotateWindowController.openFromClipboard()
        case .toggleDesktopIcons:
            DesktopIconsManager.shared.toggleDesktopIcons()
        case .hideDesktopIcons:
            DesktopIconsManager.shared.hideDesktopIcons()
        case .showDesktopIcons:
            DesktopIconsManager.shared.showDesktopIcons()
        case .addQuickAccessOverlay(let filepath):
            QuickAccessOverlayManager.shared.presentFromFile(url: URL(fileURLWithPath: filepath))
        case .openHistory:
            HistoryWindowController.shared.show()
        case .restoreRecentlyClosed:
            QuickAccessOverlayManager.shared.restoreRecentlyClosed()
        case .openSettings(let tab):
            SettingsWindowController.shared.show(tab: tab ?? .general)
        case .openOnboarding:
            OnboardingWindowController.shared.show()
        case .openClipboard:
            ClipboardWindowController.shared.show()
        case .pasteSequential:
            _ = ClipboardHistoryStore.shared.pasteNextSequential()
        case .readAloud(let rect, let display):
            Task { @MainActor in
                ReadAloudService.shared.captureAndReadAloud(rect: rect, displayIndex: display)
            }
        }
        return true
    }
}
