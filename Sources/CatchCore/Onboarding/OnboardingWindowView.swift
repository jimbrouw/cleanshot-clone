import SwiftUI
import AppKit

public final class OnboardingWindowController {
    public static let shared = OnboardingWindowController()
    private var window: NSWindow?

    public func show(initialStep: Int? = nil) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let resolvedStep = initialStep ?? OnboardingStateStore.savedStepIndex()
        let view = OnboardingWizardView(
            initialStep: resolvedStep,
            onFinish: { [weak self] in
                SettingsStore.shared.hasCompletedOnboarding = true
                OnboardingStateStore.clearSavedStep()
                CatchPermissionGuidePanel.shared.dismiss()
                self?.close()
                AllInOneHUDController.shared.show()
            },
            onClose: { [weak self] in
                CatchPermissionGuidePanel.shared.dismiss()
                self?.close()
            }
        )

        let hosting = NSHostingController(rootView: view)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 660),
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

// MARK: - Tool Selection Model & Persistence

public enum CatchOnboardingTool: String, CaseIterable, Identifiable, Sendable {
    case screenCapture
    case globalHotkeys
    case studioCamera
    case teleprompterVoice
    case clipboardHistory

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .screenCapture: return "Screen Capture, Scrolling & OCR"
        case .globalHotkeys: return "Global Hotkeys & Window Snap"
        case .studioCamera: return "Studio Camera Bubble & 4K ISO"
        case .teleprompterVoice: return "Teleprompter & Voice Tracking"
        case .clipboardHistory: return "Clipboard History & Sequential Paste"
        }
    }

    public var subtitle: String {
        switch self {
        case .screenCapture: return "Area crosshair, window capture, scrolling stitch, screen recording, and Vision OCR."
        case .globalHotkeys: return "Trigger captures from anywhere with ⌥⇧⌘ or ⇧⌘ shortcuts and snap windows cleanly."
        case .studioCamera: return "Floating webcam bubble for Loom-style walkthroughs and separate 4K camera stems."
        case .teleprompterVoice: return "Viewer-invisible notch script that follows your spoken words and paces stage cues."
        case .clipboardHistory: return "Smoked-glass history search for text, images, colors, QR codes, and Sequential Paste."
        }
    }

    public var symbolName: String {
        switch self {
        case .screenCapture: return "camera.viewfinder"
        case .globalHotkeys: return "command"
        case .studioCamera: return "video.circle.fill"
        case .teleprompterVoice: return "text.word.spacing"
        case .clipboardHistory: return "doc.on.clipboard.fill"
        }
    }

    public var requiredPermissions: [CatchPermissionKind] {
        switch self {
        case .screenCapture: return [.screenRecording]
        case .globalHotkeys: return [.accessibility]
        case .studioCamera: return [.camera, .screenRecording]
        case .teleprompterVoice: return [.microphone, .speechRecognition]
        case .clipboardHistory: return [.accessibility]
        }
    }
}

public enum CatchOnboardingPreset: String, CaseIterable, Identifiable, Sendable {
    case fullSuite
    case captureAndAnnotate
    case studioCreator

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fullSuite: return "Full Catch Suite"
        case .captureAndAnnotate: return "Screenshots & Annotate"
        case .studioCreator: return "Video Studio & Teleprompter"
        }
    }

    public var subtitle: String {
        switch self {
        case .fullSuite: return "Every capture, studio, teleprompter & clipboard tool."
        case .captureAndAnnotate: return "Lightweight setup — Screen Recording & Accessibility only."
        case .studioCreator: return "Screen capture, webcam bubble & voice-tracked teleprompter."
        }
    }

    public var symbolName: String {
        switch self {
        case .fullSuite: return "sparkles.rectangle.stack"
        case .captureAndAnnotate: return "crop"
        case .studioCreator: return "video.badge.waveform"
        }
    }

    public var tools: Set<CatchOnboardingTool> {
        switch self {
        case .fullSuite:
            return Set(CatchOnboardingTool.allCases)
        case .captureAndAnnotate:
            return [.screenCapture, .globalHotkeys, .clipboardHistory]
        case .studioCreator:
            return [.screenCapture, .globalHotkeys, .studioCamera, .teleprompterVoice]
        }
    }
}

public enum OnboardingStateStore {
    private static let stepKey = "com.catchapp.onboarding.savedStep"
    private static let toolsKey = "com.catchapp.onboarding.selectedTools"

