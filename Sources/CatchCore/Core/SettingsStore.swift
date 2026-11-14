import Foundation
import AppKit

public enum OverlayPosition: String, Codable, CaseIterable, Sendable {
    case left
    case right
}

public enum AutoCloseAction: String, Codable, CaseIterable, Sendable {
    case saveAndClose
    case close
}

public enum SaveButtonBehavior: String, Codable, CaseIterable, Sendable {
    case saveToExportLocation
    case askDestination
}

public enum DesktopWallpaperMode: String, Codable, CaseIterable, Sendable {
    case desktopWallpaper
    case customImage
    case plainColor
}

public enum ScreenshotFormat: String, Codable, CaseIterable, Sendable {
    case png
    case jpeg
    case heic
    case webp

    public var fileExtension: String {
        rawValue
    }
}

public enum WindowBackgroundMode: String, Codable, CaseIterable, Sendable {
    case withWallpaper
    case transparent
}

public enum CrosshairMode: String, Codable, CaseIterable, Sendable {
    case disabled
    case enabled
}

public enum CloudUploadQuality: String, Codable, CaseIterable, Sendable {
    case optimizedForSharing
    case original
}

public enum ClipboardCopyMode: String, Codable, CaseIterable, Sendable {
    case fileAndImage
    case imageOnly
    case fileOnly
}

public enum HistoryRetentionDuration: String, Codable, CaseIterable, Sendable {
    case threeDays
    case sevenDays
    case oneMonth

    public var timeInterval: TimeInterval {
        switch self {
        case .threeDays: return 3 * 24 * 3600
        case .sevenDays: return 7 * 24 * 3600
        case .oneMonth: return 30 * 24 * 3600
        }
    }

    public var displayName: String {
        switch self {
        case .threeDays: return "3 days"
        case .sevenDays: return "7 days"
        case .oneMonth: return "1 month"
        }
    }
}

public enum AfterCaptureAction: String, Codable, CaseIterable, Sendable {
    case showQuickAccessOverlay
    case copyToClipboard
    case save
    case uploadToCloud
    case openAnnotate
    case pinToScreen
}

public struct ShortcutBinding: Codable, Equatable, Sendable {
    public var key: String
    public var modifiers: UInt
    public var displayString: String

    public init(key: String, modifiers: UInt, displayString: String) {
        self.key = key
        self.modifiers = modifiers
        self.displayString = displayString
    }
}

public struct ColorSwatch: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var hex: String
    public var alpha: Double

    public init(id: UUID = UUID(), name: String, hex: String, alpha: Double = 1.0) {
        self.id = id
        self.name = name
        self.hex = hex
        self.alpha = alpha
    }
}

public enum SettingsTab: String, Codable, CaseIterable, Sendable {
    case general
    case wallpaper
    case shortcuts
    case quickaccess
    case recording
    case screenshots
    case annotate
    case cloud
    case advanced
    case about
}

public final class SettingsStore: ObservableObject {
    public static let shared = SettingsStore()

    private let defaults: UserDefaults
    private let keyPrefix = "com.catchapp.settings."

    // MARK: - General
    @Published public var launchAtLogin: Bool { didSet { save("launchAtLogin", launchAtLogin) } }
    @Published public var showMenuBarIcon: Bool { didSet { save("showMenuBarIcon", showMenuBarIcon) } }
    @Published public var hideDesktopIconsWhileCapturing: Bool { didSet { save("hideDesktopIconsWhileCapturing", hideDesktopIconsWhileCapturing) } }
    @Published public var playSounds: Bool { didSet { save("playSounds", playSounds) } }
    @Published public var shutterSound: String { didSet { save("shutterSound", shutterSound) } }
    @Published public var exportLocationPath: String { didSet { save("exportLocationPath", exportLocationPath) } }
    @Published public var afterCaptureActions: [AfterCaptureAction] { didSet { saveCodable("afterCaptureActions", afterCaptureActions) } }

    // MARK: - Shortcuts
    @Published public var shortcuts: [String: ShortcutBinding] { didSet { saveCodable("shortcuts", shortcuts) } }

