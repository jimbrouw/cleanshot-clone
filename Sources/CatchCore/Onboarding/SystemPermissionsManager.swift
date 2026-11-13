import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
import Combine

public final class SystemPermissionsManager: ObservableObject {
    public static let shared = SystemPermissionsManager()

    @Published public private(set) var hasScreenRecording: Bool = false
    @Published public private(set) var hasAccessibility: Bool = false
    @Published public private(set) var macOSScreenshotShortcutsDisabled: Bool = false
    @Published public private(set) var lastActionMessage: String?

    /// Apple Symbolic Hotkey IDs for macOS built-in screenshot shortcuts:
    /// 28: Save picture of screen as a file (Shift+Cmd+3)
    /// 29: Copy picture of screen to the clipboard (Ctrl+Shift+Cmd+3)
    /// 30: Save picture of area as a file (Shift+Cmd+4)
    /// 31: Copy picture of area to the clipboard (Ctrl+Shift+Cmd+4)
    /// 184: Screenshot and recording options (Shift+Cmd+5)
    public static let macOSScreenshotHotkeyIDs: [String] = ["28", "29", "30", "31", "184"]

    private var pollTimer: Timer?

    public init() {
        refreshStatus()
    }

    public func startPolling(interval: TimeInterval = 1.0) {
        stopPolling()
        refreshStatus()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    public func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    public func refreshStatus() {
        let screenRec = CGPreflightScreenCaptureAccess()
        let accessibility = AXIsProcessTrusted()
        let disabled = Self.areMacOSScreenshotShortcutsDisabled()

        if Thread.isMainThread {
            if hasScreenRecording != screenRec { hasScreenRecording = screenRec }
            if hasAccessibility != accessibility { hasAccessibility = accessibility }
            if macOSScreenshotShortcutsDisabled != disabled { macOSScreenshotShortcutsDisabled = disabled }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.hasScreenRecording != screenRec { self.hasScreenRecording = screenRec }
                if self.hasAccessibility != accessibility { self.hasAccessibility = accessibility }
                if self.macOSScreenshotShortcutsDisabled != disabled {
                    self.macOSScreenshotShortcutsDisabled = disabled
                }
            }
        }
    }

    @discardableResult
    public func requestScreenRecording() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        if !granted {
            openScreenRecordingSettings()
        }
        refreshStatus()
        return granted
    }

    @discardableResult
    public func requestAccessibility() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            openAccessibilitySettings()
        }
        refreshStatus()
        return trusted
    }

    public func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    public func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    public func openKeyboardShortcutsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts") {
            if NSWorkspace.shared.open(url) { return }
        }
        if let fallback = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts") {
            NSWorkspace.shared.open(fallback)
        }
    }

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
            let task = Process()
            task.executableURL = URL(fileURLWithPath: activateSettingsPath)
            task.arguments = ["-u"]
            try? task.run()
            task.waitUntilExit()
        }

        return synced
    }
}

public extension Notification.Name {
    static let catchHotkeysShouldReload = Notification.Name("CatchHotkeysShouldReload")
}