    public static func savedStepIndex(defaults: UserDefaults = .standard) -> Int {
        let value = defaults.integer(forKey: stepKey)
        return OnboardingStep(rawValue: value)?.rawValue ?? 0
    }

    public static func saveStep(_ step: OnboardingStep, defaults: UserDefaults = .standard) {
        defaults.set(step.rawValue, forKey: stepKey)
    }

    public static func clearSavedStep(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: stepKey)
    }

    public static func loadSelectedTools(defaults: UserDefaults = .standard) -> Set<CatchOnboardingTool> {
        guard let rawValues = defaults.stringArray(forKey: toolsKey) else {
            return Set(CatchOnboardingTool.allCases)
        }
        let parsed = Set(rawValues.compactMap(CatchOnboardingTool.init(rawValue:)))
        return parsed
    }

    public static func saveSelectedTools(_ tools: Set<CatchOnboardingTool>, defaults: UserDefaults = .standard) {
        let rawValues = CatchOnboardingTool.allCases.filter { tools.contains($0) }.map(\.rawValue)
        defaults.set(rawValues, forKey: toolsKey)
    }

    public static func requiredPermissions(for tools: Set<CatchOnboardingTool>) -> [CatchPermissionKind] {
        let needed = Set(tools.flatMap(\.requiredPermissions))
        return CatchPermissionKind.allCases.filter { needed.contains($0) }
    }

    public static func optionalPermissions(for tools: Set<CatchOnboardingTool>) -> [CatchPermissionKind] {
        let needed = Set(tools.flatMap(\.requiredPermissions))
        return CatchPermissionKind.allCases.filter { !needed.contains($0) }
    }
}

