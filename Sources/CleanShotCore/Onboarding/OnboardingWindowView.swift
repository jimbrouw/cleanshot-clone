import SwiftUI
import AppKit

public final class OnboardingWindowController {
    public static let shared = OnboardingWindowController()
    private var window: NSWindow?

    public func show(initialStep: Int = 0) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = OnboardingWizardView(
            initialStep: initialStep,
            onFinish: { [weak self] in
                SettingsStore.shared.hasCompletedOnboarding = true
                self?.close()
                AllInOneHUDController.shared.show()
            },
            onClose: { [weak self] in
                self?.close()
            }
        )

        let hosting = NSHostingController(rootView: view)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title = "Welcome to CleanShot Clone"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.contentViewController = hosting
        w.center()
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = w
    }

    public func close() {
        SystemPermissionsManager.shared.stopPolling()
        window?.close()
        window = nil
    }
}

public enum OnboardingStep: Int, CaseIterable, Identifiable {
    case permissions = 0
    case shortcuts
    case captureModes
    case annotate
    case clipboard
    case workflow

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .permissions: return "Permissions"
        case .shortcuts: return "Shortcuts"
        case .captureModes: return "Capture"
        case .annotate: return "Annotate"
        case .clipboard: return "Clipboard"
        case .workflow: return "OCR & Pin"
        }
    }

    public var headline: String {
        switch self {
        case .permissions: return "Grant macOS Permissions in Seconds"
        case .shortcuts: return "Stop the macOS Screenshot Conflict"
        case .captureModes: return "Every Capture Mode in One HUD"
        case .annotate: return "Annotate, Beautify & Redact Instantly"
        case .clipboard: return "Raycast-Style Clipboard History & Sequential Paste"
        case .workflow: return "OCR Text Capture, Floating Pins & Quick Access"
        }
    }

    public var subtitle: String {
        switch self {
        case .permissions:
            return "CleanShot Clone needs Screen Recording to capture displays and Accessibility to register global keyboard shortcuts."
        case .shortcuts:
            return "macOS intercepts ⇧⌘3, ⇧⌘4, and ⇧⌘5 for its built-in screenshot tool. Disable them in 1 click or use our conflict-free ⌥⇧⌘ keys."
        case .captureModes:
            return "Capture an Area with pixel crosshair, snap clean Windows, capture full Scrolling pages, or open the All-In-One HUD."
        case .annotate:
            return "Drop gradient wallpapers with rounded corners and shadows, draw crisp arrows and counters, and pixelate secrets."
        case .clipboard:
            return "Search copied text, screenshots, links, colors, and files in a dark smoked-glass Raycast palette with OCR, QR decoding, and Sequential Paste."
        case .workflow:
            return "Extract selectable text from any screen region with on-device Vision OCR or pin references above every window."
        }
    }
}

public struct OnboardingWizardView: View {
    @ObservedObject private var permissions = SystemPermissionsManager.shared
    @State private var currentStep: OnboardingStep
    public var onFinish: () -> Void
    public var onClose: () -> Void