    // MARK: - Quick Access
    @Published public var overlayPosition: OverlayPosition { didSet { save("overlayPosition", overlayPosition.rawValue) } }
    @Published public var moveToActiveScreen: Bool { didSet { save("moveToActiveScreen", moveToActiveScreen) } }
    @Published public var overlaySize: Double { didSet { save("overlaySize", overlaySize) } }
    @Published public var autoCloseEnabled: Bool { didSet { save("autoCloseEnabled", autoCloseEnabled) } }
    @Published public var autoCloseAction: AutoCloseAction { didSet { save("autoCloseAction", autoCloseAction.rawValue) } }
    @Published public var autoCloseIntervalSeconds: Int { didSet { save("autoCloseIntervalSeconds", autoCloseIntervalSeconds) } }
    @Published public var closeAfterDragging: Bool { didSet { save("closeAfterDragging", closeAfterDragging) } }
    @Published public var closeAfterUploading: Bool { didSet { save("closeAfterUploading", closeAfterUploading) } }
    @Published public var saveButtonBehavior: SaveButtonBehavior { didSet { save("saveButtonBehavior", saveButtonBehavior.rawValue) } }

    // MARK: - Wallpaper
    @Published public var desktopWallpaperMode: DesktopWallpaperMode { didSet { save("desktopWallpaperMode", desktopWallpaperMode.rawValue) } }
    @Published public var customWallpaperPath: String { didSet { save("customWallpaperPath", customWallpaperPath) } }
    @Published public var customWallpaperColorHex: String { didSet { save("customWallpaperColorHex", customWallpaperColorHex) } }
    @Published public var updateWallpaperWhenSwitchingSpaces: Bool { didSet { save("updateWallpaperWhenSwitchingSpaces", updateWallpaperWhenSwitchingSpaces) } }

    // MARK: - Screenshots
    @Published public var outputFormat: ScreenshotFormat { didSet { save("outputFormat", outputFormat.rawValue) } }
    @Published public var convertToSRGB: Bool { didSet { save("convertToSRGB", convertToSRGB) } }
    @Published public var scaleRetinaTo1x: Bool { didSet { save("scaleRetinaTo1x", scaleRetinaTo1x) } }
    @Published public var add1pxBorder: Bool { didSet { save("add1pxBorder", add1pxBorder) } }
    @Published public var defaultBackgroundPresetId: String? { didSet { save("defaultBackgroundPresetId", defaultBackgroundPresetId) } }
    @Published public var selfTimerIntervalSeconds: Int { didSet { save("selfTimerIntervalSeconds", selfTimerIntervalSeconds) } }
    @Published public var showCursorOnScreenshots: Bool { didSet { save("showCursorOnScreenshots", showCursorOnScreenshots) } }
    @Published public var freezeScreenWhenCapturing: Bool { didSet { save("freezeScreenWhenCapturing", freezeScreenWhenCapturing) } }
    @Published public var windowScreenshotBackgroundMode: WindowBackgroundMode { didSet { save("windowScreenshotBackgroundMode", windowScreenshotBackgroundMode.rawValue) } }
    @Published public var windowScreenshotPadding: Double { didSet { save("windowScreenshotPadding", windowScreenshotPadding) } }
    @Published public var captureWindowShadow: Bool { didSet { save("captureWindowShadow", captureWindowShadow) } }
    @Published public var crosshairMode: CrosshairMode { didSet { save("crosshairMode", crosshairMode.rawValue) } }
    @Published public var showMagnifier: Bool { didSet { save("showMagnifier", showMagnifier) } }

