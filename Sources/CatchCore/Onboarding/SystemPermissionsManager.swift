import Foundation
import AppKit
import AVFoundation
import CoreGraphics
import ApplicationServices
import Combine
import Speech

public enum CatchPermissionKind: String, CaseIterable, Identifiable, Sendable {
    case screenRecording
    case accessibility
    case microphone
    case camera
    case speechRecognition

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .accessibility: return "Accessibility"
        case .microphone: return "Microphone"
        case .camera: return "Camera"
        case .speechRecognition: return "Speech Recognition"
        }
    }

    public var symbolName: String {
        switch self {
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .accessibility: return "keyboard.badge.ellipsis"
        case .microphone: return "mic.fill"
        case .camera: return "video.fill"
        case .speechRecognition: return "waveform.badge.magnifyingglass"
        }
    }

    public var summary: String {
        switch self {
        case .screenRecording:
            return "Captures areas, windows, scrolling pages, OCR regions, and Studio screen video."
        case .accessibility:
            return "Enables global keyboard shortcuts, window snapping, and sequential paste."
        case .microphone:
            return "Records Studio voiceover and powers voice-paced & script-following teleprompter."
        case .camera:
            return "Powers the floating Loom-style webcam bubble and 4K camera ISO takes."
        case .speechRecognition:
            return "Follows your spoken script on macOS and generates editable take captions."
        }
    }

    public var settingsPaneIdentifier: String {
        switch self {
        case .screenRecording: return "Privacy_ScreenCapture"
        case .accessibility: return "Privacy_Accessibility"
        case .microphone: return "Privacy_Microphone"
        case .camera: return "Privacy_Camera"
        case .speechRecognition: return "Privacy_SpeechRecognition"
        }
    }

    /// TCC service identifier accepted by `/usr/bin/tccutil reset <service> <bundleID>`.
    public var tccResetServiceName: String? {
        switch self {
        case .screenRecording: return "ScreenCapture"
        case .accessibility: return "Accessibility"
        case .microphone: return "Microphone"
        case .camera: return "Camera"
        case .speechRecognition: return "SpeechRecognition"
        }
    }

    public var requiresSystemSettingsToggle: Bool {
        self == .screenRecording || self == .accessibility
    }
}

public enum PermissionGrantState: Equatable, Sendable {
    case granted
    case denied
    case notDetermined

    public var isGranted: Bool { self == .granted }
}

public final class SystemPermissionsManager: ObservableObject {
    public static let shared = SystemPermissionsManager()

    @Published public private(set) var hasScreenRecording: Bool = false
    @Published public private(set) var hasAccessibility: Bool = false
    @Published public private(set) var microphoneState: PermissionGrantState = .notDetermined
    @Published public private(set) var cameraState: PermissionGrantState = .notDetermined
    @Published public private(set) var speechRecognitionState: PermissionGrantState = .notDetermined
    @Published public private(set) var macOSScreenshotShortcutsDisabled: Bool = false
    @Published public private(set) var lastActionMessage: String?
    @Published public private(set) var screenRecordingGrantedThisSession: Bool = false

    /// Apple Symbolic Hotkey IDs for macOS built-in screenshot shortcuts:
    /// 28: Save picture of screen as a file (Shift+Cmd+3)
    /// 29: Copy picture of screen to the clipboard (Ctrl+Shift+Cmd+3)
    /// 30: Save picture of area as a file (Shift+Cmd+4)
    /// 31: Copy picture of area to the clipboard (Ctrl+Shift+Cmd+4)
    /// 184: Screenshot and recording options (Shift+Cmd+5)
    public static let macOSScreenshotHotkeyIDs: [String] = ["28", "29", "30", "31", "184"]

    private var pollTimer: Timer?
    private var explicitPollRequested = false
    private var pollingSurfaces = Set<UUID>()
    private var activationObserver: NSObjectProtocol?
    private var hadScreenRecordingAtLaunch: Bool = false
    private var hasInitializedLaunchBaseline = false

