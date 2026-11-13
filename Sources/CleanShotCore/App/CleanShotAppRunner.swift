import Foundation
import AppKit
import Carbon

public final class CleanShotAppRunner: NSObject, NSApplicationDelegate {
    public static let shared = CleanShotAppRunner()

    private var statusItem: NSStatusItem?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var hotKeyHandlers: [UInt32: () -> Void] = [:]

    public static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = CleanShotAppRunner.shared
        app.run()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        registerAppleEventHandler()
        setupMenuBar()
        registerGlobalHotkeys()
        _ = HistoryStore.shared.pruneExpiredItems(retention: SettingsStore.shared.keepHistoryDuration)
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
        item.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "CleanShot Clone")
        item.menu = buildMenu()
        self.statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(makeItem("All-In-One", action: #selector(cmdAllInOne), key: "5"))
        menu.addItem(.separator())
        menu.addItem(makeItem("Capture Area", action: #selector(cmdCaptureArea), key: "4"))
        menu.addItem(makeItem("Capture Previous Area", action: #selector(cmdCapturePreviousArea), key: ""))
        menu.addItem(makeItem("Capture Fullscreen", action: #selector(cmdCaptureFullscreen), key: "3"))
        menu.addItem(makeItem("Capture Window", action: #selector(cmdCaptureWindow), key: ""))
        menu.addItem(makeItem("Self-Timer", action: #selector(cmdSelfTimer), key: ""))
        menu.addItem(makeItem("Scrolling Capture", action: #selector(cmdScrollingCapture), key: ""))
        menu.addItem(.separator())
        menu.addItem(makeItem("Capture Text (OCR)", action: #selector(cmdCaptureText), key: "2"))
        menu.addItem(makeItem("Open Annotate...", action: #selector(cmdOpenAnnotate), key: ""))
        menu.addItem(makeItem("Open from Clipboard", action: #selector(cmdOpenFromClipboard), key: ""))
        menu.addItem(makeItem("Pin Screenshot...", action: #selector(cmdPinFile), key: ""))
        menu.addItem(makeItem("Unlock All Pinned Screenshots", action: #selector(cmdUnlockPinned), key: ""))
        menu.addItem(.separator())
        menu.addItem(makeItem("Capture History", action: #selector(cmdOpenHistory), key: ""))
        menu.addItem(makeItem("Restore Last Capture", action: #selector(cmdRestoreLast), key: ""))
        menu.addItem(makeItem("Toggle Desktop Icons", action: #selector(cmdToggleDesktopIcons), key: ""))
        menu.addItem(makeItem("Toggle Quick Access Visibility", action: #selector(cmdToggleQuickAccess), key: ""))
        menu.addItem(.separator())
        menu.addItem(makeItem("Settings...", action: #selector(cmdOpenSettings), key: ","))
        menu.addItem(makeItem("Quit CleanShot Clone", action: #selector(cmdQuit), key: "q"))
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
    @objc private func cmdCaptureText() { OCRService.shared.captureTextFromScreen() }
    @objc private func cmdOpenAnnotate() { openFileForAnnotate() }
    @objc private func cmdOpenFromClipboard() { AnnotateWindowController.openFromClipboard() }
    @objc private func cmdPinFile() { openFileForPin() }
    @objc private func cmdUnlockPinned() { PinnedScreenshotController.shared.unlockAll() }
    @objc private func cmdOpenHistory() { HistoryWindowController.shared.show() }
    @objc private func cmdRestoreLast() { QuickAccessOverlayManager.shared.restoreRecentlyClosed() }
    @objc private func cmdToggleDesktopIcons() { DesktopIconsManager.shared.toggleDesktopIcons() }
    @objc private func cmdToggleQuickAccess() { QuickAccessOverlayManager.shared.toggleTemporarilyHide() }
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

    private func registerGlobalHotkeys() {
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData, let event else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let runner = Unmanaged<CleanShotAppRunner>.fromOpaque(userData).takeUnretainedValue()
            runner.hotKeyHandlers[hkID.id]?()
            return noErr
        }, 1, &eventSpec, Unmanaged.passUnretained(self).toOpaque(), nil)

        registerHotKey(id: 1, keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(cmdKey | shiftKey)) {
            AllInOneHUDController.shared.show()
        }
        registerHotKey(id: 2, keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey | optionKey)) {
            CaptureEngine.shared.captureArea()
        }
        registerHotKey(id: 3, keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey | shiftKey | optionKey)) {
            OCRService.shared.captureTextFromScreen()
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