    // MARK: - Screen Recording (Preferences kept in sync with settings8/9)
    @Published public var recordingShowControls: Bool { didSet { save("recordingShowControls", recordingShowControls) } }
    @Published public var recordingRememberLastSelection: Bool { didSet { save("recordingRememberLastSelection", recordingRememberLastSelection) } }
    @Published public var recordingFrameRate: Int { didSet { save("recordingFrameRate", recordingFrameRate) } }
    @Published public var recordingScaleRetinaTo1x: Bool { didSet { save("recordingScaleRetinaTo1x", recordingScaleRetinaTo1x) } }
    @Published public var recordingRecordSystemAudio: Bool { didSet { save("recordingRecordSystemAudio", recordingRecordSystemAudio) } }
    @Published public var recordingCameraID: String? { didSet { save("recordingCameraID", recordingCameraID) } }
    @Published public var recordingMicrophoneID: String? { didSet { save("recordingMicrophoneID", recordingMicrophoneID) } }
    @Published public var recordingGifFrameRate: Int { didSet { save("recordingGifFrameRate", recordingGifFrameRate) } }

    // MARK: - Annotate
    @Published public var inverseArrowDirection: Bool { didSet { save("inverseArrowDirection", inverseArrowDirection) } }
    @Published public var smoothDrawing: Bool { didSet { save("smoothDrawing", smoothDrawing) } }
    @Published public var rememberBackgroundToolOpened: Bool { didSet { save("rememberBackgroundToolOpened", rememberBackgroundToolOpened) } }
    @Published public var drawShadowOnObjects: Bool { didSet { save("drawShadowOnObjects", drawShadowOnObjects) } }
    @Published public var automaticallyExpandCanvas: Bool { didSet { save("automaticallyExpandCanvas", automaticallyExpandCanvas) } }
    @Published public var annotateAlwaysOnTop: Bool { didSet { save("annotateAlwaysOnTop", annotateAlwaysOnTop) } }
    @Published public var showDockIconInAnnotate: Bool { didSet { save("showDockIconInAnnotate", showDockIconInAnnotate) } }
    @Published public var showColorNames: Bool { didSet { save("showColorNames", showColorNames) } }
    @Published public var savedColors: [ColorSwatch] { didSet { saveCodable("savedColors", savedColors) } }

    // MARK: - Cloud
    @Published public var accountName: String { didSet { save("accountName", accountName) } }
    @Published public var screenshotUploadQuality: CloudUploadQuality { didSet { save("screenshotUploadQuality", screenshotUploadQuality.rawValue) } }
    @Published public var askForNameAndAdvancedOptionsOnUpload: Bool { didSet { save("askForNameAndAdvancedOptionsOnUpload", askForNameAndAdvancedOptionsOnUpload) } }
    @Published public var copyLinkWhenUploadStarts: Bool { didSet { save("copyLinkWhenUploadStarts", copyLinkWhenUploadStarts) } }
    @Published public var showRecentlyUploadedInMenuBar: Bool { didSet { save("showRecentlyUploadedInMenuBar", showRecentlyUploadedInMenuBar) } }

    // MARK: - Advanced
    @Published public var askForNameAfterCapture: Bool { didSet { save("askForNameAfterCapture", askForNameAfterCapture) } }
    @Published public var fileNameFormat: String { didSet { save("fileNameFormat", fileNameFormat) } }
    @Published public var removeIllegalCharacters: Bool { didSet { save("removeIllegalCharacters", removeIllegalCharacters) } }
    @Published public var useUTCTimeZone: Bool { didSet { save("useUTCTimeZone", useUTCTimeZone) } }
    @Published public var add2xSuffixToRetina: Bool { didSet { save("add2xSuffixToRetina", add2xSuffixToRetina) } }
    @Published public var clipboardCopyMode: ClipboardCopyMode { didSet { save("clipboardCopyMode", clipboardCopyMode.rawValue) } }
    @Published public var keepHistoryDuration: HistoryRetentionDuration { didSet { save("keepHistoryDuration", keepHistoryDuration.rawValue) } }
    @Published public var ocrLanguage: String { didSet { save("ocrLanguage", ocrLanguage) } }
    @Published public var ocrKeepLineBreaks: Bool { didSet { save("ocrKeepLineBreaks", ocrKeepLineBreaks) } }
    @Published public var ocrDetectLinks: Bool { didSet { save("ocrDetectLinks", ocrDetectLinks) } }
    @Published public var allInOneRememberLastSelection: Bool { didSet { save("allInOneRememberLastSelection", allInOneRememberLastSelection) } }
    @Published public var pinnedRoundedCorners: Bool { didSet { save("pinnedRoundedCorners", pinnedRoundedCorners) } }
    @Published public var pinnedShadow: Bool { didSet { save("pinnedShadow", pinnedShadow) } }
    @Published public var pinnedBorder: Bool { didSet { save("pinnedBorder", pinnedBorder) } }
    @Published public var allowURLSchemeAPI: Bool { didSet { save("allowURLSchemeAPI", allowURLSchemeAPI) } }
    @Published public var hasCompletedOnboarding: Bool { didSet { save("hasCompletedOnboarding", hasCompletedOnboarding) } }
    @Published public var clipboardHistoryEnabled: Bool { didSet { save("clipboardHistoryEnabled", clipboardHistoryEnabled) } }
    @Published public var clipboardOCREnabled: Bool { didSet { save("clipboardOCREnabled", clipboardOCREnabled) } }
    @Published public var clipboardRetentionDays: Int { didSet { save("clipboardRetentionDays", clipboardRetentionDays) } }

