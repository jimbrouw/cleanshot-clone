import Foundation
import AppKit
import Carbon

public final class CatchAppRunner: NSObject, NSApplicationDelegate {
    public static let shared = CatchAppRunner()

    private var statusItem: NSStatusItem?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var hotKeyHandlers: [UInt32: () -> Void] = [:]
    private var isHotKeyHandlerInstalled = false

    public static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = CatchAppRunner.shared
        app.run()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        registerAppleEventHandler()
        setupMenuBar()
        reregisterHotkeys()
        NotificationCenter.default.addObserver(forName: .catchHotkeysShouldReload, object: nil, queue: .main) { [weak self] _ in
            self?.reregisterHotkeys()
        }
        _ = HistoryStore.shared.pruneExpiredItems(retention: SettingsStore.shared.keepHistoryDuration)
        if SettingsStore.shared.clipboardHistoryEnabled {
            ClipboardHistoryStore.shared.pruneExpired(days: SettingsStore.shared.clipboardRetentionDays)
            ClipboardHistoryStore.shared.startMonitoring()
        }

        SystemPermissionsManager.shared.refreshStatus()
        if !SettingsStore.shared.hasCompletedOnboarding
            || !SystemPermissionsManager.shared.hasScreenRecording
            || !SystemPermissionsManager.shared.hasAccessibility {
            DispatchQueue.main.async {
                OnboardingWindowController.shared.show()
            }
        }
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SystemPermissionsManager.shared.refreshStatus()
        if !SettingsStore.shared.hasCompletedOnboarding
            || !SystemPermissionsManager.shared.hasScreenRecording
            || !SystemPermissionsManager.shared.hasAccessibility {
            OnboardingWindowController.shared.show()
        } else if !flag {
            AllInOneHUDController.shared.show()
        }
        return true
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.isFileURL {
                AnnotateWindowController.openFile(url: url)
            } else {
                URLSchemeRouter.execute(url: url)
            }
        }
    }

    private func registerAppleEventHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlStr = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlStr) else {
            return
        }
        URLSchemeRouter.execute(url: url)
    }

    public func setupMenuBar() {
        guard SettingsStore.shared.showMenuBarIcon else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Catch")
        item.menu = buildMenu()
        self.statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(makeItem("Onboarding & Feature Tour...", action: #selector(cmdOpenOnboarding), key: ""))
        menu.addItem(.separator())
        menu.addItem(makeItem("All-In-One", action: #selector(cmdAllInOne), key: "5"))
        menu.addItem(.separator())
        menu.addItem(makeItem("Capture Area", action: #selector(cmdCaptureArea), key: "4"))
        menu.addItem(makeItem("Capture Previous Area", action: #selector(cmdCapturePreviousArea), key: ""))
        menu.addItem(makeItem("Capture Fullscreen", action: #selector(cmdCaptureFullscreen), key: "3"))
        menu.addItem(makeItem("Capture Window", action: #selector(cmdCaptureWindow), key: ""))
        menu.addItem(makeItem("Self-Timer", action: #selector(cmdSelfTimer), key: ""))
        menu.addItem(makeItem("Scrolling Capture", action: #selector(cmdScrollingCapture), key: ""))
        menu.addItem(.separator())
        menu.addItem(makeItem("Loom Video Studio (Screen + Cam + Teleprompter)...", action: #selector(cmdOpenLoomStudio), key: ""))
        menu.addItem(makeItem("Toggle Teleprompter", action: #selector(cmdToggleTeleprompter), key: ""))
        menu.addItem(makeItem("Toggle Camera Bubble", action: #selector(cmdToggleCameraBubble), key: ""))
        menu.addItem(.separator())
        menu.addItem(makeItem("Capture Text (OCR)", action: #selector(cmdCaptureText), key: "2"))
        menu.addItem(makeItem("Read Aloud (Screenshot)", action: #selector(cmdReadAloud), key: ""))
        menu.addItem(makeItem("Open Annotate...", action: #selector(cmdOpenAnnotate), key: ""))
        menu.addItem(makeItem("Open from Clipboard", action: #selector(cmdOpenFromClipboard), key: ""))
        menu.addItem(makeItem("Pin Screenshot...", action: #selector(cmdPinFile), key: ""))
        menu.addItem(makeItem("Unlock All Pinned Screenshots", action: #selector(cmdUnlockPinned), key: ""))
        menu.addItem(.separator())
        menu.addItem(makeItem("Clipboard History (Raycast Style)...", action: #selector(cmdOpenClipboardHistory), key: ""))
        menu.addItem(makeItem("Paste Sequentially", action: #selector(cmdPasteSequential), key: ""))
        menu.addItem(.separator())
        menu.addItem(makeItem("Capture History", action: #selector(cmdOpenHistory), key: ""))
        menu.addItem(makeItem("Restore Last Capture", action: #selector(cmdRestoreLast), key: ""))
        menu.addItem(makeItem("Toggle Desktop Icons", action: #selector(cmdToggleDesktopIcons), key: ""))
        menu.addItem(makeItem("Toggle Quick Access Visibility", action: #selector(cmdToggleQuickAccess), key: ""))
        menu.addItem(.separator())
        menu.addItem(makeItem("Settings...", action: #selector(cmdOpenSettings), key: ","))
        menu.addItem(makeItem("Quit Catch", action: #selector(cmdQuit), key: "q"))
        return menu
    }

    private func makeItem(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        return mi
    }

    @objc private func cmdAllInOne() { AllInOneHUDController.shared.show() }
    @objc private func cmdCaptureArea() { CaptureEngine.shared.captureArea() }
    @objc private func cmdCapturePreviousArea() { CaptureEngine.shared.capturePreviousArea() }
    @objc private func cmdCaptureFullscreen() { CaptureEngine.shared.captureFullscreen() }
    @objc private func cmdCaptureWindow() { CaptureEngine.shared.captureWindow() }
    @objc private func cmdSelfTimer() { CaptureEngine.shared.captureWithSelfTimer() }
    @objc private func cmdScrollingCapture() { ScrollingCaptureController.shared.beginScrollingCapture() }
    @objc private func cmdOpenLoomStudio() { ScreenRecordingStudio.shared.presentStudio() }
    @objc private func cmdToggleTeleprompter() { TeleprompterController.shared.toggle() }
    @objc private func cmdToggleCameraBubble() { CameraBubbleController.shared.toggle() }
    @objc private func cmdCaptureText() { OCRService.shared.captureTextFromScreen() }
    @objc private func cmdReadAloud() {
        Task { @MainActor in
            ReadAloudService.shared.captureAndReadAloud()
        }
    }
    @objc private func cmdOpenAnnotate() { openFileForAnnotate() }
    @objc private func cmdOpenFromClipboard() { AnnotateWindowController.openFromClipboard() }
    @objc private func cmdPinFile() { openFileForPin() }
    @objc private func cmdUnlockPinned() { PinnedScreenshotController.shared.unlockAll() }
    @objc private func cmdOpenClipboardHistory() { ClipboardWindowController.shared.show() }
    @objc private func cmdPasteSequential() { _ = ClipboardHistoryStore.shared.pasteNextSequential() }
    @objc private func cmdOpenHistory() { HistoryWindowController.shared.show() }
    @objc private func cmdRestoreLast() { QuickAccessOverlayManager.shared.restoreRecentlyClosed() }
    @objc private func cmdToggleDesktopIcons() { DesktopIconsManager.shared.toggleDesktopIcons() }
    @objc private func cmdToggleQuickAccess() { QuickAccessOverlayManager.shared.toggleTemporarilyHide() }
    @objc private func cmdOpenOnboarding() { OnboardingWindowController.shared.show() }
    @objc private func cmdOpenSettings() { SettingsWindowController.shared.show() }
    @objc private func cmdQuit() { NSApp.terminate(nil) }

    public func openFileForAnnotate() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url {
            AnnotateWindowController.openFile(url: url)
        }
    }

    public func openFileForPin() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url {
            PinnedScreenshotController.shared.pinFromFile(url: url)
        }
    }

    public func reregisterHotkeys() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        hotKeyHandlers.removeAll()
        registerGlobalHotkeys()
    }

    private func registerGlobalHotkeys() {
        if !isHotKeyHandlerInstalled {
            var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
                guard let userData, let event else { return noErr }
                var hkID = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
                let runner = Unmanaged<CatchAppRunner>.fromOpaque(userData).takeUnretainedValue()
                runner.hotKeyHandlers[hkID.id]?()
                return noErr
            }, 1, &eventSpec, Unmanaged.passUnretained(self).toOpaque(), nil)
            isHotKeyHandlerInstalled = true
        }

        // Standard shortcuts (active immediately once macOS system screenshot shortcuts are disabled)
        registerHotKey(id: 1, keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(cmdKey | shiftKey)) {
            AllInOneHUDController.shared.show()
        }
        registerHotKey(id: 2, keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey)) {
            CaptureEngine.shared.captureArea()
        }
        registerHotKey(id: 3, keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey | shiftKey)) {
            CaptureEngine.shared.captureFullscreen()
        }
        registerHotKey(id: 4, keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey | shiftKey)) {
            OCRService.shared.captureTextFromScreen()
        }

        // Conflict-free Option+Shift+Cmd shortcuts (always work alongside macOS defaults)
        registerHotKey(id: 10, keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(cmdKey | shiftKey | optionKey)) {
            AllInOneHUDController.shared.show()
        }
        registerHotKey(id: 11, keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey | optionKey)) {
            CaptureEngine.shared.captureArea()
        }
        registerHotKey(id: 12, keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey | shiftKey | optionKey)) {
            CaptureEngine.shared.captureFullscreen()
        }
        registerHotKey(id: 13, keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(cmdKey | shiftKey | optionKey)) {
            CaptureEngine.shared.captureWindow()
        }
        registerHotKey(id: 14, keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | shiftKey | optionKey)) {
            ScrollingCaptureController.shared.beginScrollingCapture()
        }
        registerHotKey(id: 15, keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey | shiftKey | optionKey)) {
            OCRService.shared.captureTextFromScreen()
        }
        registerHotKey(id: 16, keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(cmdKey | shiftKey | optionKey)) {
            HistoryWindowController.shared.show()
        }
        registerHotKey(id: 17, keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey | shiftKey | optionKey)) { [weak self] in
            self?.openFileForAnnotate()
        }
        registerHotKey(id: 18, keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey | optionKey)) {
            ClipboardWindowController.shared.toggle()
        }
        registerHotKey(id: 19, keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey | controlKey)) {
            _ = ClipboardHistoryStore.shared.pasteNextSequential()
        }
        registerHotKey(id: 20, keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | shiftKey | optionKey)) {
            Task { @MainActor in
                ReadAloudService.shared.captureAndReadAloud()
            }
        }
        registerHotKey(id: 21, keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(cmdKey | shiftKey | optionKey)) {
            ScreenRecordingStudio.shared.presentStudio()
        }
    }

    private func registerHotKey(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        hotKeyHandlers[id] = handler
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: 0x43534854, id: id) // 'CSHT'
        RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        if let ref {
            hotKeyRefs.append(ref)
        }
    }
}