    public init(initialStep: Int = 0, onFinish: @escaping () -> Void, onClose: @escaping () -> Void) {
        self._currentStep = State(initialValue: OnboardingStep(rawValue: initialStep) ?? .permissions)
        self.onFinish = onFinish
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().opacity(0.3)

            VStack(spacing: 18) {
                animationStage
                    .frame(height: 225)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(red: 0.08, green: 0.10, blue: 0.16))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
                            )
                    )

                VStack(spacing: 6) {
                    Text(currentStep.headline)
                        .font(.system(size: 22, weight: .bold))
                    Text(currentStep.subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 640)
                }

                stepActionPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)

            Divider().opacity(0.3)
            footerBar
        }
        .frame(width: 860, height: 600)
        .onAppear {
            permissions.startPolling(interval: 1.0)
        }
        .onDisappear {
            permissions.stopPolling()
        }
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("CleanShot Clone Setup")
                    .font(.system(size: 14, weight: .semibold))
            }

            Spacer()

            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases) { step in
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            currentStep = step
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(step == currentStep ? Color.accentColor : Color.secondary.opacity(0.35))
                                .frame(width: 7, height: 7)
                            Text(step.title)
                                .font(.system(size: 11, weight: step == currentStep ? .bold : .medium))
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(step == currentStep ? Color.accentColor.opacity(0.15) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var animationStage: some View {
        switch currentStep {
        case .permissions:
            PermissionsStageAnimationView(
                hasScreenRecording: permissions.hasScreenRecording,
                hasAccessibility: permissions.hasAccessibility
            )
        case .shortcuts:
            ShortcutsStageAnimationView(macShortcutsDisabled: permissions.macOSScreenshotShortcutsDisabled)
        case .captureModes:
            CaptureModesStageAnimationView()
        case .annotate:
            AnnotateStageAnimationView()
        case .clipboard:
            ClipboardStageAnimationView()
        case .workflow:
            WorkflowStageAnimationView()
        }
    }

    @ViewBuilder
    private var stepActionPanel: some View {
        switch currentStep {
        case .permissions:
            permissionsPanel
        case .shortcuts:
            shortcutsPanel
        case .captureModes:
            captureModesPanel
        case .annotate:
            annotatePanel
        case .clipboard:
            clipboardPanel
        case .workflow:
            workflowPanel
        }
    }

    private var permissionsPanel: some View {
        HStack(spacing: 16) {
            permissionCard(
                icon: "rectangle.dashed.badge.record",
                title: "Screen Recording",
                detail: "Required to capture windows, areas, scrolling pages & OCR.",
                granted: permissions.hasScreenRecording,
                buttonTitle: permissions.hasScreenRecording ? "Granted" : "Grant Screen Recording",
                action: { _ = permissions.requestScreenRecording() },
                openSettings: { permissions.openScreenRecordingSettings() }
            )
            permissionCard(
                icon: "keyboard.badge.ellipsis",
                title: "Accessibility",
                detail: "Required for global hotkeys and window snapping.",
                granted: permissions.hasAccessibility,
                buttonTitle: permissions.hasAccessibility ? "Granted" : "Grant Accessibility",
                action: { _ = permissions.requestAccessibility() },
                openSettings: { permissions.openAccessibilitySettings() }
            )
        }
    }

    private func permissionCard(
        icon: String,
        title: String,
        detail: String,
        granted: Bool,
        buttonTitle: String,
        action: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(granted ? "Granted" : "Required")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(granted ? .green : .orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill((granted ? Color.green : Color.orange).opacity(0.15)))
            }
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                Button(buttonTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(granted ? .green : .accentColor)
                    .disabled(granted)
                Button("Open Settings", action: openSettings)
                    .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 132)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.09), lineWidth: 1))
        )
    }

    private var shortcutsPanel: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                if permissions.macOSScreenshotShortcutsDisabled {
                    Label("macOS built-in screenshot keys disabled — ⇧⌘3, ⇧⌘4, ⇧⌘5 are routed to CleanShot Clone.", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Restore macOS Defaults") {
                        _ = permissions.restoreMacOSSystemScreenshotShortcuts()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        _ = permissions.disableMacOSSystemScreenshotShortcuts()
                    } label: {
                        Label("Disable macOS Screenshot Shortcuts & Use ⇧⌘3 / ⇧⌘4 / ⇧⌘5", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Open Keyboard Settings") {
                        permissions.openKeyboardShortcutsSettings()
                    }
                    .buttonStyle(.bordered)
                }
            }

            HStack(spacing: 10) {
                shortcutBadge("All-In-One", keys: "⌥⇧⌘5")
                shortcutBadge("Capture Area", keys: "⌥⇧⌘4")
                shortcutBadge("Fullscreen", keys: "⌥⇧⌘3")
                shortcutBadge("Window", keys: "⌥⇧⌘W")
                shortcutBadge("Scrolling", keys: "⌥⇧⌘S")
                shortcutBadge("OCR Text", keys: "⌥⇧⌘2")
            }

            if let msg = permissions.lastActionMessage {
                Text(msg)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.09), lineWidth: 1))
        )
    }

    private func shortcutBadge(_ title: String, keys: String) -> some View {
        VStack(spacing: 4) {
            Text(keys)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var captureModesPanel: some View {
        HStack(spacing: 12) {
            demoActionTile(
                icon: "square.grid.2x2",
                title: "All-In-One HUD",
                caption: "One toolbar for Area, Window, Scrolling & OCR.",
                buttonTitle: "Try HUD"
            ) {
                AllInOneHUDController.shared.show()
            }
            demoActionTile(
                icon: "crop",
                title: "Area & Crosshair",
                caption: "Drag any region with live magnifier & pixel measurements.",
                buttonTitle: "Try Area Capture"
            ) {
                CaptureEngine.shared.captureArea()
            }
            demoActionTile(
                icon: "scroll",
                title: "Scrolling Capture",
                caption: "Stitch tall docs & chats automatically into one PNG.",
                buttonTitle: "Try Scrolling"
            ) {
                ScrollingCaptureController.shared.beginScrollingCapture()
            }
        }
    }

    private var annotatePanel: some View {
        HStack(spacing: 14) {
            demoActionTile(
                icon: "pencil.and.outline",
                title: "Interactive Annotation Demo",
                caption: "Opens the Annotate Editor with a sample canvas, gradient background, arrow, counter, and pixelate redaction.",
                buttonTitle: "Open Live Annotate Demo"
            ) {
                let sample = CaptureEngine.makeSyntheticImage(width: 960, height: 600, label: "CleanShot Clone Demo")
                var state = AnnotationDocumentState()
                state.background.mode = .gradient
                state.background.selectedBuiltInIndex = 0
                state.background.padding = 44
                state.background.cornerRadius = 16
                state.background.shadowRadius = 22
                state.annotations = [
                    AnnotationItem(
                        kind: .arrow,
                        startPoint: CodablePoint(x: 520, y: 360),
                        endPoint: CodablePoint(x: 340, y: 240),
                        color: CodableColor(hex: "#FF3B30"),
                        strokeWidth: 5
                    ),
                    AnnotationItem(
                        kind: .counter,
                        rect: CodableRect(x: 295, y: 200, width: 32, height: 32),
                        startPoint: CodablePoint(x: 310, y: 215),
                        color: CodableColor(hex: "#FF9500"),
                        strokeWidth: 3,
                        counterNumber: 1
                    ),
                    AnnotationItem(
                        kind: .pixelate,
                        rect: CodableRect(x: 240, y: 420, width: 320, height: 50),
                        color: CodableColor(hex: "#000000"),
                        strokeWidth: 16
                    )
                ]
                AnnotateWindowController.open(image: sample, title: "CleanShot Interactive Tour", state: state)
            }
        }
    }

    private var clipboardPanel: some View {
        HStack(spacing: 14) {
            demoActionTile(
                icon: "doc.on.clipboard",
                title: "Raycast Clipboard History (⌥⇧⌘V)",
                caption: "Smoked-glass master-detail search for text, images, files, links, emails, and hex/RGB colors with OCR & QR decode.",
                buttonTitle: "Try Raycast Clipboard History"
            ) {
                ClipboardWindowController.shared.show()
            }
            demoActionTile(
                icon: "list.number",
                title: "Sequential Paste (⌃⇧⌘V)",
                caption: "Copy several fields in a row, then tap Sequential Paste to step through and paste each item in order.",
                buttonTitle: "Seed & Preview"
            ) {
                _ = ClipboardHistoryStore.shared.recordText("#FF6363", sourceAppName: "Raycast Tour")
                _ = ClipboardHistoryStore.shared.recordText("https://cleanshot.com/screenshots", sourceAppName: "Raycast Tour")
                ClipboardWindowController.shared.show()
            }
        }
    }

    private var workflowPanel: some View {
        HStack(spacing: 14) {
            demoActionTile(
                icon: "text.viewfinder",
                title: "Text Recognition (OCR)",
                caption: "Select any text on screen, email, or video and copy it instantly.",
                buttonTitle: "Try OCR"
            ) {
                OCRService.shared.captureTextFromScreen()
            }
            demoActionTile(
                icon: "pin.fill",
                title: "Pinned Floating Window",
                caption: "Keep a live reference screenshot floating above every app.",
                buttonTitle: "Try Floating Pin"
            ) {
                let sample = CaptureEngine.makeSyntheticImage(width: 440, height: 260, label: "Pinned Reference")
                PinnedScreenshotController.shared.pin(image: sample, title: "Pinned Demo")
            }
        }
    }

    private func demoActionTile(
        icon: String,
        title: String,
        caption: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .semibold))
            Text(caption)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 116)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.09), lineWidth: 1))
        )
    }

    private var footerBar: some View {
        HStack {
            Button("Skip Setup") {
                SettingsStore.shared.hasCompletedOnboarding = true
                onClose()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            if currentStep != .permissions {
                Button("Back") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        if let prev = OnboardingStep(rawValue: currentStep.rawValue - 1) {
                            currentStep = prev
                        }
                    }
                }
                .buttonStyle(.bordered)
            }

            if currentStep != .workflow {
                Button("Continue") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        if let next = OnboardingStep(rawValue: currentStep.rawValue + 1) {
                            currentStep = next
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Finish Setup & Start Using CleanShot Clone") {
                    onFinish()
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
}