    public var exportLocationURL: URL {
        get { URL(fileURLWithPath: exportLocationPath, isDirectory: true) }
        set { exportLocationPath = newValue.path }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let desktopPath = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()

        self.launchAtLogin = defaults.object(forKey: keyPrefix + "launchAtLogin") as? Bool ?? false
        self.showMenuBarIcon = defaults.object(forKey: keyPrefix + "showMenuBarIcon") as? Bool ?? true
        self.hideDesktopIconsWhileCapturing = defaults.object(forKey: keyPrefix + "hideDesktopIconsWhileCapturing") as? Bool ?? true
        self.playSounds = defaults.object(forKey: keyPrefix + "playSounds") as? Bool ?? true
        self.shutterSound = defaults.string(forKey: keyPrefix + "shutterSound") ?? "System Default"
        self.exportLocationPath = defaults.string(forKey: keyPrefix + "exportLocationPath") ?? desktopPath
        self.afterCaptureActions = Self.loadCodable(defaults, key: keyPrefix + "afterCaptureActions") ?? [.showQuickAccessOverlay, .copyToClipboard]

        self.shortcuts = Self.loadCodable(defaults, key: keyPrefix + "shortcuts") ?? Self.defaultShortcuts()

        self.overlayPosition = OverlayPosition(rawValue: defaults.string(forKey: keyPrefix + "overlayPosition") ?? "") ?? .left
        self.moveToActiveScreen = defaults.object(forKey: keyPrefix + "moveToActiveScreen") as? Bool ?? true
        self.overlaySize = defaults.object(forKey: keyPrefix + "overlaySize") as? Double ?? 1.0
        self.autoCloseEnabled = defaults.object(forKey: keyPrefix + "autoCloseEnabled") as? Bool ?? true
        self.autoCloseAction = AutoCloseAction(rawValue: defaults.string(forKey: keyPrefix + "autoCloseAction") ?? "") ?? .close
        self.autoCloseIntervalSeconds = defaults.object(forKey: keyPrefix + "autoCloseIntervalSeconds") as? Int ?? 10
        self.closeAfterDragging = defaults.object(forKey: keyPrefix + "closeAfterDragging") as? Bool ?? true
        self.closeAfterUploading = defaults.object(forKey: keyPrefix + "closeAfterUploading") as? Bool ?? true
        self.saveButtonBehavior = SaveButtonBehavior(rawValue: defaults.string(forKey: keyPrefix + "saveButtonBehavior") ?? "") ?? .saveToExportLocation

        self.desktopWallpaperMode = DesktopWallpaperMode(rawValue: defaults.string(forKey: keyPrefix + "desktopWallpaperMode") ?? "") ?? .desktopWallpaper
        self.customWallpaperPath = defaults.string(forKey: keyPrefix + "customWallpaperPath") ?? ""
        self.customWallpaperColorHex = defaults.string(forKey: keyPrefix + "customWallpaperColorHex") ?? "#1E293B"
        self.updateWallpaperWhenSwitchingSpaces = defaults.object(forKey: keyPrefix + "updateWallpaperWhenSwitchingSpaces") as? Bool ?? true

        self.outputFormat = ScreenshotFormat(rawValue: defaults.string(forKey: keyPrefix + "outputFormat") ?? "") ?? .png
        self.convertToSRGB = defaults.object(forKey: keyPrefix + "convertToSRGB") as? Bool ?? true
        self.scaleRetinaTo1x = defaults.object(forKey: keyPrefix + "scaleRetinaTo1x") as? Bool ?? false
        self.add1pxBorder = defaults.object(forKey: keyPrefix + "add1pxBorder") as? Bool ?? false
        self.defaultBackgroundPresetId = defaults.string(forKey: keyPrefix + "defaultBackgroundPresetId")
        self.selfTimerIntervalSeconds = defaults.object(forKey: keyPrefix + "selfTimerIntervalSeconds") as? Int ?? 5
        self.showCursorOnScreenshots = defaults.object(forKey: keyPrefix + "showCursorOnScreenshots") as? Bool ?? false
        self.freezeScreenWhenCapturing = defaults.object(forKey: keyPrefix + "freezeScreenWhenCapturing") as? Bool ?? true
        self.windowScreenshotBackgroundMode = WindowBackgroundMode(rawValue: defaults.string(forKey: keyPrefix + "windowScreenshotBackgroundMode") ?? "") ?? .withWallpaper
        self.windowScreenshotPadding = defaults.object(forKey: keyPrefix + "windowScreenshotPadding") as? Double ?? 40.0
        self.captureWindowShadow = defaults.object(forKey: keyPrefix + "captureWindowShadow") as? Bool ?? true
        self.crosshairMode = CrosshairMode(rawValue: defaults.string(forKey: keyPrefix + "crosshairMode") ?? "") ?? .enabled
        self.showMagnifier = defaults.object(forKey: keyPrefix + "showMagnifier") as? Bool ?? true

        self.recordingShowControls = defaults.object(forKey: keyPrefix + "recordingShowControls") as? Bool ?? true
        self.recordingRememberLastSelection = defaults.object(forKey: keyPrefix + "recordingRememberLastSelection") as? Bool ?? true
        self.recordingFrameRate = defaults.object(forKey: keyPrefix + "recordingFrameRate") as? Int ?? 60
        self.recordingScaleRetinaTo1x = defaults.object(forKey: keyPrefix + "recordingScaleRetinaTo1x") as? Bool ?? false
        self.recordingRecordSystemAudio = defaults.object(forKey: keyPrefix + "recordingRecordSystemAudio") as? Bool ?? true
        self.recordingCameraID = defaults.string(forKey: keyPrefix + "recordingCameraID")
        self.recordingMicrophoneID = defaults.string(forKey: keyPrefix + "recordingMicrophoneID")
        self.recordingGifFrameRate = defaults.object(forKey: keyPrefix + "recordingGifFrameRate") as? Int ?? 15

        self.inverseArrowDirection = defaults.object(forKey: keyPrefix + "inverseArrowDirection") as? Bool ?? false
        self.smoothDrawing = defaults.object(forKey: keyPrefix + "smoothDrawing") as? Bool ?? true
        self.rememberBackgroundToolOpened = defaults.object(forKey: keyPrefix + "rememberBackgroundToolOpened") as? Bool ?? true
        self.drawShadowOnObjects = defaults.object(forKey: keyPrefix + "drawShadowOnObjects") as? Bool ?? true
        self.automaticallyExpandCanvas = defaults.object(forKey: keyPrefix + "automaticallyExpandCanvas") as? Bool ?? true
        self.annotateAlwaysOnTop = defaults.object(forKey: keyPrefix + "annotateAlwaysOnTop") as? Bool ?? false
        self.showDockIconInAnnotate = defaults.object(forKey: keyPrefix + "showDockIconInAnnotate") as? Bool ?? false
        self.showColorNames = defaults.object(forKey: keyPrefix + "showColorNames") as? Bool ?? false
        self.savedColors = Self.loadCodable(defaults, key: keyPrefix + "savedColors") ?? Self.defaultColors()

        self.accountName = defaults.string(forKey: keyPrefix + "accountName") ?? "Local User"
        self.screenshotUploadQuality = CloudUploadQuality(rawValue: defaults.string(forKey: keyPrefix + "screenshotUploadQuality") ?? "") ?? .optimizedForSharing
        self.askForNameAndAdvancedOptionsOnUpload = defaults.object(forKey: keyPrefix + "askForNameAndAdvancedOptionsOnUpload") as? Bool ?? false
        self.copyLinkWhenUploadStarts = defaults.object(forKey: keyPrefix + "copyLinkWhenUploadStarts") as? Bool ?? true
        self.showRecentlyUploadedInMenuBar = defaults.object(forKey: keyPrefix + "showRecentlyUploadedInMenuBar") as? Bool ?? true

        self.askForNameAfterCapture = defaults.object(forKey: keyPrefix + "askForNameAfterCapture") as? Bool ?? false
        self.fileNameFormat = defaults.string(forKey: keyPrefix + "fileNameFormat") ?? "Catch %y-%m-%d at %H.%M.%S"
        self.removeIllegalCharacters = defaults.object(forKey: keyPrefix + "removeIllegalCharacters") as? Bool ?? true
        self.useUTCTimeZone = defaults.object(forKey: keyPrefix + "useUTCTimeZone") as? Bool ?? false
        self.add2xSuffixToRetina = defaults.object(forKey: keyPrefix + "add2xSuffixToRetina") as? Bool ?? false
        self.clipboardCopyMode = ClipboardCopyMode(rawValue: defaults.string(forKey: keyPrefix + "clipboardCopyMode") ?? "") ?? .fileAndImage
        self.keepHistoryDuration = HistoryRetentionDuration(rawValue: defaults.string(forKey: keyPrefix + "keepHistoryDuration") ?? "") ?? .oneMonth
        self.ocrLanguage = defaults.string(forKey: keyPrefix + "ocrLanguage") ?? "auto"
        self.ocrKeepLineBreaks = defaults.object(forKey: keyPrefix + "ocrKeepLineBreaks") as? Bool ?? true
        self.ocrDetectLinks = defaults.object(forKey: keyPrefix + "ocrDetectLinks") as? Bool ?? true
        self.allInOneRememberLastSelection = defaults.object(forKey: keyPrefix + "allInOneRememberLastSelection") as? Bool ?? true
        self.pinnedRoundedCorners = defaults.object(forKey: keyPrefix + "pinnedRoundedCorners") as? Bool ?? true
        self.pinnedShadow = defaults.object(forKey: keyPrefix + "pinnedShadow") as? Bool ?? true
        self.pinnedBorder = defaults.object(forKey: keyPrefix + "pinnedBorder") as? Bool ?? false
        self.allowURLSchemeAPI = defaults.object(forKey: keyPrefix + "allowURLSchemeAPI") as? Bool ?? false
        self.hasCompletedOnboarding = defaults.object(forKey: keyPrefix + "hasCompletedOnboarding") as? Bool ?? false
        self.clipboardHistoryEnabled = defaults.object(forKey: keyPrefix + "clipboardHistoryEnabled") as? Bool ?? false
        self.clipboardOCREnabled = defaults.object(forKey: keyPrefix + "clipboardOCREnabled") as? Bool ?? true
        self.clipboardRetentionDays = defaults.object(forKey: keyPrefix + "clipboardRetentionDays") as? Int ?? 7
    }