    public init() {
        refreshStatus()
        hadScreenRecordingAtLaunch = hasScreenRecording
        hasInitializedLaunchBaseline = true

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    deinit {
        pollTimer?.invalidate()
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    public func isGranted(_ kind: CatchPermissionKind) -> Bool {
        switch kind {
        case .screenRecording: return hasScreenRecording
        case .accessibility: return hasAccessibility
        case .microphone: return microphoneState == .granted
        case .camera: return cameraState == .granted
        case .speechRecognition: return speechRecognitionState == .granted
        }
    }

    public func state(for kind: CatchPermissionKind) -> PermissionGrantState {
        switch kind {
        case .screenRecording: return hasScreenRecording ? .granted : .notDetermined
        case .accessibility: return hasAccessibility ? .granted : .notDetermined
        case .microphone: return microphoneState
        case .camera: return cameraState
        case .speechRecognition: return speechRecognitionState
        }
    }

    public func startPolling(interval: TimeInterval = 0.8) {
        explicitPollRequested = true
        updatePollTimer(interval: interval)
    }

    public func stopPolling() {
        explicitPollRequested = false
        updatePollTimer(interval: 0.8)
    }

    public func setPollingSurface(_ id: UUID, visible: Bool) {
        if visible {
            pollingSurfaces.insert(id)
            refreshStatus()
        } else {
            pollingSurfaces.remove(id)
        }
        updatePollTimer(interval: 0.8)
    }

    private func updatePollTimer(interval: TimeInterval) {
        let shouldPoll = explicitPollRequested || !pollingSurfaces.isEmpty
        if shouldPoll {
            guard pollTimer == nil else { return }
            refreshStatus()
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                self?.refreshStatus()
            }
            timer.tolerance = interval * 0.3
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        } else {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    public func refreshStatus() {
        let screenRec = CGPreflightScreenCaptureAccess()
        let accessibility = AXIsProcessTrusted()
        let disabled = Self.areMacOSScreenshotShortcutsDisabled()
        let mic = Self.mapAVAuthorization(AVCaptureDevice.authorizationStatus(for: .audio))
        let cam = Self.mapAVAuthorization(AVCaptureDevice.authorizationStatus(for: .video))
        let speech = Self.mapSpeechAuthorization(SFSpeechRecognizer.authorizationStatus())

        let apply = { [weak self] in
            guard let self else { return }
            if self.hasInitializedLaunchBaseline && !self.hadScreenRecordingAtLaunch && screenRec {
                self.screenRecordingGrantedThisSession = true
            }
            if self.hasScreenRecording != screenRec { self.hasScreenRecording = screenRec }
            if self.hasAccessibility != accessibility { self.hasAccessibility = accessibility }
            if self.microphoneState != mic { self.microphoneState = mic }
            if self.cameraState != cam { self.cameraState = cam }
            if self.speechRecognitionState != speech { self.speechRecognitionState = speech }
            if self.macOSScreenshotShortcutsDisabled != disabled {
                self.macOSScreenshotShortcutsDisabled = disabled
            }
        }

        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    private static func mapAVAuthorization(_ status: AVAuthorizationStatus) -> PermissionGrantState {
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    private static func mapSpeechAuthorization(_ status: SFSpeechRecognizerAuthorizationStatus) -> PermissionGrantState {
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    // MARK: - Unified Request Flow

    public func request(_ kind: CatchPermissionKind, showFloatingGuide: Bool = true) {
        switch kind {
        case .screenRecording:
            _ = requestScreenRecording(showFloatingGuide: showFloatingGuide)
        case .accessibility:
            _ = requestAccessibility(showFloatingGuide: showFloatingGuide)
        case .microphone:
            requestMicrophone()
        case .camera:
            requestCamera()
        case .speechRecognition:
            requestSpeechRecognition()
        }
    }

    @discardableResult
    public func requestScreenRecording(showFloatingGuide: Bool = true) -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        refreshStatus()
        if !granted && !hasScreenRecording {
            openSettings(for: .screenRecording)
            if showFloatingGuide {
                CatchPermissionGuidePanel.shared.present(for: .screenRecording)
            }
        }
        return granted
    }

    @discardableResult
    public func requestAccessibility(showFloatingGuide: Bool = true) -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        refreshStatus()
        if !trusted && !hasAccessibility {
            openSettings(for: .accessibility)
            if showFloatingGuide {
                CatchPermissionGuidePanel.shared.present(for: .accessibility)
            }
        }
        return trusted
    }

    public func requestMicrophone() {
        let current = AVCaptureDevice.authorizationStatus(for: .audio)
        switch current {
        case .authorized:
            refreshStatus()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.refreshStatus()
                    if !granted {
                        self?.openSettings(for: .microphone)
                    }
                }
            }
        case .denied, .restricted:
            openSettings(for: .microphone)
        @unknown default:
            openSettings(for: .microphone)
        }
    }

    public func requestCamera() {
        let current = AVCaptureDevice.authorizationStatus(for: .video)
        switch current {
        case .authorized:
            refreshStatus()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.refreshStatus()
                    if !granted {
                        self?.openSettings(for: .camera)
                    }
                }
            }
        case .denied, .restricted:
            openSettings(for: .camera)
        @unknown default:
            openSettings(for: .camera)
        }
    }

