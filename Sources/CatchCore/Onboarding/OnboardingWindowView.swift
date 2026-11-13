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
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.minSize = NSSize(width: 780, height: 600)
        w.title = "Welcome to Catch"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.backgroundColor = .clear
        w.isOpaque = false
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
            return "Catch needs Screen Recording to capture displays and Accessibility to register global keyboard shortcuts."
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var stepNamespace
    @State private var currentStep: OnboardingStep
    public var onFinish: () -> Void
    public var onClose: () -> Void

    public init(initialStep: Int = 0, onFinish: @escaping () -> Void, onClose: @escaping () -> Void) {
        self._currentStep = State(initialValue: OnboardingStep(rawValue: initialStep) ?? .permissions)
        self.onFinish = onFinish
        self.onClose = onClose
    }

    public var body: some View {
        ZStack {
            RaycastVisualEffectBackground(cornerRadius: 0, tintAlpha: 0.86, material: .underWindowBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar
                Rectangle().fill(RaycastTheme.borderSubtle).frame(height: 1)

                VStack(spacing: 14) {
                    animationStage
                        .frame(height: 196)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color(red: 0.06, green: 0.08, blue: 0.13))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(RaycastTheme.specularGradient, lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.42), radius: 14, x: 0, y: 6)
                        .id(currentStep)
                        .transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98)), removal: .opacity))

                    VStack(spacing: 5) {
                        Text(currentStep.headline)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(RaycastTheme.textPrimary)
                            .contentTransition(.interpolate)
                        Text(currentStep.subtitle)
                            .font(.system(size: 12.5))
                            .foregroundStyle(RaycastTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 660)
                    }

                    stepActionPanel
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .id("panel-\(currentStep.rawValue)")
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 14)

                Rectangle().fill(RaycastTheme.borderSubtle).frame(height: 1)
                footerBar
            }
        }
        .frame(minWidth: 780, idealWidth: 880, minHeight: 600, idealHeight: 640)
        .preferredColorScheme(.dark)
        .onAppear {
            permissions.startPolling(interval: 1.0)
        }
        .onDisappear {
            permissions.stopPolling()
        }
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(RaycastTheme.accent.opacity(0.18))
                        .frame(width: 28, height: 28)
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(RaycastTheme.accent)
                }
                Text("Catch Setup")
                    .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(RaycastTheme.textPrimary)
            }
            .padding(.leading, 56) // Clear macOS traffic light buttons cleanly per HIG

            Spacer()

            RaycastGlassContainer(spacing: 4) {
                HStack(spacing: 4) {
                    ForEach(OnboardingStep.allCases) { step in
                        let isActive = step == currentStep
                        Button {
                            withAnimation(reduceMotion ? nil : .snappy(duration: 0.32)) {
                                currentStep = step
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(isActive ? RaycastTheme.accent : RaycastTheme.textTertiary)
                                    .frame(width: 6, height: 6)
                                Text(step.title)
                                    .font(.system(size: 11, weight: isActive ? .semibold : .medium))
                                    .foregroundStyle(isActive ? RaycastTheme.textPrimary : RaycastTheme.textSecondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background {
                                if isActive {
                                    Capsule()
                                        .fill(Color.white.opacity(0.12))
                                        .overlay(Capsule().strokeBorder(RaycastTheme.specularGradient, lineWidth: 0.75))
                                        .matchedGeometryEffect(id: "activeStepPill", in: stepNamespace)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .background(Capsule().fill(Color.white.opacity(0.05)))
            }
        }
        .padding(.trailing, 24)
        .padding(.top, 14)
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
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(granted ? .green : Color.accentColor)
                    .symbolEffect(.pulse, isActive: !granted)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(RaycastTheme.textPrimary)
            }
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .bold))
                Text(granted ? "Granted" : "Required")
                    .font(.system(size: 10.5, weight: .bold))
            }
            .foregroundStyle(granted ? .green : .orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(
                Capsule()
                    .fill((granted ? Color.green : Color.orange).opacity(0.16))
                    .overlay(Capsule().strokeBorder((granted ? Color.green : Color.orange).opacity(0.35), lineWidth: 0.75))
            )
        }
        Text(detail)
            .font(.system(size: 12))
            .foregroundStyle(RaycastTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
        HStack(spacing: 8) {
            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
                .tint(granted ? .green : Color.accentColor)
                .disabled(granted)
            Button("Open Settings", action: openSettings)
                .buttonStyle(.bordered)
        }
    }
    .padding(15)
    .frame(maxWidth: .infinity, minHeight: 130)
    .raycastCardSurface(cornerRadius: 14, isHighlighted: granted)
}

    private var shortcutsPanel: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                if permissions.macOSScreenshotShortcutsDisabled {
                    Label("macOS built-in screenshot keys disabled — ⇧⌘3, ⇧⌘4, ⇧⌘5 are routed to Catch.", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Restore macOS Defaults") {
                        _ = permissions.restoreMacOSSystemScreenshotShortcuts()
                    }
                    .raycastGlassButton(prominent: false)
                } else {
                    Button {
                        _ = permissions.disableMacOSSystemScreenshotShortcuts()
                    } label: {
                        Label("Disable macOS Screenshot Shortcuts & Use ⇧⌘3 / ⇧⌘4 / ⇧⌘5", systemImage: "wand.and.stars")
                    }
                    .raycastGlassButton(prominent: true)
                    .tint(RaycastTheme.accent)

                    Button("Open Keyboard Settings") {
                        permissions.openKeyboardShortcutsSettings()
                    }
                    .raycastGlassButton(prominent: false)
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
                    .foregroundStyle(RaycastTheme.textSecondary)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity)
        .raycastCardSurface(cornerRadius: 14)
    }

    private func shortcutBadge(_ title: String, keys: String) -> some View {
        VStack(spacing: 5) {
            RaycastKeycapBadge(keys)
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(RaycastTheme.textSecondary)
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
                let sample = CaptureEngine.makeSyntheticImage(width: 960, height: 600, label: "Catch Demo")
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
                AnnotateWindowController.open(image: sample, title: "Catch Interactive Tour", state: state)
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
                _ = ClipboardHistoryStore.shared.recordText("https://catch.app/screenshots", sourceAppName: "Raycast Tour")
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
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(RaycastTheme.textPrimary)
            }
            Text(caption)
                .font(.system(size: 11.5))
                .foregroundStyle(RaycastTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
                .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 120)
        .raycastCardSurface(cornerRadius: 14)
    }

    private var footerBar: some View {
        HStack {
            Button("Skip Setup") {
                SettingsStore.shared.hasCompletedOnboarding = true
                onClose()
            }
            .buttonStyle(.plain)
            .foregroundStyle(RaycastTheme.textSecondary)

            Spacer()

            HStack(spacing: 10) {
                if currentStep != .permissions {
                    Button("Back") {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.32)) {
                            if let prev = OnboardingStep(rawValue: currentStep.rawValue - 1) {
                                currentStep = prev
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                }

                if currentStep != .workflow {
                    Button("Continue") {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.32)) {
                            if let next = OnboardingStep(rawValue: currentStep.rawValue + 1) {
                                currentStep = next
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accentColor)
                } else {
                    Button("Finish Setup & Start Using Catch") {
                        onFinish()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 14)
    }
}