public enum OnboardingStep: Int, CaseIterable, Identifiable {
    case tools = 0
    case permissions
    case shortcuts
    case captureModes
    case annotate
    case clipboard
    case workflow

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .tools: return "Tools"
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
        case .tools: return "Choose What You Want Catch to Do"
        case .permissions: return "Grant Permissions for Your Selected Tools"
        case .shortcuts: return "Stop the macOS Screenshot Conflict"
        case .captureModes: return "Every Capture Mode in One HUD"
        case .annotate: return "Annotate, Beautify & Redact Instantly"
        case .clipboard: return "Instant Clipboard History & Sequential Paste"
        case .workflow: return "OCR Text Capture, Floating Pins & Quick Access"
        }
    }

    public var subtitle: String {
        switch self {
        case .tools:
            return "Pick a preset or toggle individual tools. The next step will only ask for the macOS permissions your chosen tools actually need."
        case .permissions:
            return "Click Grant to open the macOS prompt or System Settings pane. Catch watches live and resumes right here if macOS relaunches for Screen Recording."
        case .shortcuts:
            return "macOS intercepts ⇧⌘3, ⇧⌘4, and ⇧⌘5 for its built-in screenshot tool. Disable them in 1 click or use our conflict-free ⌥⇧⌘ keys."
        case .captureModes:
            return "Capture an Area with pixel crosshair, snap clean Windows, capture full Scrolling pages, or open the All-In-One HUD."
        case .annotate:
            return "Drop gradient wallpapers with rounded corners and shadows, draw crisp arrows and counters, and pixelate secrets."
        case .clipboard:
            return "Search copied text, screenshots, links, colors, and files in a dark smoked-glass command palette with OCR, QR decoding, and Sequential Paste."
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
    @State private var selectedTools: Set<CatchOnboardingTool>
    @State private var showOptionalPermissions = false
    @State private var pollingSurfaceID = UUID()
    public var onFinish: () -> Void
    public var onClose: () -> Void

    public init(initialStep: Int = 0, onFinish: @escaping () -> Void, onClose: @escaping () -> Void) {
        self._currentStep = State(initialValue: OnboardingStep(rawValue: initialStep) ?? .tools)
        self._selectedTools = State(initialValue: OnboardingStateStore.loadSelectedTools())
        self.onFinish = onFinish
        self.onClose = onClose
    }

    private var activePreset: CatchOnboardingPreset? {
        CatchOnboardingPreset.allCases.first { $0.tools == selectedTools }
    }

    private var requiredPermissions: [CatchPermissionKind] {
        OnboardingStateStore.requiredPermissions(for: selectedTools)
    }

    private var optionalPermissions: [CatchPermissionKind] {
        OnboardingStateStore.optionalPermissions(for: selectedTools)
    }

    private var grantedRequiredCount: Int {
        requiredPermissions.filter { permissions.isGranted($0) }.count
    }

    public var body: some View {
        ZStack {
            RaycastVisualEffectBackground(cornerRadius: 0, tintAlpha: 0.86, material: .underWindowBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar
                Rectangle().fill(RaycastTheme.borderSubtle).frame(height: 1)

                ScrollView {
                    VStack(spacing: 14) {
                        if showsAnimationStage {
                            animationStage
                                .frame(height: 184)
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
                        }

                        VStack(spacing: 5) {
                            Text(currentStep.headline)
                                .font(.system(size: 21, weight: .bold, design: .rounded))
                                .foregroundStyle(RaycastTheme.textPrimary)
                                .contentTransition(.interpolate)
                            Text(currentStep.subtitle)
                                .font(.system(size: 12.5))
                                .foregroundStyle(RaycastTheme.textSecondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 680)
                        }
                        .padding(.top, showsAnimationStage ? 0 : 6)

                        stepActionPanel
                            .frame(maxWidth: .infinity, alignment: .top)
                            .id("panel-\(currentStep.rawValue)")
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
                    }
                    .padding(.horizontal, 26)
                    .padding(.vertical, 16)
                }

                Rectangle().fill(RaycastTheme.borderSubtle).frame(height: 1)
                footerBar
            }
        }
        .frame(minWidth: 780, idealWidth: 880, minHeight: 600, idealHeight: 660)
        .preferredColorScheme(.dark)
        .onAppear {
            OnboardingStateStore.saveStep(currentStep)
            permissions.setPollingSurface(pollingSurfaceID, visible: true)
        }
        .onChange(of: currentStep) { _, newStep in
            OnboardingStateStore.saveStep(newStep)
            if newStep == .permissions {
                permissions.refreshStatus()
            }
        }
        .onDisappear {
            permissions.setPollingSurface(pollingSurfaceID, visible: false)
        }
    }

    private var showsAnimationStage: Bool {
        currentStep != .tools && currentStep != .permissions
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
                            applyToolSelectionIfLeavingTools()
                            withAnimation(reduceMotion ? nil : .snappy(duration: 0.32)) {
                                currentStep = step
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(stepDotColor(for: step, isActive: isActive))
                                    .frame(width: 6, height: 6)
                                Text(step.title)
                                    .font(.system(size: 11, weight: isActive ? .semibold : .medium))
                                    .foregroundStyle(isActive ? RaycastTheme.textPrimary : RaycastTheme.textSecondary)
                            }
                            .padding(.horizontal, 9)
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

    private func stepDotColor(for step: OnboardingStep, isActive: Bool) -> Color {
        if step == .permissions && !requiredPermissions.isEmpty && grantedRequiredCount == requiredPermissions.count {
            return .green
        }
        return isActive ? RaycastTheme.accent : RaycastTheme.textTertiary
    }

    @ViewBuilder
    private var animationStage: some View {
        switch currentStep {
        case .tools, .permissions:
            EmptyView()
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
        case .tools:
            toolsSelectionPanel
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

    // MARK: - Step 0: Tool Selection

    private var toolsSelectionPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ForEach(CatchOnboardingPreset.allCases) { preset in
                    let isSelected = activePreset == preset
                    Button {
                        withAnimation(.easeOut(duration: 0.16)) {
                            selectedTools = preset.tools
                            OnboardingStateStore.saveSelectedTools(selectedTools)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 7) {
                                Image(systemName: preset.symbolName)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(isSelected ? RaycastTheme.accent : RaycastTheme.textSecondary)
                                Text(preset.title)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(RaycastTheme.textPrimary)
                                Spacer(minLength: 4)
                                if isSelected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 13))
                                        .foregroundStyle(RaycastTheme.accent)
                                }
                            }
                            Text(preset.subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(RaycastTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .raycastCardSurface(cornerRadius: 12, isHighlighted: isSelected)
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Text("TOOLS TO ENABLE")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.9)
                    .foregroundStyle(RaycastTheme.textTertiary)
                Spacer()
                Text("\(selectedTools.count) of \(CatchOnboardingTool.allCases.count) selected · \(requiredPermissions.count) permissions needed next")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(RaycastTheme.textSecondary)
            }
            .padding(.top, 2)

            VStack(spacing: 8) {
                ForEach(CatchOnboardingTool.allCases) { tool in
                    toolToggleRow(tool)
                }
            }
        }
    }

    private func toolToggleRow(_ tool: CatchOnboardingTool) -> some View {
        let isSelected = selectedTools.contains(tool)
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                if isSelected {
                    selectedTools.remove(tool)
                } else {
                    selectedTools.insert(tool)
                }
                OnboardingStateStore.saveSelectedTools(selectedTools)
            }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isSelected ? RaycastTheme.accent.opacity(0.20) : Color.white.opacity(0.06))
                        .frame(width: 34, height: 34)
                    Image(systemName: tool.symbolName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isSelected ? RaycastTheme.accent : RaycastTheme.textSecondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(tool.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(RaycastTheme.textPrimary)
                        ForEach(tool.requiredPermissions) { perm in
                            Text(perm.displayName)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(RaycastTheme.textSecondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.white.opacity(0.07)))
                        }
                    }
                    Text(tool.subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(RaycastTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isSelected ? RaycastTheme.accent : RaycastTheme.textTertiary)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .raycastCardSurface(cornerRadius: 12, isHighlighted: isSelected)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 1: Tailored Permissions (Working Grant Flow)

    private var permissionsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Live readiness summary header
            HStack(spacing: 10) {
                let allReady = !requiredPermissions.isEmpty && grantedRequiredCount == requiredPermissions.count
                Image(systemName: allReady ? "checkmark.seal.fill" : "key.horizontal.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(allReady ? .green : RaycastTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(requiredPermissions.isEmpty
                         ? "No permissions required for your current selection"
                         : allReady
                            ? "All \(requiredPermissions.count) permissions for your tools are granted"
                            : "\(grantedRequiredCount) of \(requiredPermissions.count) permissions granted")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(RaycastTheme.textPrimary)
                    Text("Permissions stay local to this Mac. You can change any toggle in System Settings anytime.")
                        .font(.system(size: 11))
                        .foregroundStyle(RaycastTheme.textSecondary)
                }
                Spacer()
                Button("Check Status") {
                    permissions.refreshStatus()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(13)
            .raycastCardSurface(cornerRadius: 12, isHighlighted: !requiredPermissions.isEmpty && grantedRequiredCount == requiredPermissions.count)

            if permissions.screenRecordingGrantedThisSession {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Screen Recording Granted — Relaunch Catch to Activate")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.green)
                        Text("macOS applies Screen Recording to fresh processes. Catch will reopen right on this screen.")
                            .font(.system(size: 11))
                            .foregroundStyle(RaycastTheme.textSecondary)
                    }
                    Spacer()
                    Button("Relaunch Catch") {
                        OnboardingStateStore.saveStep(.permissions)
                        permissions.relaunchApplication()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.small)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.green.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.green.opacity(0.35), lineWidth: 1)
                        )
                )
            }

            if !requiredPermissions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(requiredPermissions.enumerated()), id: \.element.id) { index, kind in
                        if index > 0 {
                            Divider()
                                .overlay(RaycastTheme.borderSubtle)
                                .padding(.vertical, 10)
                        }
                        permissionRow(kind, showUsedBy: true)
                    }
                }
                .padding(15)
                .raycastCardSurface(cornerRadius: 14)
            }

            if !optionalPermissions.isEmpty {
                DisclosureGroup(isExpanded: $showOptionalPermissions) {
                    VStack(spacing: 0) {
                        ForEach(Array(optionalPermissions.enumerated()), id: \.element.id) { index, kind in
                            if index > 0 {
                                Divider()
                                    .overlay(RaycastTheme.borderSubtle)
                                    .padding(.vertical, 10)
                            }
                            permissionRow(kind, showUsedBy: true)
                        }
                    }
                    .padding(.top, 12)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Other Optional Permissions (\(optionalPermissions.count))")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(RaycastTheme.textPrimary)
                        Text("Not required by your selected tools right now, but ready whenever you enable them.")
                            .font(.system(size: 11))
                            .foregroundStyle(RaycastTheme.textSecondary)
                    }
                }
                .padding(14)
                .raycastCardSurface(cornerRadius: 14)
            }

            if let message = permissions.lastActionMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(RaycastTheme.textSecondary)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func permissionRow(_ kind: CatchPermissionKind, showUsedBy: Bool) -> some View {
        let state = permissions.state(for: kind)
        let granted = state.isGranted
        let usedBy = toolNames(for: kind)

        return HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill((granted ? Color.green : Color.orange).opacity(0.16))
                    .frame(width: 34, height: 34)
                Image(systemName: kind.symbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(granted ? .green : .orange)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(kind.displayName)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(RaycastTheme.textPrimary)

                    HStack(spacing: 4) {
                        Image(systemName: granted ? "checkmark.circle.fill" : (state == .denied ? "xmark.circle.fill" : "exclamationmark.triangle.fill"))
                            .font(.system(size: 9.5, weight: .bold))
                        Text(granted ? "Granted" : (state == .denied ? "Denied" : "Not Granted"))
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(granted ? .green : (state == .denied ? .red : .orange))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(
                        Capsule()
                            .fill((granted ? Color.green : (state == .denied ? Color.red : Color.orange)).opacity(0.16))
                    )

                    Spacer()
                }

                Text(kind.summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(RaycastTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if showUsedBy && !usedBy.isEmpty {
                    Text("Used by: \(usedBy)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(RaycastTheme.textTertiary)
                }

                if !granted {
                    HStack(spacing: 8) {
                        Button(state == .denied ? "Open in Settings" : "Grant \(kind.displayName)") {
                            permissions.request(kind, showFloatingGuide: true)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(RaycastTheme.accent)
                        .controlSize(.small)

                        Button("Open Settings") {
                            permissions.openSettings(for: kind)
                            if kind.requiresSystemSettingsToggle {
                                CatchPermissionGuidePanel.shared.present(for: kind)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        if kind.requiresSystemSettingsToggle {
                            Button("Reset & Retry") {
                                permissions.resetAndRequest(kind, showFloatingGuide: true)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(RaycastTheme.textSecondary)
                            .controlSize(.small)
                            .help("Clears a stale macOS permission entry from an older build and asks fresh")
                        }
                    }
                    .padding(.top, 3)
                }
            }
        }
    }

    private func toolNames(for permission: CatchPermissionKind) -> String {
        let matchingSelected = CatchOnboardingTool.allCases.filter {
            selectedTools.contains($0) && $0.requiredPermissions.contains(permission)
        }
        let source = matchingSelected.isEmpty
            ? CatchOnboardingTool.allCases.filter { $0.requiredPermissions.contains(permission) }
            : matchingSelected
        return source.map(\.title).joined(separator: ", ")
    }

    private func applyToolSelectionIfLeavingTools() {
        guard currentStep == .tools else { return }
        OnboardingStateStore.saveSelectedTools(selectedTools)
        SettingsStore.shared.clipboardHistoryEnabled = selectedTools.contains(.clipboardHistory)
    }

    // MARK: - Step 2: Shortcuts

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

    // MARK: - Steps 3-6: Interactive Feature Tour

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
                title: "Clipboard History (⌥⇧⌘V)",
                caption: "Smoked-glass master-detail search for text, images, files, links, emails, and hex/RGB colors with OCR & QR decode.",
                buttonTitle: "Try Clipboard History"
            ) {
                ClipboardWindowController.shared.show()
            }
            demoActionTile(
                icon: "list.number",
                title: "Sequential Paste (⌃⇧⌘V)",
                caption: "Copy several fields in a row, then tap Sequential Paste to step through and paste each item in order.",
                buttonTitle: "Seed & Preview"
            ) {
                _ = ClipboardHistoryStore.shared.recordText("#FF6363", sourceAppName: "Catch Tour")
                _ = ClipboardHistoryStore.shared.recordText("https://catch.app/screenshots", sourceAppName: "Catch Tour")
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
                OnboardingStateStore.clearSavedStep()
                onClose()
            }
            .buttonStyle(.plain)
            .foregroundStyle(RaycastTheme.textSecondary)

            Spacer()

            HStack(spacing: 10) {
                if currentStep != .tools {
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
                    Button(currentStep == .tools ? "Continue to Permissions" : "Continue") {
                        applyToolSelectionIfLeavingTools()
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.32)) {
                            if let next = OnboardingStep(rawValue: currentStep.rawValue + 1) {
                                currentStep = next
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accentColor)
                } else {
                    Button("Finish Setup & Start Using Catch") {
                        onFinish()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 14)
    }
}
