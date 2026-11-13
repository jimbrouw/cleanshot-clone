import Foundation
import AppKit
import SwiftUI

public final class SettingsWindowController {
    public static let shared = SettingsWindowController()
    private var window: NSWindow?

    public func show(tab: SettingsTab = .general) {
        DispatchQueue.main.async {
            if let existing = self.window {
                existing.contentView = NSHostingView(rootView: SettingsWindowView(initialTab: tab))
                existing.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            let win = NSWindow(
                contentRect: CGRect(x: 240, y: 160, width: 780, height: 580),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            win.title = "CleanShot Clone Settings"
            win.isReleasedWhenClosed = false
            win.contentView = NSHostingView(rootView: SettingsWindowView(initialTab: tab))
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            self.window = win
        }
    }
}

public struct SettingsWindowView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @State private var selectedTab: SettingsTab
    @State private var shortcutSearch = ""
    @State private var showFileNameBuilder = false

    public init(initialTab: SettingsTab = .general) {
        _selectedTab = State(initialValue: initialTab)
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                Label("General", systemImage: "gearshape").tag(SettingsTab.general)
                Label("Shortcuts", systemImage: "command").tag(SettingsTab.shortcuts)
                Label("Quick Access", systemImage: "rectangle.stack").tag(SettingsTab.quickaccess)
                Label("Wallpaper", systemImage: "photo").tag(SettingsTab.wallpaper)
                Label("Screenshots", systemImage: "camera.viewfinder").tag(SettingsTab.screenshots)
                Label("Screen Recording", systemImage: "record.circle").tag(SettingsTab.recording)
                Label("Annotate", systemImage: "pencil.tip").tag(SettingsTab.annotate)
                Label("Cloud", systemImage: "icloud").tag(SettingsTab.cloud)
                Label("Advanced", systemImage: "slider.horizontal.3").tag(SettingsTab.advanced)
                Label("About", systemImage: "info.circle").tag(SettingsTab.about)
            }
            .frame(minWidth: 185)
        } detail: {
            ScrollView {
                detailContent
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(isPresented: $showFileNameBuilder) {
            FileNameFormatBuilderSheet(settings: settings)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedTab {
        case .general: generalTab
        case .shortcuts: shortcutsTab
        case .quickaccess: quickAccessTab
        case .wallpaper: wallpaperTab
        case .screenshots: screenshotsTab
        case .recording: recordingTab
        case .annotate: annotateTab
        case .cloud: cloudTab
        case .advanced: advancedTab
        case .about: aboutTab
        }
    }

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("General").font(.title2.bold())
            Toggle("Launch at login", isOn: $settings.launchAtLogin)
            Toggle("Show menu bar icon", isOn: $settings.showMenuBarIcon)
            Toggle("Hide desktop icons while capturing", isOn: $settings.hideDesktopIconsWhileCapturing)
            Toggle("Play sounds", isOn: $settings.playSounds)

            Divider()
            Text("Export").font(.headline)
            HStack {
                Text("Export location: \(settings.exportLocationPath)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose...") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    if panel.runModal() == .OK, let url = panel.url {
                        settings.exportLocationURL = url
                    }
                }
            }

            Divider()
            Text("After Capture").font(.headline)
            ForEach(AfterCaptureAction.allCases, id: \.self) { action in
                Toggle(afterCaptureLabel(action), isOn: Binding(
                    get: { settings.afterCaptureActions.contains(action) },
                    set: { enabled in
                        if enabled {
                            if !settings.afterCaptureActions.contains(action) {
                                settings.afterCaptureActions.append(action)
                            }
                        } else {
                            settings.afterCaptureActions.removeAll { $0 == action }
                        }
                    }
                ))
            }
        }
    }

    private var shortcutsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shortcuts").font(.title2.bold())
            TextField("Search shortcuts", text: $shortcutSearch)
                .textFieldStyle(.roundedBorder)
            ForEach(settings.shortcuts.keys.sorted(), id: \.self) { key in
                if shortcutSearch.isEmpty || key.localizedCaseInsensitiveContains(shortcutSearch) {
                    HStack {
                        Text(key)
                        Spacer()
                        Text(settings.shortcuts[key]?.displayString ?? "")
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }

    private var quickAccessTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Quick Access").font(.title2.bold())
            Picker("Position on screen", selection: $settings.overlayPosition) {
                Text("Left").tag(OverlayPosition.left)
                Text("Right").tag(OverlayPosition.right)
            }
            .pickerStyle(.segmented)
            Toggle("Move to active screen", isOn: $settings.moveToActiveScreen)
            Slider(value: $settings.overlaySize, in: 0.75...1.5) {
                Text("Overlay size: \(Int(settings.overlaySize * 100))%")
            }

            Divider()
            Toggle("Auto-close", isOn: $settings.autoCloseEnabled)
            Picker("Auto-close Action", selection: $settings.autoCloseAction) {
                Text("Save and Close").tag(AutoCloseAction.saveAndClose)
                Text("Close").tag(AutoCloseAction.close)
            }
            Stepper("Interval: \(settings.autoCloseIntervalSeconds) seconds", value: $settings.autoCloseIntervalSeconds, in: 5...300, step: 5)
            Toggle("Close after dragging", isOn: $settings.closeAfterDragging)
            Toggle("Close after uploading", isOn: $settings.closeAfterUploading)
            Picker("Save button behavior", selection: $settings.saveButtonBehavior) {
                Text("Save to Export location").tag(SaveButtonBehavior.saveToExportLocation)
                Text("Ask destination").tag(SaveButtonBehavior.askDestination)
            }
        }
    }

    private var wallpaperTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Wallpaper").font(.title2.bold())
            Picker("Background source", selection: $settings.desktopWallpaperMode) {
                Text("Desktop wallpaper").tag(DesktopWallpaperMode.desktopWallpaper)
                Text("Custom image").tag(DesktopWallpaperMode.customImage)
                Text("Plain color").tag(DesktopWallpaperMode.plainColor)
            }
            if settings.desktopWallpaperMode == .customImage {
                HStack {
                    Text(settings.customWallpaperPath.isEmpty ? "No image selected" : settings.customWallpaperPath)
                        .lineLimit(1)
                    Spacer()
                    Button("Choose...") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.image]
                        if panel.runModal() == .OK, let url = panel.url {
                            settings.customWallpaperPath = url.path
                        }
                    }
                }
            } else if settings.desktopWallpaperMode == .plainColor {
                TextField("Color Hex", text: $settings.customWallpaperColorHex)
                    .textFieldStyle(.roundedBorder)
            }
            Toggle("Update wallpaper when switching Spaces", isOn: $settings.updateWallpaperWhenSwitchingSpaces)
        }
    }

    private var screenshotsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Screenshots").font(.title2.bold())
            Picker("File format", selection: $settings.outputFormat) {
                ForEach(ScreenshotFormat.allCases, id: \.self) { fmt in
                    Text(fmt.rawValue.uppercased()).tag(fmt)
                }
            }
            Toggle("Convert to sRGB profile", isOn: $settings.convertToSRGB)
            Toggle("Scale Retina screenshots to 1x", isOn: $settings.scaleRetinaTo1x)
            Toggle("Add 1px border to all screenshots", isOn: $settings.add1pxBorder)

            Divider()
            Stepper("Self-Timer interval: \(settings.selfTimerIntervalSeconds) Seconds", value: $settings.selfTimerIntervalSeconds, in: 1...30)
            Toggle("Show cursor on screenshots", isOn: $settings.showCursorOnScreenshots)
            Toggle("Freeze screen when taking a screenshot", isOn: $settings.freezeScreenWhenCapturing)

            Divider()
            Text("Window Screenshots").font(.headline)
            Picker("Background", selection: $settings.windowScreenshotBackgroundMode) {
                Text("With wallpaper").tag(WindowBackgroundMode.withWallpaper)
                Text("Transparent").tag(WindowBackgroundMode.transparent)
            }
            Slider(value: $settings.windowScreenshotPadding, in: 0...120) {
                Text("Padding: \(Int(settings.windowScreenshotPadding))px")
            }
            Toggle("Capture window shadow", isOn: $settings.captureWindowShadow)

            Divider()
            Text("Crosshair").font(.headline)
            Picker("Crosshair Mode", selection: $settings.crosshairMode) {
                Text("Enabled").tag(CrosshairMode.enabled)
                Text("Disabled").tag(CrosshairMode.disabled)
            }
            Toggle("Show magnifier", isOn: $settings.showMagnifier)
                .disabled(settings.crosshairMode == .disabled)
        }
    }

    private var recordingTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Screen Recording").font(.title2.bold())
            Text("Screenshots & Annotation suite is active; recording preferences are synchronized here.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Show controls while recording", isOn: $settings.recordingShowControls)
            Toggle("Remember last selection", isOn: $settings.recordingRememberLastSelection)
            Stepper("Video Frame rate: \(settings.recordingFrameRate) fps", value: $settings.recordingFrameRate, in: 15...60, step: 15)
            Toggle("Scale Retina videos to 1x", isOn: $settings.recordingScaleRetinaTo1x)
            Toggle("Record system audio", isOn: $settings.recordingRecordSystemAudio)
            Stepper("GIF Frame rate: \(settings.recordingGifFrameRate) fps", value: $settings.recordingGifFrameRate, in: 5...30, step: 5)
        }
    }

    private var annotateTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Annotate").font(.title2.bold())
            Toggle("Inverse arrow direction", isOn: $settings.inverseArrowDirection)
            Toggle("Smooth drawing", isOn: $settings.smoothDrawing)
            Toggle("Remember if background tool was opened", isOn: $settings.rememberBackgroundToolOpened)
            Toggle("Draw shadow on objects", isOn: $settings.drawShadowOnObjects)
            Toggle("Automatically expand canvas", isOn: $settings.automaticallyExpandCanvas)
            Divider()
            Toggle("Always on top", isOn: $settings.annotateAlwaysOnTop)
            Toggle("Show Dock icon", isOn: $settings.showDockIconInAnnotate)
            Toggle("Show color names", isOn: $settings.showColorNames)
        }
    }

    private var cloudTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cloud").font(.title2.bold())
            TextField("Account Name", text: $settings.accountName)
                .textFieldStyle(.roundedBorder)
            Picker("Screenshot quality", selection: $settings.screenshotUploadQuality) {
                Text("Optimized for sharing").tag(CloudUploadQuality.optimizedForSharing)
                Text("Original").tag(CloudUploadQuality.original)
            }
            Toggle("Ask for name & show advanced options", isOn: $settings.askForNameAndAdvancedOptionsOnUpload)
            Toggle("Copy link when upload starts", isOn: $settings.copyLinkWhenUploadStarts)
            Toggle("Show recently uploaded media in Menu Bar", isOn: $settings.showRecentlyUploadedInMenuBar)
        }
    }

    private var advancedTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Advanced").font(.title2.bold())
            Toggle("Ask for name after every capture", isOn: $settings.askForNameAfterCapture)
            HStack {
                Text("File name format: \(settings.fileNameFormat)")
                    .lineLimit(1)
                Spacer()
                Button("Customize...") {
                    showFileNameBuilder = true
                }
            }
            Toggle("Add \"@2x\" suffix to Retina screenshots", isOn: $settings.add2xSuffixToRetina)

            Picker("Copy to clipboard", selection: $settings.clipboardCopyMode) {
                Text("File & Image (default)").tag(ClipboardCopyMode.fileAndImage)
                Text("Image only").tag(ClipboardCopyMode.imageOnly)
                Text("File only").tag(ClipboardCopyMode.fileOnly)
            }

            Picker("Keep history", selection: $settings.keepHistoryDuration) {
                ForEach(HistoryRetentionDuration.allCases, id: \.self) { dur in
                    Text(dur.displayName).tag(dur)
                }
            }

            Divider()
            Text("Text Recognition").font(.headline)
            TextField("Language (auto or ISO code e.g. en-US)", text: $settings.ocrLanguage)
                .textFieldStyle(.roundedBorder)
            Toggle("Keep line breaks", isOn: $settings.ocrKeepLineBreaks)
            Toggle("Detect links", isOn: $settings.ocrDetectLinks)

            Divider()
            Text("All-In-One & Pinned Screenshots").font(.headline)
            Toggle("Remember last selection", isOn: $settings.allInOneRememberLastSelection)
            Toggle("Pinned: Rounded corners", isOn: $settings.pinnedRoundedCorners)
            Toggle("Pinned: Shadow", isOn: $settings.pinnedShadow)
            Toggle("Pinned: Border", isOn: $settings.pinnedBorder)

            Divider()
            Toggle("Allow URL scheme API (cleanshot://)", isOn: $settings.allowURLSchemeAPI)
        }
    }

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CleanShot Clone").font(.title.bold())
            Text("Native macOS Screen Capture, Annotation, Background Tool, Scrolling Capture, OCR & Pinned Screenshot Suite.")
                .foregroundStyle(.secondary)
            Text("URL Scheme API: cleanshot:// & cleanshotclone://")
                .font(.caption.monospaced())
        }
    }

    private func afterCaptureLabel(_ action: AfterCaptureAction) -> String {
        switch action {
        case .showQuickAccessOverlay: return "Show Quick Access Overlay"
        case .copyToClipboard: return "Copy file to clipboard"
        case .save: return "Save"
        case .uploadToCloud: return "Upload to Cloud & copy link"
        case .openAnnotate: return "Open Annotate tool"
        case .pinToScreen: return "Pin to the screen"
        }
    }
}

private struct FileNameFormatBuilderSheet: View {
    @ObservedObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var draftFormat: String

    init(settings: SettingsStore) {
        self.settings = settings
        _draftFormat = State(initialValue: settings.fileNameFormat)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Customize File Name Format").font(.headline)
            TextField("Pattern", text: $draftFormat)
                .textFieldStyle(.roundedBorder)

            Text("Preview: \(FileNameFormatter.format(pattern: draftFormat, windowTitle: "Browser", appName: "Safari", useUTC: settings.useUTCTimeZone, removeIllegalCharacters: settings.removeIllegalCharacters))")
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6)], spacing: 6) {
                ForEach(FileNameFormatter.availableTokens) { token in
                    Button("\(token.label): \(token.token)") {
                        draftFormat += token.token
                    }
                    .controlSize(.small)
                }
            }

            Toggle("Remove illegal characters", isOn: $settings.removeIllegalCharacters)
            Toggle("Use UTC time zone", isOn: $settings.useUTCTimeZone)

            HStack {
                Button("Restore Defaults") {
                    draftFormat = "CleanShot %y-%m-%d at %H.%M.%S"
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("OK") {
                    settings.fileNameFormat = draftFormat
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