    public static func defaultColors() -> [ColorSwatch] {
        [
            ColorSwatch(name: "Crimson Red", hex: "#FF3B30"),
            ColorSwatch(name: "Vibrant Orange", hex: "#FF9500"),
            ColorSwatch(name: "Warm Yellow", hex: "#FFCC00"),
            ColorSwatch(name: "Emerald Green", hex: "#34C759"),
            ColorSwatch(name: "Catch Blue", hex: "#0D44E8"),
            ColorSwatch(name: "Royal Purple", hex: "#9425E7"),
            ColorSwatch(name: "Charcoal Black", hex: "#161618"),
            ColorSwatch(name: "Pure White", hex: "#FFFFFF")
        ]
    }

    public static func defaultShortcuts() -> [String: ShortcutBinding] {
        [
            "allInOne": ShortcutBinding(key: "5", modifiers: NSEvent.ModifierFlags.command.union(.shift).rawValue, displayString: "⇧⌘5"),
            "captureArea": ShortcutBinding(key: "4", modifiers: NSEvent.ModifierFlags.command.union(.shift).rawValue, displayString: "⇧⌘4"),
            "captureFullscreen": ShortcutBinding(key: "3", modifiers: NSEvent.ModifierFlags.command.union(.shift).rawValue, displayString: "⇧⌘3"),
            "captureWindow": ShortcutBinding(key: "4", modifiers: NSEvent.ModifierFlags.command.union(.shift).union(.option).rawValue, displayString: "⌥⇧⌘4"),
            "capturePreviousArea": ShortcutBinding(key: "p", modifiers: NSEvent.ModifierFlags.command.union(.shift).rawValue, displayString: "⇧⌘P"),
            "scrollingCapture": ShortcutBinding(key: "s", modifiers: NSEvent.ModifierFlags.command.union(.shift).union(.option).rawValue, displayString: "⌥⇧⌘S"),
            "captureTextOCR": ShortcutBinding(key: "2", modifiers: NSEvent.ModifierFlags.command.union(.shift).rawValue, displayString: "⇧⌘2"),
            "toggleDesktopIcons": ShortcutBinding(key: "d", modifiers: NSEvent.ModifierFlags.command.union(.shift).union(.option).rawValue, displayString: "⌥⇧⌘D"),
            "openCaptureHistory": ShortcutBinding(key: "h", modifiers: NSEvent.ModifierFlags.command.union(.shift).union(.option).rawValue, displayString: "⌥⇧⌘H"),
            "restoreLastCapture": ShortcutBinding(key: "z", modifiers: NSEvent.ModifierFlags.command.union(.shift).union(.option).rawValue, displayString: "⌥⇧⌘Z"),
            "openAnnotate": ShortcutBinding(key: "a", modifiers: NSEvent.ModifierFlags.command.union(.shift).union(.option).rawValue, displayString: "⌥⇧⌘A"),
            "openFromClipboard": ShortcutBinding(key: "v", modifiers: NSEvent.ModifierFlags.command.union(.shift).union(.option).rawValue, displayString: "⌥⇧⌘V"),
            "pinScreenshot": ShortcutBinding(key: "t", modifiers: NSEvent.ModifierFlags.command.union(.shift).union(.option).rawValue, displayString: "⌥⇧⌘T"),
            "selfTimer": ShortcutBinding(key: "6", modifiers: NSEvent.ModifierFlags.command.union(.shift).rawValue, displayString: "⇧⌘6"),
            "captureAreaAndCopy": ShortcutBinding(key: "c", modifiers: NSEvent.ModifierFlags.command.union(.control).union(.shift).rawValue, displayString: "⌃⇧⌘C"),
            "captureAreaAndSave": ShortcutBinding(key: "s", modifiers: NSEvent.ModifierFlags.command.union(.control).union(.shift).rawValue, displayString: "⌃⇧⌘S"),
            "captureAreaAndUpload": ShortcutBinding(key: "u", modifiers: NSEvent.ModifierFlags.command.union(.control).union(.shift).rawValue, displayString: "⌃⇧⌘U")
        ]
    }

    private func save(_ key: String, _ value: Any?) {
        if let value {
            defaults.set(value, forKey: keyPrefix + key)
        } else {
            defaults.removeObject(forKey: keyPrefix + key)
        }
    }

    private func saveCodable<T: Encodable>(_ key: String, _ value: T) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: keyPrefix + key)
        }
    }

    private static func loadCodable<T: Decodable>(_ defaults: UserDefaults, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
