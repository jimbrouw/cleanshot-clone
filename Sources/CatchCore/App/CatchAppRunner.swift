import Foundation
import AppKit
import Carbon
import Combine

public final class CatchAppRunner: NSObject, NSApplicationDelegate {
    public static let shared = CatchAppRunner()
    public static let preferredActivationPolicy: NSApplication.ActivationPolicy = .regular

    public enum ReopenAction: Equatable {
        case focusWindow(NSWindow)
        case deminiaturizeWindow(NSWindow)
        case showOnboarding
        case showAllInOneHUD
        case keepCurrentSession
    }

    private var statusItem: NSStatusItem?
    private var statusMenuTrackingObserver: NSObjectProtocol?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var hotKeyHandlers: [UInt32: () -> Void] = [:]
    private var isHotKeyHandlerInstalled = false
    private var clipboardMonitoringPreference: AnyCancellable?
    private var menuBarIconPreference: AnyCancellable?
    private var hasHandledOpenEvent = false

    public static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(preferredActivationPolicy)
        app.delegate = CatchAppRunner.shared
        app.run()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(Self.preferredActivationPolicy)
        registerAppleEventHandler()
        setupMainMenu()
        setupMenuBar()
        reregisterHotkeys()
        NotificationCenter.default.addObserver(forName: .catchHotkeysShouldReload, object: nil, queue: .main) { [weak self] _ in
            self?.reregisterHotkeys()
        }
        _ = HistoryStore.shared.pruneExpiredItems(retention: SettingsStore.shared.keepHistoryDuration)
        clipboardMonitoringPreference = SettingsStore.shared.$clipboardHistoryEnabled
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { enabled in
                if enabled {
                    ClipboardHistoryStore.shared.pruneExpired(days: SettingsStore.shared.clipboardRetentionDays)
                    ClipboardHistoryStore.shared.startMonitoring()
                } else {
                    ClipboardHistoryStore.shared.stopMonitoring()
                }
            }
        menuBarIconPreference = SettingsStore.shared.$showMenuBarIcon
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                self?.updateMenuBarVisibility(enabled)
            }

        SystemPermissionsManager.shared.refreshStatus()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !SettingsStore.shared.hasCompletedOnboarding {
                OnboardingWindowController.shared.show()
            } else if !self.hasHandledOpenEvent {
                var candidates = NSApp.orderedWindows
                for window in NSApp.windows where !candidates.contains(window) {
                    candidates.append(window)
                }
                if Self.resolveReopenAction(
                    windows: candidates,
                    hasCompletedOnboarding: true,
                    isRecordingActive: ScreenRecordingStudio.shared.state != .idle
                ) == .showAllInOneHUD {
                    NSApp.activate(ignoringOtherApps: true)
                    AllInOneHUDController.shared.show()
                }
            }
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    public static func isStandardAppWindow(_ window: NSWindow) -> Bool {
        guard window.level != .statusBar else { return false }
        guard !NSStringFromClass(type(of: window)).contains("StatusBar") else { return false }
        return window.styleMask.contains(.titled) && window.canBecomeKey
    }

    public static func resolveReopenAction(
        windows: [NSWindow],
        hasCompletedOnboarding: Bool,
        isRecordingActive: Bool
    ) -> ReopenAction {
        let standardWindows = windows.filter(isStandardAppWindow)
        if let visibleWindow = standardWindows.first(where: { $0.isVisible && !$0.isMiniaturized }) {
            return .focusWindow(visibleWindow)
        }
        if let minimizedWindow = standardWindows.first(where: { $0.isMiniaturized }) {
            return .deminiaturizeWindow(minimizedWindow)
        }
        if isRecordingActive {
            return .keepCurrentSession
        }
        return hasCompletedOnboarding ? .showAllInOneHUD : .showOnboarding
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SystemPermissionsManager.shared.refreshStatus()
        sender.activate(ignoringOtherApps: true)
        var candidates = sender.orderedWindows
        for window in sender.windows where !candidates.contains(window) {
            candidates.append(window)
        }
        switch Self.resolveReopenAction(
            windows: candidates,
            hasCompletedOnboarding: SettingsStore.shared.hasCompletedOnboarding,
            isRecordingActive: ScreenRecordingStudio.shared.state != .idle
        ) {
        case .focusWindow(let window):
            window.makeKeyAndOrderFront(nil)
        case .deminiaturizeWindow(let window):
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        case .showOnboarding:
            OnboardingWindowController.shared.show()
        case .showAllInOneHUD:
            AllInOneHUDController.shared.show()
        case .keepCurrentSession:
            break
        }
        return true
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        hasHandledOpenEvent = true
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
        hasHandledOpenEvent = true
        URLSchemeRouter.execute(url: url)
    }

    public func setupMainMenu() {
        let app = NSApplication.shared
        let mainMenu = buildMainMenu()
        app.mainMenu = mainMenu
        if let appMenu = mainMenu.items.first?.submenu,
           let servicesItem = appMenu.item(withTitle: "Services") {
            app.servicesMenu = servicesItem.submenu
        }
        if let windowItem = mainMenu.item(withTitle: "Window") {
            app.windowsMenu = windowItem.submenu
        }
    }

    public func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        // 1. Catch (Application) menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Catch")
        appMenu.addItem(makeResponderItem("About Catch", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), key: ""))
        appMenu.addItem(makeItem("Onboarding & Feature Tour...", action: #selector(cmdOpenOnboarding), key: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(makeItem("Settings...", action: #selector(cmdOpenSettings), key: ","))
        appMenu.addItem(.separator())
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = NSMenu(title: "Services")
        appMenu.addItem(servicesItem)
        appMenu.addItem(.separator())
        appMenu.addItem(makeResponderItem("Hide Catch", action: #selector(NSApplication.hide(_:)), key: "h"))
        appMenu.addItem(makeResponderItem("Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option]))
        appMenu.addItem(makeResponderItem("Show All", action: #selector(NSApplication.unhideAllApplications(_:)), key: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(makeResponderItem("Quit Catch", action: #selector(NSApplication.terminate(_:)), key: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // 2. File menu
        let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(makeItem("Open in Annotate...", action: #selector(cmdOpenAnnotate), key: "o"))
        fileMenu.addItem(makeItem("Open from Clipboard", action: #selector(cmdOpenFromClipboard), key: ""))
        fileMenu.addItem(makeItem("Pin Screenshot...", action: #selector(cmdPinFile), key: ""))
        fileMenu.addItem(.separator())
        fileMenu.addItem(makeResponderItem("Close Window", action: #selector(NSWindow.performClose(_:)), key: "w"))
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // 3. Edit menu
        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(makeResponderItem("Undo", action: Selector(("undo:")), key: "z"))
        editMenu.addItem(makeResponderItem("Redo", action: Selector(("redo:")), key: "z", modifiers: [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(makeResponderItem("Cut", action: #selector(NSText.cut(_:)), key: "x"))
        editMenu.addItem(makeResponderItem("Copy", action: #selector(NSText.copy(_:)), key: "c"))
        editMenu.addItem(makeResponderItem("Paste", action: #selector(NSText.paste(_:)), key: "v"))
        editMenu.addItem(makeResponderItem("Delete", action: #selector(NSText.delete(_:)), key: ""))
        editMenu.addItem(makeResponderItem("Select All", action: #selector(NSText.selectAll(_:)), key: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // 4. Capture menu
        let captureMenuItem = NSMenuItem(title: "Capture", action: nil, keyEquivalent: "")
        let captureMenu = NSMenu(title: "Capture")
        captureMenu.addItem(makeItem("All-In-One", action: #selector(cmdAllInOne), key: "5", modifiers: [.command, .shift]))
        captureMenu.addItem(.separator())
        captureMenu.addItem(makeItem("Capture Area", action: #selector(cmdCaptureArea), key: "4", modifiers: [.command, .shift]))
        captureMenu.addItem(makeItem("Capture Previous Area", action: #selector(cmdCapturePreviousArea), key: ""))
        captureMenu.addItem(makeItem("Capture Fullscreen", action: #selector(cmdCaptureFullscreen), key: "3", modifiers: [.command, .shift]))
        captureMenu.addItem(makeItem("Capture Window", action: #selector(cmdCaptureWindow), key: ""))
        captureMenu.addItem(makeItem("Self-Timer", action: #selector(cmdSelfTimer), key: ""))
        captureMenu.addItem(makeItem("Scrolling Capture", action: #selector(cmdScrollingCapture), key: ""))
        captureMenu.addItem(.separator())
        captureMenu.addItem(makeItem("Catch Studio — Screen + Loom Bubble...", action: #selector(cmdOpenLoomStudio), key: ""))
        captureMenu.addItem(makeItem("Catch Studio — Dual 4K ISO...", action: #selector(cmdOpenDualISOStudio), key: ""))
        captureMenu.addItem(makeItem("Catch Studio — Podcast Camera...", action: #selector(cmdOpenPodcastCameraStudio), key: ""))
        captureMenu.addItem(makeItem("Toggle Teleprompter", action: #selector(cmdToggleTeleprompter), key: ""))
        captureMenu.addItem(makeItem("Toggle Camera Bubble", action: #selector(cmdToggleCameraBubble), key: ""))
        captureMenu.addItem(.separator())
        captureMenu.addItem(makeItem("Capture Text (OCR)", action: #selector(cmdCaptureText), key: "2", modifiers: [.command, .shift]))
        captureMenu.addItem(makeItem("Read Aloud (Screenshot)", action: #selector(cmdReadAloud), key: ""))
        captureMenuItem.submenu = captureMenu
        mainMenu.addItem(captureMenuItem)

        // 5. Window menu
        let windowMenuItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(makeResponderItem("Minimize", action: #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        windowMenu.addItem(makeResponderItem("Zoom", action: #selector(NSWindow.performZoom(_:)), key: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(makeItem("Capture History", action: #selector(cmdOpenHistory), key: ""))
        windowMenu.addItem(makeItem("Clipboard History", action: #selector(cmdOpenClipboardHistory), key: ""))
        windowMenu.addItem(makeItem("Restore Last Capture", action: #selector(cmdRestoreLast), key: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(makeResponderItem("Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), key: ""))
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        return mainMenu
    }

    public func setupMenuBar() {
        updateMenuBarVisibility(SettingsStore.shared.showMenuBarIcon)
    }

    private func updateMenuBarVisibility(_ visible: Bool) {
        if !visible {
            if let observer = statusMenuTrackingObserver {
                NotificationCenter.default.removeObserver(observer)
                statusMenuTrackingObserver = nil
            }
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
            return
        }
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let mark = Bundle.module.url(forResource: "CatchMenuBar", withExtension: "png")
            .flatMap { NSImage(contentsOf: $0) }
        mark?.size = NSSize(width: 18, height: 18)
        mark?.isTemplate = true
        mark?.accessibilityDescription = "Catch"
        item.button?.image = mark ?? NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Catch")
        item.menu = buildMenu()
        self.statusItem = item
    }

    private func buildMenu() -> NSMenu {
        if let observer = statusMenuTrackingObserver {
            NotificationCenter.default.removeObserver(observer)
            statusMenuTrackingObserver = nil
        }
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
        menu.addItem(makeItem("Catch Studio — Screen + Loom Bubble...", action: #selector(cmdOpenLoomStudio), key: ""))
        menu.addItem(makeItem("Catch Studio — Dual 4K ISO (Clean Screen + 4K Cam + WAV)...", action: #selector(cmdOpenDualISOStudio), key: ""))
        menu.addItem(makeItem("Catch Studio — Podcast Camera (Full 4K Cam + Teleprompter + WAV)...", action: #selector(cmdOpenPodcastCameraStudio), key: ""))
        menu.addItem(makeItem("Toggle Teleprompter", action: #selector(cmdToggleTeleprompter), key: ""))
        let endSession = makeItem("End Agent Capture Session", action: #selector(cmdEndAgentCaptureSession), key: "")
        menu.addItem(endSession)
        statusMenuTrackingObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: menu, queue: nil) { _ in
            endSession.isHidden = LocalStudioBridge.shared.captureKey == nil
        }
        menu.addItem(makeItem("Toggle Camera Bubble", action: #selector(cmdToggleCameraBubble), key: ""))
        menu.addItem(.separator())
        menu.addItem(makeItem("Capture Text (OCR)", action: #selector(cmdCaptureText), key: "2"))
        menu.addItem(makeItem("Read Aloud (Screenshot)", action: #selector(cmdReadAloud), key: ""))
        menu.addItem(makeItem("Open Annotate...", action: #selector(cmdOpenAnnotate), key: ""))
        menu.addItem(makeItem("Open from Clipboard", action: #selector(cmdOpenFromClipboard), key: ""))
        menu.addItem(makeItem("Pin Screenshot...", action: #selector(cmdPinFile), key: ""))
        menu.addItem(makeItem("Unlock All Pinned Screenshots", action: #selector(cmdUnlockPinned), key: ""))
        menu.addItem(.separator())
        menu.addItem(makeItem("Clipboard History...", action: #selector(cmdOpenClipboardHistory), key: ""))
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

    private func makeItem(
        _ title: String,
        action: Selector,
        key: String,
        modifiers: NSEvent.ModifierFlags? = nil
    ) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        if let modifiers {
            mi.keyEquivalentModifierMask = modifiers
        }
        return mi
    }

    private func makeResponderItem(
        _ title: String,
        action: Selector,
        key: String,
        modifiers: NSEvent.ModifierFlags? = nil
    ) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = nil
        if let modifiers {
            mi.keyEquivalentModifierMask = modifiers
        }
        return mi
    }

    @objc private func cmdAllInOne() { AllInOneHUDController.shared.show() }
    @objc private func cmdCaptureArea() { CaptureEngine.shared.captureArea() }
    @objc private func cmdCapturePreviousArea() { CaptureEngine.shared.capturePreviousArea() }
    @objc private func cmdCaptureFullscreen() { CaptureEngine.shared.captureFullscreen() }
    @objc private func cmdCaptureWindow() { CaptureEngine.shared.captureWindow() }
    @objc private func cmdSelfTimer() { CaptureEngine.shared.captureWithSelfTimer() }
    @objc private func cmdScrollingCapture() { ScrollingCaptureController.shared.beginScrollingCapture() }
    @objc private func cmdOpenLoomStudio() {
        ScreenRecordingStudio.shared.presentStudio(captureMode: .fullscreen, cameraMode: .floatingBubble)
    }
    @objc private func cmdOpenDualISOStudio() {
        ScreenRecordingStudio.shared.presentStudio(captureMode: .fullscreen, cameraMode: .separateFullResFile, exportWAVStems: true)
    }
    @objc private func cmdOpenPodcastCameraStudio() {
        ScreenRecordingStudio.shared.presentStudio(captureMode: .cameraOnly, exportWAVStems: true)
    }
    @objc private func cmdToggleTeleprompter() { TeleprompterController.shared.toggle() }
    @objc private func cmdEndAgentCaptureSession() { LocalStudioBridge.shared.endCaptureSession() }
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
            var eventSpecs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                              EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
                guard let userData, let event else { return noErr }
                var hkID = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
                let runner = Unmanaged<CatchAppRunner>.fromOpaque(userData).takeUnretainedValue()
                if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
                    if hkID.id == 22 { StudioInkOverlay.shared.end() }
                } else {
                    runner.hotKeyHandlers[hkID.id]?()
                }
                return noErr
            }, eventSpecs.count, &eventSpecs, Unmanaged.passUnretained(self).toOpaque(), nil)
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
        registerHotKey(id: 22, keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(cmdKey | shiftKey | optionKey)) {
            StudioInkOverlay.shared.begin()
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