    public func requestSpeechRecognition() {
        let current = SFSpeechRecognizer.authorizationStatus()
        switch current {
        case .authorized:
            refreshStatus()
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                DispatchQueue.main.async {
                    self?.refreshStatus()
                    if status != .authorized {
                        self?.openSettings(for: .speechRecognition)
                    }
                }
            }
        case .denied, .restricted:
            openSettings(for: .speechRecognition)
        @unknown default:
            openSettings(for: .speechRecognition)
        }
    }

    /// Clears Catch's stale TCC entry for the given service (common after local/ad-hoc rebuilds)
    /// using macOS's `/usr/bin/tccutil` and immediately re-triggers the permission prompt.
    public func resetAndRequest(_ kind: CatchPermissionKind, showFloatingGuide: Bool = true) {
        guard let service = kind.tccResetServiceName,
              let bundleID = Bundle.main.bundleIdentifier,
              !bundleID.isEmpty else {
            openSettings(for: kind)
            return
        }

        lastActionMessage = "Resetting stale \(kind.displayName) entry and requesting fresh approval…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            Self.runBoundedProcess(
                executable: "/usr/bin/tccutil",
                arguments: ["reset", service, bundleID],
                timeout: 3.0
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                guard let self else { return }
                self.refreshStatus()
                self.request(kind, showFloatingGuide: showFloatingGuide)
            }
        }
    }

    /// Relaunches the running Catch.app bundle so macOS applies newly granted Screen Recording access.
    public func relaunchApplication() {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            lastActionMessage = "Relaunch from your built Catch.app bundle to apply Screen Recording permission."
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if error == nil {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    // MARK: - System Settings Deep Links

    public func openSettings(for kind: CatchPermissionKind) {
        let primary = "x-apple.systempreferences:com.apple.preference.security?\(kind.settingsPaneIdentifier)"
        if let url = URL(string: primary), NSWorkspace.shared.open(url) {
            return
        }
        if let fallback = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(fallback)
        }
    }

    public func openScreenRecordingSettings() {
        openSettings(for: .screenRecording)
    }

    public func openAccessibilitySettings() {
        openSettings(for: .accessibility)
    }

    public func openKeyboardShortcutsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts") {
            if NSWorkspace.shared.open(url) { return }
        }
        if let fallback = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts") {
            NSWorkspace.shared.open(fallback)
        }
    }

    // MARK: - macOS Screenshot Hotkeys

    public static func areMacOSScreenshotShortcutsDisabled() -> Bool {
        guard let defaults = UserDefaults(suiteName: "com.apple.symbolichotkeys"),
              let hotkeys = defaults.dictionary(forKey: "AppleSymbolicHotKeys") else {
            return false
        }
        for key in macOSScreenshotHotkeyIDs {
            guard let entry = hotkeys[key] as? [String: Any],
                  let enabled = entry["enabled"] as? Bool else {
                // Absent keys default to enabled on macOS.
                return false
            }
            if enabled {
                return false
            }
        }
        return true
    }

    @discardableResult
    public func disableMacOSSystemScreenshotShortcuts() -> Bool {
        let updated = setMacOSScreenshotShortcuts(enabled: false)
        lastActionMessage = updated
            ? "macOS built-in screenshot shortcuts disabled — ⇧⌘3, ⇧⌘4, ⇧⌘5 now route to Catch."
            : "Could not update AppleSymbolicHotKeys automatically. You can toggle them in System Settings → Keyboard → Keyboard Shortcuts → Screenshots."
        refreshStatus()
        NotificationCenter.default.post(name: .catchHotkeysShouldReload, object: nil)
        return updated
    }

    @discardableResult
    public func restoreMacOSSystemScreenshotShortcuts() -> Bool {
        let updated = setMacOSScreenshotShortcuts(enabled: true)
        lastActionMessage = updated
            ? "Restored macOS built-in screenshot shortcuts. Use ⌥⇧⌘5 / ⌥⇧⌘4 / ⌥⇧⌘3 for Catch."
            : "Could not restore AppleSymbolicHotKeys automatically."
        refreshStatus()
        NotificationCenter.default.post(name: .catchHotkeysShouldReload, object: nil)
        return updated
    }

    private func setMacOSScreenshotShortcuts(enabled: Bool) -> Bool {
        let domain = "com.apple.symbolichotkeys"
        guard let defaults = UserDefaults(suiteName: domain) else {
            return false
        }
        var hotkeys = defaults.dictionary(forKey: "AppleSymbolicHotKeys") ?? [:]

        // Standard Apple Symbolic Hotkey parameters for screenshot keys when not yet written to plist.
        let defaultParams: [String: [Int]] = [
            "28": [51, 20, 1179648],   // Shift+Cmd+3
            "29": [51, 20, 1441792],   // Ctrl+Shift+Cmd+3
            "30": [52, 21, 1179648],   // Shift+Cmd+4
            "31": [52, 21, 1441792],   // Ctrl+Shift+Cmd+4
            "184": [53, 23, 1179648]   // Shift+Cmd+5
        ]

        for id in Self.macOSScreenshotHotkeyIDs {
            var entry = (hotkeys[id] as? [String: Any]) ?? [:]
            entry["enabled"] = enabled
            if entry["value"] == nil, let params = defaultParams[id] {
                entry["value"] = [
                    "parameters": params,
                    "type": "standard"
                ]
            }
            hotkeys[id] = entry
        }

        defaults.set(hotkeys, forKey: "AppleSymbolicHotKeys")
        let synced = defaults.synchronize()

        // Apply updated symbolic hotkeys immediately to the active session.
        let activateSettingsPath = "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"
        if FileManager.default.isExecutableFile(atPath: activateSettingsPath) {
            Self.runBoundedProcess(executable: activateSettingsPath, arguments: ["-u"], timeout: 3.0)
        }

        return synced
    }

    @discardableResult
    private static func runBoundedProcess(executable: String, arguments: [String], timeout: TimeInterval) -> Int32 {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return -1 }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        do {
            try process.run()
        } catch {
            return -1
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return -2
        }
        return process.terminationStatus
    }
}

public extension Notification.Name {
    static let catchHotkeysShouldReload = Notification.Name("CatchHotkeysShouldReload")
}
