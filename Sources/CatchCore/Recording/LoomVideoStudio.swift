import Foundation
import Combine
import AppKit
import SwiftUI
import AVFoundation
import CoreMedia
import CoreVideo
import ScreenCaptureKit

// MARK: - Teleprompter Controller (Viewer-Invisible Floating & Notch Script Panel)

public final class TeleprompterController: ObservableObject {
    public static let shared = TeleprompterController()

    private let scriptKey = "com.catchapp.teleprompter.script"
    private let wpmKey = "com.catchapp.teleprompter.wpm"
    private let fontSizeKey = "com.catchapp.teleprompter.fontSize"
    private let hideKey = "com.catchapp.teleprompter.hideFromCapture"
    private let notchModeKey = "com.catchapp.teleprompter.pinToNotch"

    public static let defaultScript = """
    Hey everyone — here is a quick walkthrough of what I built today.
    Notice how crisp the workflow feels when everything stays in one place.
    I can highlight key details on screen, drop my camera bubble right alongside, and read this script naturally while looking straight toward the webcam.
    Best of all, this teleprompter floats right beneath the notch and stays completely invisible in the final recording.
    """

    @Published public var scriptText: String {
        didSet {
            UserDefaults.standard.set(scriptText, forKey: scriptKey)
            if oldValue != scriptText { reset() }
        }
    }
    @Published public var wordsPerMinute: Double {
        didSet { UserDefaults.standard.set(wordsPerMinute, forKey: wpmKey) }
    }
    @Published public var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: fontSizeKey) }
    }
    @Published public private(set) var hideFromCapture: Bool {
        didSet {
            UserDefaults.standard.set(hideFromCapture, forKey: hideKey)
            panel?.sharingType = hideFromCapture ? .none : .readOnly
        }
    }
    @Published public var pinToNotch: Bool {
        didSet {
            UserDefaults.standard.set(pinToNotch, forKey: notchModeKey)
            if oldValue != pinToNotch, isVisible {
                reconfigurePanelGeometry()
            }
        }
    }
    @Published public var isPlaying: Bool = false
    @Published public var isEditingScript: Bool = false
    @Published public var scrollProgress: Double = 0.0
    @Published public var isVisible: Bool = false
    @Published private(set) var scrollMode: ScrollMode = .timed
    @Published private(set) var voiceStatus: VoiceStatus = .idle
    @Published private(set) var scriptAnchor: Int?
    @Published private(set) var nextSpokenWord: NSRange?
    @Published private(set) var readCharacterOffset: Int = 0
    @Published private(set) var audioLevels: [CGFloat] = Array(repeating: 0, count: 16)
    @Published private(set) var elapsedSeconds: Int = 0
    @Published private(set) var allowBackwardVisualTransition: Bool = true
    let scriptLayout = TeleprompterTextLayout()

    enum ScrollMode: String, CaseIterable {
        case timed = "Timed"
        case voice = "Voice"
        case followScript = "Follow Script"
    }

    enum VoiceStatus: Equatable {
        case idle, starting, waiting, speaking, stageDirection
        case unavailable(String)
    }

    private var panel: NSPanel?
    private var activeScreen: NSScreen?
    private var scrollTimer: Timer?
    private var voiceMonitor: TeleprompterVoiceMonitor?
    private var voiceSession: UUID?
    private var voiceGate = TeleprompterVoiceGate()
    private var speechTask: Task<Void, Never>?
    private var speechTracker: TeleprompterSpeechTracker?
    private var scriptMatcher: TeleprompterScriptMatcher?
    private var keepAwakeActivity: NSObjectProtocol?
    private var sessionStartUptime: TimeInterval?
    private var reachedEnd = false

    public var windowNumber: Int? {
        panel?.windowNumber
    }

    public func toggleHideFromCapture() {
        guard ScreenRecordingStudio.shared.state == .idle else { return }
        hideFromCapture.toggle()
    }

    public init() {
        let defaults = UserDefaults.standard
        self.scriptText = defaults.string(forKey: scriptKey) ?? Self.defaultScript
        let savedWPM = defaults.object(forKey: wpmKey) as? Double ?? 130.0
        self.wordsPerMinute = max(60.0, min(260.0, savedWPM))
        let savedFont = defaults.object(forKey: fontSizeKey) as? Double ?? 22.0
        self.fontSize = max(14.0, min(38.0, savedFont))
        self.hideFromCapture = defaults.object(forKey: hideKey) as? Bool ?? true
        self.pinToNotch = defaults.object(forKey: notchModeKey) as? Bool ?? false
    }

    public var wordCount: Int {
        scriptText
            .split { $0.isWhitespace || $0.isNewline }
            .count
    }

    public var estimatedDurationSeconds: TimeInterval {
        Double(max(1, wordCount)) / max(1.0, wordsPerMinute) * 60.0
    }

    public func show(on screen: NSScreen? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let studio = ScreenRecordingStudio.shared
            if self.hideFromCapture && self.panel == nil && studio.state != .idle {
                studio.recordingError = "Open the hidden teleprompter before starting a take so Catch can exclude it from the recording."
                return
            }
            self.isVisible = true
            let targetScreen = screen ?? CaptureEngine.shared.resolveScreen(displayIndex: nil)
            self.activeScreen = targetScreen
            if let existing = self.panel {
                existing.sharingType = self.hideFromCapture ? .none : .readOnly
                existing.orderFrontRegardless()
                return
            }

            let frame = self.panelFrame(for: targetScreen, pinnedToNotch: self.pinToNotch)
            let styleMask: NSWindow.StyleMask = self.pinToNotch
                ? [.borderless, .nonactivatingPanel]
                : [.borderless, .nonactivatingPanel, .resizable]

            let panel = KeyableHUDPanel(
                contentRect: frame,
                styleMask: styleMask,
                backing: .buffered,
                defer: false
            )
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isMovableByWindowBackground = !self.pinToNotch
            panel.minSize = NSSize(width: 380, height: 188)
            panel.maxSize = NSSize(width: 720, height: 480)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = !self.pinToNotch
            panel.sharingType = self.hideFromCapture ? .none : .readOnly

            let hosting = NSHostingView(rootView: TeleprompterPanelView(controller: self))
            panel.contentView = hosting
            panel.invalidateShadow()
            panel.orderFrontRegardless()
            self.panel = panel
        }
    }

    private func panelFrame(for screen: NSScreen, pinnedToNotch: Bool) -> CGRect {
        if pinnedToNotch {
            let menuBarHeight = max(28, screen.frame.maxY - screen.visibleFrame.maxY)
            let width: CGFloat = 520
            let height: CGFloat = 244 + menuBarHeight
            return CGRect(
                x: screen.frame.midX - width / 2,
                y: screen.frame.maxY - height,
                width: width,
                height: height
            )
        } else {
            let width: CGFloat = 520
            let height: CGFloat = 258
            return CGRect(
                x: screen.frame.midX - width / 2,
                y: screen.visibleFrame.maxY - height - 10,
                width: width,
                height: height
            )
        }
    }

    private func reconfigurePanelGeometry() {
        guard let panel else { return }
        let targetScreen = activeScreen ?? panel.screen ?? CaptureEngine.shared.resolveScreen(displayIndex: nil)
        let frame = panelFrame(for: targetScreen, pinnedToNotch: pinToNotch)
        panel.isMovableByWindowBackground = !pinToNotch
        panel.hasShadow = !pinToNotch
        if pinToNotch {
            panel.styleMask.remove(.resizable)
        } else {
            panel.styleMask.insert(.resizable)
        }
        panel.setFrame(frame, display: true, animate: true)
    }

    public func hide() {
        pause()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isVisible = false
            self.panel?.orderOut(nil)
            self.panel = nil
        }
    }

    public func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    public func play() {
        guard !isPlaying else { return }
        if reachedEnd {
            scrollProgress = 0.0
            readCharacterOffset = 0
            reachedEnd = false
        }
        isPlaying = true
        isEditingScript = false
        allowBackwardVisualTransition = false
        sessionStartUptime = ProcessInfo.processInfo.systemUptime - TimeInterval(elapsedSeconds)
        beginKeepAwake()
        scrollTimer?.invalidate()
        let tickInterval = 1.0 / 30.0
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            self?.advanceScroll(by: tickInterval)
        }
        RunLoop.main.add(timer, forMode: .common)
        scrollTimer = timer
        if scrollMode != .timed { startListening() }
    }

    private var readingProgress: Double {
        scriptAnchor.map { scriptLayout.progress(for: $0) } ?? scrollProgress
    }

    private func stageDirection(at progress: Double) -> TeleprompterTextLayout.StageDirection? {
        scriptLayout.stageDirections.first { $0.approach <= progress && progress < $0.end }
    }

    func advanceScroll(by seconds: TimeInterval) {
        guard isPlaying else { return }
        if let start = sessionStartUptime {
            let secs = max(0, Int(ProcessInfo.processInfo.systemUptime - start))
            if elapsedSeconds != secs { elapsedSeconds = secs }
        }

        let position = readingProgress
        if scrollMode != .timed {
            // Wait for microphone setup before starting the first timed cue.
            guard voiceStatus != .starting else { return }
            if let cue = stageDirection(at: position) {
                let duration = max(1.5, Double(cue.wordCount) * 60 / max(1, wordsPerMinute))
                let next = min(cue.end, max(position, cue.start) + (cue.end - cue.start) * seconds / duration)
                scriptAnchor = nil
                if nextSpokenWord != nil { nextSpokenWord = nil }
                scrollProgress = next
                readCharacterOffset = max(readCharacterOffset, scriptLayout.character(at: next))
                if next >= cue.end {
                    if cue.endsScript {
                        reachedEnd = true
                        pause()
                        return
                    }
                    voiceGate = TeleprompterVoiceGate()
                    voiceStatus = .waiting
                    nextSpokenWord = scriptMatcher?.nextSpokenWord
                } else if voiceStatus != .stageDirection {
                    voiceStatus = .stageDirection
                }
                return
            }
            guard scrollMode == .voice, voiceMonitor != nil else { return }
            let active = voiceGate.shouldScroll(at: ProcessInfo.processInfo.systemUptime)
            let status: VoiceStatus = active ? .speaking : .waiting
            if voiceStatus != status { voiceStatus = status }
            guard active else { return }
        }

        let next = min(1, scrollProgress + seconds / max(4, estimatedDurationSeconds))
        scrollProgress = next
        readCharacterOffset = max(readCharacterOffset, scriptLayout.character(at: next))
        if next >= 1 {
            reachedEnd = true
            pause()
        }
    }

    public func pause() {
        isPlaying = false
        endKeepAwake()
        scrollTimer?.invalidate()
        scrollTimer = nil
        voiceSession = nil
        voiceMonitor?.stop()
        voiceMonitor = nil
        speechTask?.cancel()
        speechTask = nil
        if let tracker = speechTracker {
            speechTracker = nil
            Task { @MainActor in tracker.stop() }
        }
        scriptMatcher = nil
        nextSpokenWord = nil
        voiceGate = TeleprompterVoiceGate()
        voiceStatus = .idle
        audioLevels = Array(repeating: 0, count: 16)
    }

    public func reset() {
        pause()
        allowBackwardVisualTransition = true
        reachedEnd = false
        scriptAnchor = nil
        scrollProgress = 0.0
        readCharacterOffset = 0
        elapsedSeconds = 0
        sessionStartUptime = nil
    }

    func rewind() {
        pause()
        allowBackwardVisualTransition = true
        reachedEnd = false
        let rewound = scriptLayout.rewind(progress: scrollProgress, anchor: scriptAnchor)
        scrollProgress = rewound
        scriptAnchor = nil
        readCharacterOffset = scriptLayout.character(at: rewound)
    }

    /// Click any word in the teleprompter to jump straight there without stopping live tracking.
    func jump(toCharacter offset: Int) {
        let clamped = max(0, min(offset, (scriptText as NSString).length))
        let previousOffset = scriptAnchor ?? scriptLayout.character(at: scrollProgress)
        let distance = abs(clamped - previousOffset)

        allowBackwardVisualTransition = true
        reachedEnd = false
        scrollProgress = scriptLayout.progress(for: clamped)
        readCharacterOffset = clamped

        if scrollMode == .followScript && isPlaying {
            scriptAnchor = clamped
            if scriptMatcher != nil {
                scriptMatcher?.jump(to: clamped)
            } else {
                scriptMatcher = TeleprompterScriptMatcher(script: scriptText, at: clamped)
            }
            nextSpokenWord = stageDirection(at: readingProgress) == nil ? scriptMatcher?.nextSpokenWord : nil
            if let tracker = speechTracker {
                Task { @MainActor in tracker.noteJump(to: clamped, distance: distance) }
            }
        } else {
            scriptAnchor = nil
        }

        DispatchQueue.main.async { [weak self] in
            if self?.isPlaying == true {
                self?.allowBackwardVisualTransition = false
            }
        }
    }

    /// Smoothly scrub reading position via trackpad/mouse wheel.
    func scrub(toProgress progress: Double) {
        let clamped = max(0, min(1, progress))
        let targetChar = scriptLayout.character(at: clamped)
        let previousChar = scriptAnchor ?? scriptLayout.character(at: scrollProgress)
        let distance = abs(targetChar - previousChar)

        allowBackwardVisualTransition = true
        reachedEnd = false
        scrollProgress = clamped
        scriptAnchor = nil
        readCharacterOffset = targetChar

        if scrollMode == .followScript && isPlaying {
            scriptMatcher?.jump(to: targetChar)
            nextSpokenWord = stageDirection(at: clamped) == nil ? scriptMatcher?.nextSpokenWord : nil
            if let tracker = speechTracker {
                Task { @MainActor in tracker.noteJump(to: targetChar, distance: distance) }
            }
        }
    }

    func selectScrollMode(_ mode: ScrollMode) {
        guard mode != scrollMode else { return }
        let wasPlaying = isPlaying
        pause()
        if let scriptAnchor {
            scrollProgress = scriptLayout.progress(for: scriptAnchor)
            self.scriptAnchor = nil
        }
        scrollMode = mode
        if wasPlaying { play() }
    }

    private func recordAudioLevel(_ level: CGFloat) {
        var next = audioLevels
        next.append(level)
        if next.count > 16 {
            next.removeFirst(next.count - 16)
        }
        audioLevels = next
    }

    private func beginKeepAwake() {
        endKeepAwake()
        keepAwakeActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled],
            reason: "Catch teleprompter playback"
        )
    }

    private func endKeepAwake() {
        guard let keepAwakeActivity else { return }
        ProcessInfo.processInfo.endActivity(keepAwakeActivity)
        self.keepAwakeActivity = nil
    }

    private func startListening() {
        StudioMicrophoneMeter.shared.stop()
        let session = UUID()
        voiceSession = session
        voiceStatus = .starting

        let message = "Allow Catch to use the microphone in System Settings."
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            openMicrophone(session: session)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.voiceSession == session else { return }
                    if granted {
                        self.openMicrophone(session: session)
                    } else {
                        self.failVoiceScroll(message)
                    }
                }
            }
        default:
            failVoiceScroll(message)
        }
    }

    private func openMicrophone(session: UUID) {
        if scrollMode == .followScript {
            startScriptTracking(session: session)
        } else {
            openVoiceMonitor(session: session)
        }
    }

    private func startScriptTracking(session: UUID) {
        speechTask = Task { @MainActor [weak self] in
            guard let self, self.voiceSession == session else { return }
            let offset = self.scriptAnchor ?? self.scriptLayout.character(at: self.scrollProgress)
            self.scriptMatcher = TeleprompterScriptMatcher(script: self.scriptText, at: offset)
            self.readCharacterOffset = max(self.readCharacterOffset, self.scriptMatcher?.completedCharacterOffset ?? offset)
            self.nextSpokenWord = self.stageDirection(at: self.readingProgress) == nil
                ? self.scriptMatcher?.nextSpokenWord : nil

            let tracker = TeleprompterSpeechTracker(
                preferredMicUID: { SettingsStore.shared.recordingMicrophoneID },
                onPhrase: { [weak self] phrase, isFinal in
                    guard let self, self.voiceSession == session,
                          self.stageDirection(at: self.readingProgress) == nil,
                          let position = self.scriptMatcher?.advance(with: phrase, isFinal: isFinal) else { return }
                    self.allowBackwardVisualTransition = false
                    self.scriptAnchor = position
                    self.readCharacterOffset = max(
                        self.readCharacterOffset,
                        self.scriptMatcher?.completedCharacterOffset ?? position
                    )
                    self.nextSpokenWord = self.stageDirection(at: self.readingProgress) == nil
                        ? self.scriptMatcher?.nextSpokenWord : nil
                },
                onLevel: { [weak self] level in
                    guard let self, self.voiceSession == session else { return }
                    self.recordAudioLevel(level)
                },
                onFailure: { [weak self] message in
                    guard let self, self.voiceSession == session else { return }
                    self.failVoiceScroll(message)
                }
            )
            self.speechTracker = tracker
            do {
                try await tracker.start(script: self.scriptText, startingAt: offset)
                if self.voiceSession == session { self.voiceStatus = .waiting }
            } catch {
                guard self.voiceSession == session else { return }
                self.failVoiceScroll(error.localizedDescription.isEmpty
                    ? "Couldn't start Follow Script. Check your microphone or choose Voice."
                    : error.localizedDescription)
            }
        }
    }

    private func openVoiceMonitor(session: UUID) {
        let monitor = TeleprompterVoiceMonitor(
            preferredMicUID: { SettingsStore.shared.recordingMicrophoneID },
            onSpeech: { [weak self] time in
                guard let self, self.voiceSession == session else { return }
                self.voiceGate.noteSpeech(at: time)
            },
            onLevel: { [weak self] level in
                guard let self, self.voiceSession == session else { return }
                self.recordAudioLevel(level)
            },
            onFailure: { [weak self] in
                guard let self, self.voiceSession == session else { return }
                self.failVoiceScroll("Microphone changed or stopped. Press Scroll to try again.")
            }
        )

        do {
            try monitor.start()
            voiceMonitor = monitor
            voiceStatus = .waiting
        } catch {
            failVoiceScroll("Couldn't start voice scrolling. Check your microphone input.")
        }
    }

    private func failVoiceScroll(_ message: String) {
        pause()
        voiceStatus = .unavailable(message)
    }
}

/// Concave top-corner Dynamic Island silhouette for notch-pinned teleprompter presentation.
/// Shape concept adapted from Textream (MIT License, Copyright (c) 2026 Fatih Kadir Akin).
private struct TeleprompterNotchShape: Shape {
    var topInset: CGFloat = 14
    var bottomRadius: CGFloat = 18

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let t = topInset
        let br = bottomRadius
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addQuadCurve(to: CGPoint(x: t, y: t), control: CGPoint(x: t, y: 0))
        p.addLine(to: CGPoint(x: t, y: h - br))
        p.addQuadCurve(to: CGPoint(x: t + br, y: h), control: CGPoint(x: t, y: h))
        p.addLine(to: CGPoint(x: w - t - br, y: h))
        p.addQuadCurve(to: CGPoint(x: w - t, y: h - br), control: CGPoint(x: w - t, y: h))
        p.addLine(to: CGPoint(x: w - t, y: t))
        p.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - t, y: 0))
        p.closeSubpath()
        return p
    }
}

private struct TeleprompterMiniWaveform: View {
    let levels: [CGFloat]
    let active: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 1.5) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                RoundedRectangle(cornerRadius: 1)
                    .fill(active ? RaycastTheme.accent.opacity(0.45 + Double(level) * 0.55) : Color.white.opacity(0.18))
                    .frame(width: 2, height: max(3, min(14, level * 14 + 2)))
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
        .frame(height: 14)
    }
}

private struct TeleprompterPanelView: View {
    @ObservedObject var controller: TeleprompterController

    private var elapsedLabel: String {
        String(format: "%02d:%02d", controller.elapsedSeconds / 60, controller.elapsedSeconds % 60)
    }

    private var statusText: String {
        switch controller.voiceStatus {
        case .idle:
            return "\(controller.wordCount)w · \(Int(controller.wordsPerMinute)) WPM"
        case .starting:
            return "Starting mic…"
        case .waiting:
            return controller.scrollMode == .followScript ? "Following" : "Listening"
        case .speaking:
            return "Speaking"
        case .stageDirection:
            return "Stage cue"
        case .unavailable:
            return "Mic issue"
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            if controller.pinToNotch {
                Spacer().frame(height: 24)
            }

            // Top bar: notch-aligned camera indicator + privacy badge + live telemetry
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(controller.isPlaying ? RaycastTheme.accent : Color.green)
                        .frame(width: 6, height: 6)
                    Text("TELEPROMPTER")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(RaycastTheme.textSecondary)
                }

                Button {
                    controller.toggleHideFromCapture()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: controller.hideFromCapture ? "eye.slash.fill" : "eye.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text(controller.hideFromCapture ? "Invisible" : "Visible")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(controller.hideFromCapture ? Color.green : Color.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(
                        Capsule()
                            .fill((controller.hideFromCapture ? Color.green : Color.orange).opacity(0.18))
                            .overlay(
                                Capsule()
                                    .strokeBorder((controller.hideFromCapture ? Color.green : Color.orange).opacity(0.45), lineWidth: 1)
                            )
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Change teleprompter visibility on recordings between takes")

                Button {
                    controller.pinToNotch.toggle()
                } label: {
                    Image(systemName: controller.pinToNotch ? "macwindow.on.rectangle" : "rectangle.topthird.inset.filled")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(controller.pinToNotch ? RaycastTheme.accent : RaycastTheme.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help(controller.pinToNotch ? "Switch to floating resizable window" : "Pin to MacBook notch")

                Spacer()

                if controller.isPlaying && controller.scrollMode != .timed {
                    TeleprompterMiniWaveform(
                        levels: controller.audioLevels,
                        active: controller.voiceStatus == .speaking || controller.scrollMode == .followScript
                    )
                }

                if controller.elapsedSeconds > 0 || controller.isPlaying {
                    Text(elapsedLabel)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(RaycastTheme.textSecondary)
                }

                Text(statusText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(RaycastTheme.textTertiary)

                Button {
                    controller.hide()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(RaycastTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }

            if case let .unavailable(message) = controller.voiceStatus {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            // Script scrolling stage or editor
            if controller.isEditingScript {
                TextEditor(text: $controller.scriptText)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.black.opacity(0.45))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(RaycastTheme.borderSubtle, lineWidth: 1)
                            )
                    )
            } else {
                ZStack {
                    TeleprompterScriptView(
                        layout: controller.scriptLayout,
                        script: controller.scriptText,
                        fontSize: controller.fontSize,
                        progress: controller.scrollProgress,
                        anchor: controller.scriptAnchor,
                        readUpTo: controller.readCharacterOffset,
                        nextSpokenWord: controller.nextSpokenWord,
                        allowBackwardTransition: controller.allowBackwardVisualTransition,
                        onTapCharacter: { charIndex in
                            controller.jump(toCharacter: charIndex)
                        },
                        onManualScroll: { newProgress in
                            controller.scrub(toProgress: newProgress)
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                    // Eye-line reading focal band
                    VStack {
                        Spacer().frame(height: 22)
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(RaycastTheme.accent.opacity(0.11))
                            .frame(height: controller.fontSize + 14)
                            .overlay(alignment: .leading) {
                                Rectangle()
                                    .fill(RaycastTheme.accent)
                                    .frame(width: 2.5)
                                    .padding(.vertical, 4)
                            }
                            .allowsHitTesting(false)
                        Spacer()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(controller.pinToNotch ? 0.25 : 0.38))
                )
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .white, location: 0.14),
                            .init(color: .white, location: 0.84),
                            .init(color: .clear, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }

            // Bottom transport controls
            HStack(spacing: 8) {
                Button {
                    if controller.isPlaying {
                        controller.pause()
                    } else {
                        controller.play()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        Text(controller.isPlaying ? "Pause" : "Scroll")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(controller.isPlaying ? Color.orange : RaycastTheme.accent)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    controller.reset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(RaycastTheme.textPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.white.opacity(0.10))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Reset to Top")

                Button(action: controller.rewind) {
                    Image(systemName: "chevron.up.2")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(RaycastTheme.textPrimary)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .disabled(controller.isEditingScript || (controller.scrollProgress == 0 && controller.scriptAnchor == nil))
                .accessibilityLabel("Back Two Lines")
                .help("Back two lines and pause")

                Menu {
                    ForEach(TeleprompterController.ScrollMode.allCases, id: \.self) { mode in
                        Button {
                            controller.selectScrollMode(mode)
                        } label: {
                            if controller.scrollMode == mode {
                                Label(mode.rawValue, systemImage: "checkmark")
                            } else {
                                Text(mode.rawValue)
                            }
                        }
                    }
                } label: {
                    Text(controller.scrollMode.rawValue)
                        .font(.system(size: 10, weight: .semibold))
                }
                .fixedSize()
                .accessibilityLabel("Scroll mode")
                .accessibilityValue(controller.scrollMode.rawValue)

                HStack(spacing: 4) {
                    Slider(value: $controller.wordsPerMinute, in: 60...260, step: 10)
                        .frame(width: 70)
                        .accessibilityLabel("Words per minute")
                        .help(controller.scrollMode == .followScript
                              ? "Stage direction speed"
                              : "\(Int(controller.wordsPerMinute)) words per minute")
                }

                HStack(spacing: 4) {
                    Button {
                        controller.fontSize = max(14, controller.fontSize - 2)
                    } label: {
                        Text("A-")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(RaycastTheme.textPrimary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.10)))
                    }
                    .buttonStyle(.plain)

                    Button {
                        controller.fontSize = min(38, controller.fontSize + 2)
                    } label: {
                        Text("A+")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(RaycastTheme.textPrimary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.10)))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Button {
                    controller.isEditingScript.toggle()
                    if controller.isEditingScript {
                        controller.pause()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: controller.isEditingScript ? "checkmark" : "square.and.pencil")
                        Text(controller.isEditingScript ? "Done" : "Edit")
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(RaycastTheme.textPrimary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(0.10))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, controller.pinToNotch ? 24 : 12)
        .padding(.vertical, 12)
        .background {
            if controller.pinToNotch {
                TeleprompterNotchShape()
                    .fill(Color.black.opacity(0.95))
            }
        }
        .modifier(TeleprompterSurfaceModifier(isNotch: controller.pinToNotch))
        .preferredColorScheme(.dark)
    }
}

private struct TeleprompterSurfaceModifier: ViewModifier {
    let isNotch: Bool
    func body(content: Content) -> some View {
        if isNotch {
            content
        } else {
            content.raycastLiquidGlass(cornerRadius: 16, tintAlpha: 0.86)
        }
    }
}

// MARK: - Floating Picture-in-Picture Camera Bubble

public enum CameraBubbleShape: String, Codable, CaseIterable, Sendable {
    case circle
    case squircle
    case portrait

    var label: String {
        switch self {
        case .circle: return "Circle"
        case .squircle: return "Rounded Square"
        case .portrait: return "Portrait (9:16)"
        }
    }

    var symbol: String {
        switch self {
        case .circle: return "circle"
        case .squircle: return "square"
        case .portrait: return "rectangle.portrait"
        }
    }

    func panelSize(width: CGFloat) -> CGSize {
        CGSize(width: width, height: self == .portrait ? width * 16 / 9 : width)
    }

    func cornerRadius(width: CGFloat) -> CGFloat {
        switch self {
        case .circle: return width / 2
        case .squircle: return 28
        case .portrait: return 14
        }
    }
}

public enum CameraBubbleSize: String, Codable, CaseIterable, Sendable {
    case small
    case medium
    case large

    public var dimension: CGFloat {
        switch self {
        case .small: return 130
        case .medium: return 180
        case .large: return 240
        }
    }

    public var label: String {
        switch self {
        case .small: return "S"
        case .medium: return "M"
        case .large: return "L"
        }
    }
}

public enum CameraDisplayStyle: String, Codable, CaseIterable, Sendable {
    case floatingBubble
    case fullFrameMonitor
}

struct ActiveCameraRecordingFeed {
    let dimensions: CGSize
    let frameRate: Double
    let synchronizationClock: CMClock
    let includesMicrophone: Bool
    let resolutionBadge: String
}

public final class CameraBubbleController: ObservableObject, @unchecked Sendable {
    public static let shared = CameraBubbleController(settings: .shared)

    @Published public var isVisible: Bool = false
    @Published public var shape: CameraBubbleShape {
        didSet {
            settings?.recordingCameraShape = shape
            updatePanelSize()
        }
    }
    @Published public var bubbleSize: CameraBubbleSize = .medium {
        didSet { updatePanelSize() }
    }
    @Published public var isMirrored: Bool = true
    @Published public var displayStyle: CameraDisplayStyle = .floatingBubble {
        didSet {
            guard oldValue != displayStyle else { return }
            if isVisible {
                show()
            }
        }
    }
    @Published public var hideFromScreenCapture: Bool = false {
        didSet {
            panel?.sharingType = hideFromScreenCapture ? .none : .readOnly
        }
    }
    @Published public var preferMaxResolution: Bool = false {
        didSet {
            guard oldValue != preferMaxResolution else { return }
            if isVisible {
                reloadSelectedCamera()
            }
        }
    }
    @Published public private(set) var cameraAuthorized: Bool = false
    @Published public private(set) var hasLiveCameraFeed: Bool = false
    @Published private(set) var cameraError: String?
    @Published public private(set) var activeFormatBadge: String?
    @Published public private(set) var activeFormatDimensions: CGSize?

    public var windowNumber: Int? {
        panel?.windowNumber
    }

    private let settings: SettingsStore?
    private var panel: NSPanel?
    private var fullFrameWindow: NSWindow?
    var panelSize: CGSize { shape.panelSize(width: bubbleSize.dimension) }
    // The main queue owns the preview reference and request token. The session
    // queue owns starting and stopping the capture session.
    private var previewSession: AVCaptureSession?
    private var captureSession: AVCaptureSession?
    private var captureDeviceID: String?
    private var captureConfiguredMaxRes: Bool = false
    private var captureConfiguredAspectRatio: CameraAspectRatioPreference?
    private var captureActiveFormat: SelectedCameraFormat?
    private var recordingVideoOutput: AVCaptureVideoDataOutput?
    private var recordingAudioOutput: AVCaptureAudioDataOutput?
    private var recordingAudioInput: AVCaptureDeviceInput?
    private var recordingDelegate: CameraRecordingTapDelegate?
    private var onRecordingRuntimeError: ((String) -> Void)?
    private var cameraRequest = UUID()
    private var disconnectObserver: NSObjectProtocol?
    private var runtimeErrorObserver: NSObjectProtocol?
    private let sessionQueue = DispatchQueue(label: "com.catchapp.camerabubble")
    private let sampleDeliveryQueue = DispatchQueue(label: "com.catchapp.camera.samples", qos: .userInitiated)

    public convenience init() {
        self.init(settings: nil)
    }

    private init(settings: SettingsStore?) {
        self.settings = settings
        self.shape = settings?.recordingCameraShape ?? .circle
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let device = notification.object as? AVCaptureDevice else { return }
            let isActiveDevice = self.previewSession?.inputs.contains(where: { ($0 as? AVCaptureDeviceInput)?.device.uniqueID == device.uniqueID }) == true
            if isActiveDevice {
                let message = "\(device.localizedName) disconnected. Choose a camera in Studio."
                self.sessionQueue.async {
                    let callback = self.onRecordingRuntimeError
                    self.onRecordingRuntimeError = nil
                    if let callback {
                        callback(message)
                    }
                }
                if self.isVisible {
                    self.stopCamera(force: false)
                    self.cameraError = message
                }
            }
        }
        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self,
                  let session = notification.object as? AVCaptureSession else { return }
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            let message = "Camera capture stopped unexpectedly: \(error?.localizedDescription ?? "Unknown camera error")."
            self.sessionQueue.async {
                guard session === self.captureSession, let callback = self.onRecordingRuntimeError else { return }
                self.onRecordingRuntimeError = nil
                callback(message)
            }
        }
    }

    deinit {
        if let disconnectObserver { NotificationCenter.default.removeObserver(disconnectObserver) }
        if let runtimeErrorObserver { NotificationCenter.default.removeObserver(runtimeErrorObserver) }
    }

    public func show(on screen: NSScreen? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isVisible = true
            let targetScreen = screen ?? CaptureEngine.shared.resolveScreen(displayIndex: nil)

            switch self.displayStyle {
            case .floatingBubble:
                self.fullFrameWindow?.orderOut(nil)
                self.fullFrameWindow = nil
                if let existing = self.panel {
                    existing.sharingType = self.hideFromScreenCapture ? .none : .readOnly
                    self.updatePanelSize()
                    existing.orderFrontRegardless()
                    self.startCameraIfAuthorized()
                    return
                }

                let size = self.panelSize
                let origin = CGPoint(
                    x: targetScreen.visibleFrame.minX + 24,
                    y: targetScreen.visibleFrame.minY + 24
                )
                let panel = NSPanel(
                    contentRect: CGRect(origin: origin, size: size),
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered,
                    defer: false
                )
                panel.level = .floating
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                panel.isMovableByWindowBackground = true
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = true
                panel.sharingType = self.hideFromScreenCapture ? .none : .readOnly

                let hosting = NSHostingView(rootView: CameraBubbleView(controller: self))
                hosting.sizingOptions = []
                hosting.frame = CGRect(origin: .zero, size: size)
                panel.contentView = hosting
                panel.invalidateShadow()
                panel.orderFrontRegardless()
                self.panel = panel
                self.startCameraIfAuthorized()

            case .fullFrameMonitor:
                self.panel?.orderOut(nil)
                self.panel = nil
                if let existing = self.fullFrameWindow {
                    existing.makeKeyAndOrderFront(nil)
                    self.startCameraIfAuthorized()
                    return
                }

                let visible = targetScreen.visibleFrame
                let width = min(visible.width * 0.72, 1120)
                let height = min(visible.height * 0.68, width * 9.0 / 16.0)
                let rect = CGRect(
                    x: visible.midX - width / 2,
                    y: visible.midY - height / 2 + 24,
                    width: width,
                    height: height
                )
                let window = NSWindow(
                    contentRect: rect,
                    styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                    backing: .buffered,
                    defer: false
                )
                window.title = "Catch Camera Studio"
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.isReleasedWhenClosed = false
                window.backgroundColor = .black
                window.collectionBehavior = [.fullScreenPrimary]
                window.minSize = CGSize(width: 480, height: 300)
                window.contentView = NSHostingView(rootView: FullFrameCameraMonitorView(controller: self))
                window.makeKeyAndOrderFront(nil)
                self.fullFrameWindow = window
                self.startCameraIfAuthorized()
            }
        }
    }

    public func hide() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isVisible = false
            self.stopCamera(force: false)
            self.panel?.orderOut(nil)
            self.panel = nil
            self.fullFrameWindow?.orderOut(nil)
            self.fullFrameWindow = nil
        }
    }

    public func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    public func cycleSize() {
        switch bubbleSize {
        case .small: bubbleSize = .medium
        case .medium: bubbleSize = .large
        case .large: bubbleSize = .small
        }
    }

    public func toggleShape() {
        shape = nextShape
    }

    fileprivate var nextShape: CameraBubbleShape {
        switch shape {
        case .circle: return .squircle
        case .squircle: return .portrait
        case .portrait: return .circle
        }
    }

    private func updatePanelSize() {
        guard let panel else { return }
        let size = panelSize
        var origin = panel.frame.origin
        if let visibleFrame = panel.screen?.visibleFrame {
            origin.x = max(visibleFrame.minX, min(origin.x, visibleFrame.maxX - size.width))
            origin.y = max(visibleFrame.minY, min(origin.y, visibleFrame.maxY - size.height))
        }
        let updated = CGRect(origin: origin, size: size)
        panel.setFrame(updated, display: true, animate: true)
        panel.contentView?.frame = CGRect(origin: .zero, size: size)
        panel.invalidateShadow()
    }

    private func startCameraIfAuthorized() {
        let request = UUID()
        cameraRequest = request
        cameraError = nil
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            cameraAuthorized = true
            configureSession(request: request)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.cameraRequest == request, self.isVisible else { return }
                    self.cameraAuthorized = granted
                    if granted {
                        self.configureSession(request: request)
                    } else {
                        self.cameraError = "Allow Camera access in System Settings."
                    }
                }
            }
        default:
            cameraAuthorized = false
            hasLiveCameraFeed = false
            cameraError = "Allow Camera access in System Settings."
        }
    }

    func reloadSelectedCamera() {
        guard isVisible else { return }
        startCameraIfAuthorized()
    }

    private func configureSession(request: UUID) {
        let activeSettings = settings ?? .shared
        let selectedID = activeSettings.recordingCameraID
        let wantsMaxRes = preferMaxResolution
        let preferredFPS = Double(activeSettings.recordingFrameRate)
        let preferredAspectRatio = activeSettings.recordingCameraAspectRatio
        hasLiveCameraFeed = false
        previewSession = nil
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                guard let device = StudioCaptureDevices.resolve(selectedID, mediaType: .video) else {
                    if self.recordingVideoOutput == nil {
                        self.captureSession?.stopRunning()
                        self.captureSession = nil
                    }
                    throw CameraStartError.unavailable
                }
                if let existing = self.captureSession,
                   self.captureDeviceID == device.uniqueID,
                   self.captureConfiguredMaxRes == wantsMaxRes,
                   (!wantsMaxRes || self.captureConfiguredAspectRatio == preferredAspectRatio),
                   existing.isRunning {
                    self.publishCamera(existing, format: self.captureActiveFormat, error: nil, request: request)
                    return
                }
                guard self.recordingVideoOutput == nil else {
                    if let existing = self.captureSession, existing.isRunning {
                        self.publishCamera(existing, format: self.captureActiveFormat, error: nil, request: request)
                    }
                    return
                }
                self.captureSession?.stopRunning()
                self.captureSession = nil
                let input = try AVCaptureDeviceInput(device: device)
                let session = AVCaptureSession()
                guard session.canAddInput(input) else { throw CameraStartError.unavailable }
                session.addInput(input)

                var chosenFormat: SelectedCameraFormat?
                if wantsMaxRes {
                    // On macOS, configure activeFormat after adding the device input without setting a downscaling preset.
                    chosenFormat = CameraFormatSelector.configureMaxResolution(
                        for: device,
                        preferredFrameRate: preferredFPS,
                        aspectRatio: preferredAspectRatio
                    )
                } else {
                    if session.canSetSessionPreset(.medium) {
                        session.sessionPreset = .medium
                    }
                }

                session.startRunning()
                guard session.isRunning else { throw CameraStartError.unavailable }
                self.captureSession = session
                self.captureDeviceID = device.uniqueID
                self.captureConfiguredMaxRes = wantsMaxRes
                self.captureConfiguredAspectRatio = wantsMaxRes ? preferredAspectRatio : nil
                self.captureActiveFormat = chosenFormat
                self.publishCamera(session, format: chosenFormat, error: nil, request: request)
            } catch {
                self.publishCamera(nil, format: nil, error: "Camera could not start: \(error.localizedDescription)", request: request)
            }
        }
    }

    /// Starts (or attaches to) the shared high-resolution camera capture session for recording.
    /// When `microphoneID` is non-nil (Camera-Only Podcast mode), the microphone is added to the
    /// exact same `AVCaptureSession`. Both video and audio callbacks receive the session's live
    /// `synchronizationClock` and the connection's input port clock so timestamps can always be
    /// converted cleanly onto `CMClockGetHostTimeClock()`.
    func startRecordingCapture(
        deviceID: String?,
        microphoneID: String?,
        preferredFPS: Double,
        aspectRatio: CameraAspectRatioPreference = SettingsStore.shared.recordingCameraAspectRatio,
        onVideoSample: @escaping (CMSampleBuffer, CMClock?, CMClock?) -> Void,
        onAudioSample: @escaping (CMSampleBuffer, CMClock?, CMClock?) -> Void,
        onRuntimeError: @escaping (String) -> Void
    ) async -> Result<ActiveCameraRecordingFeed, Error> {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .failure(CameraStartError.unavailable))
                    return
                }
                do {
                    guard let device = StudioCaptureDevices.resolve(deviceID, mediaType: .video) else {
                        throw CameraStartError.unavailable
                    }
                    var micDevice: AVCaptureDevice?
                    if let microphoneID {
                        guard let resolvedMic = StudioCaptureDevices.resolve(microphoneID, mediaType: .audio) else {
                            throw CameraStartError.microphoneUnavailable
                        }
                        micDevice = resolvedMic
                    }

                    // Clean up any stale recording outputs before attaching new ones.
                    self.detachRecordingOutputsLocked()

                    let canReuseSession = (self.captureSession != nil
                        && self.captureSession?.isRunning == true
                        && self.captureDeviceID == device.uniqueID
                        && self.captureConfiguredMaxRes == true
                        && self.captureConfiguredAspectRatio == aspectRatio
                        && micDevice == nil)

                    let session: AVCaptureSession
                    var chosenFormat: SelectedCameraFormat?
                    if canReuseSession, let existing = self.captureSession {
                        session = existing
                        chosenFormat = self.captureActiveFormat
                    } else {
                        self.captureSession?.stopRunning()
                        self.captureSession = nil
                        let created = AVCaptureSession()
                        let videoInput = try AVCaptureDeviceInput(device: device)
                        guard created.canAddInput(videoInput) else { throw CameraStartError.unavailable }
                        created.addInput(videoInput)
                        chosenFormat = CameraFormatSelector.configureMaxResolution(
                            for: device,
                            preferredFrameRate: preferredFPS,
                            aspectRatio: aspectRatio
                        )
                        session = created
                        self.captureSession = created
                        self.captureDeviceID = device.uniqueID
                        self.captureConfiguredMaxRes = true
                        self.captureConfiguredAspectRatio = aspectRatio
                        self.captureActiveFormat = chosenFormat
                    }

                    let syncClock = session.synchronizationClock ?? CMClockGetHostTimeClock()
                    let delegate = CameraRecordingTapDelegate(
                        session: session,
                        synchronizationClock: syncClock,
                        onVideo: onVideoSample,
                        onAudio: onAudioSample
                    )

                    let videoOutput = AVCaptureVideoDataOutput()
                    videoOutput.alwaysDiscardsLateVideoFrames = true
                    videoOutput.setSampleBufferDelegate(delegate, queue: self.sampleDeliveryQueue)

                    session.beginConfiguration()
                    var addedMicInput: AVCaptureDeviceInput?
                    var addedAudioOutput: AVCaptureAudioDataOutput?

                    guard session.canAddOutput(videoOutput) else {
                        session.commitConfiguration()
                        throw CameraStartError.outputFailed
                    }
                    session.addOutput(videoOutput)
                    if let connection = videoOutput.connection(with: .video), connection.isVideoMirroringSupported {
                        connection.automaticallyAdjustsVideoMirroring = false
                        // Always record unmirrored frames so text/background looks natural for editors.
                        connection.isVideoMirrored = false
                    }

                    if let micDevice {
                        let audioInput = try AVCaptureDeviceInput(device: micDevice)
                        let audioOutput = AVCaptureAudioDataOutput()
                        audioOutput.setSampleBufferDelegate(delegate, queue: self.sampleDeliveryQueue)
                        guard session.canAddInput(audioInput), session.canAddOutput(audioOutput) else {
                            session.removeOutput(videoOutput)
                            session.commitConfiguration()
                            throw CameraStartError.microphoneUnavailable
                        }
                        session.addInput(audioInput)
                        session.addOutput(audioOutput)
                        addedMicInput = audioInput
                        addedAudioOutput = audioOutput
                    }
                    session.commitConfiguration()

                    if let refreshedFormat = CameraFormatSelector.configureMaxResolution(
                        for: device,
                        preferredFrameRate: preferredFPS,
                        aspectRatio: aspectRatio
                    ) {
                        chosenFormat = refreshedFormat
                        self.captureActiveFormat = refreshedFormat
                        self.captureConfiguredAspectRatio = aspectRatio
                    }

                    if !session.isRunning {
                        session.startRunning()
                    }
                    guard session.isRunning else {
                        self.detachRecordingOutputsLocked()
                        throw CameraStartError.unavailable
                    }

                    // Re-read the active format dimensions directly from the device in case fallback applied.
                    let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                    let width = max(320, (Int(dims.width) / 2) * 2)
                    let height = max(240, (Int(dims.height) / 2) * 2)
                    let resolvedFPS = chosenFormat?.targetFrameRate ?? min(30.0, preferredFPS)
                    let badge = chosenFormat?.badgeText ?? "\(width)×\(height) · \(Int(resolvedFPS.rounded()))fps"

                    self.recordingVideoOutput = videoOutput
                    self.recordingAudioOutput = addedAudioOutput
                    self.recordingAudioInput = addedMicInput
                    self.recordingDelegate = delegate
                    self.onRecordingRuntimeError = onRuntimeError

                    let activeClock = session.synchronizationClock ?? syncClock
                    delegate.synchronizationClock = activeClock

                    DispatchQueue.main.async {
                        if self.isVisible {
                            self.previewSession = session
                            self.hasLiveCameraFeed = true
                            self.cameraError = nil
                        }
                        self.activeFormatBadge = badge
                        self.activeFormatDimensions = CGSize(width: width, height: height)
                    }

                    let feed = ActiveCameraRecordingFeed(
                        dimensions: CGSize(width: width, height: height),
                        frameRate: resolvedFPS,
                        synchronizationClock: activeClock,
                        includesMicrophone: addedAudioOutput != nil,
                        resolutionBadge: badge
                    )
                    continuation.resume(returning: .success(feed))
                } catch {
                    self.detachRecordingOutputsLocked()
                    continuation.resume(returning: .failure(error))
                }
            }
        }
    }

    func stopRecordingCapture() {
        let keepPreviewVisible = isVisible
        sessionQueue.sync {
            self.onRecordingRuntimeError = nil
            self.detachRecordingOutputsLocked()
            if !keepPreviewVisible {
                self.captureSession?.stopRunning()
                self.captureSession = nil
                self.captureDeviceID = nil
                self.captureActiveFormat = nil
                self.captureConfiguredMaxRes = false
                self.captureConfiguredAspectRatio = nil
            }
        }
    }

    private func detachRecordingOutputsLocked() {
        guard let session = captureSession else {
            recordingVideoOutput = nil
            recordingAudioOutput = nil
            recordingAudioInput = nil
            recordingDelegate = nil
            return
        }
        let hasAttachments = recordingVideoOutput != nil || recordingAudioOutput != nil || recordingAudioInput != nil
        if hasAttachments {
            session.beginConfiguration()
            if let videoOut = recordingVideoOutput {
                videoOut.setSampleBufferDelegate(nil, queue: nil)
                session.removeOutput(videoOut)
            }
            if let audioOut = recordingAudioOutput {
                audioOut.setSampleBufferDelegate(nil, queue: nil)
                session.removeOutput(audioOut)
            }
            if let audioIn = recordingAudioInput {
                session.removeInput(audioIn)
            }
            session.commitConfiguration()
        }
        recordingVideoOutput = nil
        recordingAudioOutput = nil
        recordingAudioInput = nil
        recordingDelegate = nil
    }

    private enum CameraStartError: LocalizedError {
        case unavailable
        case microphoneUnavailable
        case outputFailed
        var errorDescription: String? {
            switch self {
            case .unavailable: return "The selected camera is unavailable."
            case .microphoneUnavailable: return "The selected microphone is unavailable."
            case .outputFailed: return "Catch could not attach a high-resolution video recorder to this camera."
            }
        }
    }

    private func publishCamera(_ session: AVCaptureSession?, format: SelectedCameraFormat?, error: String?, request: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.cameraRequest == request, self.isVisible else { return }
            self.previewSession = session
            self.hasLiveCameraFeed = session != nil
            self.cameraError = error
            if let format {
                self.activeFormatBadge = format.badgeText
                self.activeFormatDimensions = CGSize(width: format.encodedWidth, height: format.encodedHeight)
            } else if session == nil || !self.preferMaxResolution {
                self.activeFormatBadge = nil
                self.activeFormatDimensions = nil
            }
        }
    }

    private func stopCamera(force: Bool = true) {
        cameraRequest = UUID()
        previewSession = nil
        hasLiveCameraFeed = false
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !force && self.recordingVideoOutput != nil { return }
            self.detachRecordingOutputsLocked()
            self.captureSession?.stopRunning()
            self.captureSession = nil
            self.captureDeviceID = nil
            self.captureActiveFormat = nil
            self.captureConfiguredMaxRes = false
            self.captureConfiguredAspectRatio = nil
        }
    }

    fileprivate var activeSession: AVCaptureSession? {
        previewSession
    }
}

private final class CameraRecordingTapDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    weak var session: AVCaptureSession?
    var synchronizationClock: CMClock
    private let onVideo: (CMSampleBuffer, CMClock?, CMClock?) -> Void
    private let onAudio: (CMSampleBuffer, CMClock?, CMClock?) -> Void

    init(
        session: AVCaptureSession,
        synchronizationClock: CMClock,
        onVideo: @escaping (CMSampleBuffer, CMClock?, CMClock?) -> Void,
        onAudio: @escaping (CMSampleBuffer, CMClock?, CMClock?) -> Void
    ) {
        self.session = session
        self.synchronizationClock = synchronizationClock
        self.onVideo = onVideo
        self.onAudio = onAudio
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let liveSessionClock = session?.synchronizationClock ?? synchronizationClock
        let portClock = connection.inputPorts.first?.clock
        if output is AVCaptureVideoDataOutput {
            onVideo(sampleBuffer, liveSessionClock, portClock)
        } else if output is AVCaptureAudioDataOutput {
            onAudio(sampleBuffer, liveSessionClock, portClock)
        }
    }
}

private struct CameraBubbleView: View {
    @ObservedObject var controller: CameraBubbleController
    @State private var isHovered = false

    var body: some View {
        let size = controller.panelSize
        let radius = controller.shape.cornerRadius(width: size.width)

        ZStack {
            if controller.hasLiveCameraFeed, let session = controller.activeSession {
                CameraPreviewLayerView(
                    session: session,
                    isMirrored: controller.isMirrored,
                    cornerRadius: radius,
                    videoGravity: .resizeAspectFill
                )
            } else {
                ZStack {
                    LinearGradient(
                        colors: [Color(red: 0.13, green: 0.16, blue: 0.24), Color(red: 0.08, green: 0.10, blue: 0.15)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    VStack(spacing: 6) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: size.width * 0.34))
                            .foregroundStyle(RaycastTheme.textPrimary.opacity(0.85))
                        Text(controller.cameraError ?? (controller.cameraAuthorized ? "Starting camera…" : "Camera Ready"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(RaycastTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 10)
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(RaycastTheme.specularGradient, lineWidth: 2)
        )
        .overlay(alignment: .top) {
            if controller.hideFromScreenCapture {
                HStack(spacing: 4) {
                    Image(systemName: "eye.slash.fill")
                        .font(.system(size: 8.5, weight: .bold))
                    Text("ISO · Hidden")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.black.opacity(0.72)))
                .padding(.top, 8)
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if isHovered {
                HStack(spacing: 6) {
                    Button {
                        controller.cycleSize()
                    } label: {
                        Text(controller.bubbleSize.label)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.18)))
                    }
                    .buttonStyle(.plain)

                    Button {
                        controller.toggleShape()
                    } label: {
                        Image(systemName: controller.nextShape.symbol)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(Circle().fill(Color.white.opacity(0.18)))
                    }
                    .buttonStyle(.plain)
                    .help("Use \(controller.nextShape.label) camera frame")
                    .accessibilityLabel("Use \(controller.nextShape.label) camera frame")

                    Button {
                        controller.isMirrored.toggle()
                    } label: {
                        Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(Circle().fill(Color.white.opacity(0.18)))
                    }
                    .buttonStyle(.plain)

                    Button {
                        controller.hide()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(Circle().fill(Color.white.opacity(0.18)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.75))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.75))
                )
                .padding(.bottom, 10)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct FullFrameCameraMonitorView: View {
    @ObservedObject var controller: CameraBubbleController
    @ObservedObject private var studio = ScreenRecordingStudio.shared

    var body: some View {
        ZStack {
            Color.black
            if controller.hasLiveCameraFeed, let session = controller.activeSession {
                CameraPreviewLayerView(
                    session: session,
                    isMirrored: controller.isMirrored,
                    cornerRadius: 0,
                    videoGravity: .resizeAspect
                )
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "video.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(RaycastTheme.textSecondary)
                    Text(controller.cameraError ?? (controller.cameraAuthorized ? "Starting full-resolution camera…" : "Camera Ready"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(RaycastTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 8) {
                if studio.state.isActive {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 7, height: 7)
                        Text("REC")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.red.opacity(0.32)))
                }

                HStack(spacing: 5) {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 10, weight: .semibold))
                    Text((controller.activeFormatBadge ?? "Max Resolution") + " · HEVC")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.65)))
            }
            .padding(.leading, 76)
            .padding(.top, 10)
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                Button {
                    studio.cameraAspectRatio = studio.cameraAspectRatio == .widescreen16x9
                        ? .fullSensor
                        : .widescreen16x9
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "aspectratio")
                            .font(.system(size: 10, weight: .semibold))
                        Text(studio.cameraAspectRatio.label)
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(studio.state == .idle ? 0.9 : 0.45))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.65)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(studio.state != .idle)
                .help("Toggle camera aspect ratio between 16:9 Widescreen (1080p / 4K) and Full Sensor (Max / 4:3)")

                Button {
                    controller.isMirrored.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                            .font(.system(size: 10, weight: .semibold))
                        Text(controller.isMirrored ? "Preview Mirrored" : "Preview Unmirrored")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.65)))
                }
                .buttonStyle(.plain)
                .help("Toggle preview mirroring (recording is always saved unmirrored for editors)")
            }
            .padding(.trailing, 14)
            .padding(.top, 10)
        }
        .preferredColorScheme(.dark)
    }
}

private struct CameraPreviewLayerView: NSViewRepresentable {
    let session: AVCaptureSession
    let isMirrored: Bool
    let cornerRadius: CGFloat
    var videoGravity: AVLayerVideoGravity = .resizeAspectFill

    func makeNSView(context: Context) -> CameraPreviewNSView {
        let view = CameraPreviewNSView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = videoGravity
        view.updateMirroring(isMirrored)
        view.updateCornerRadius(cornerRadius)
        return view
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        if nsView.previewLayer.session !== session {
            nsView.previewLayer.session = session
        }
        if nsView.previewLayer.videoGravity != videoGravity {
            nsView.previewLayer.videoGravity = videoGravity
        }
        nsView.updateMirroring(isMirrored)
        nsView.updateCornerRadius(cornerRadius)
    }
}

private final class CameraPreviewNSView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        previewLayer.masksToBounds = true
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }

    func updateMirroring(_ mirrored: Bool) {
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
    }

    func updateCornerRadius(_ radius: CGFloat) {
        layer?.cornerRadius = radius
        layer?.masksToBounds = true
        previewLayer.cornerRadius = radius
        previewLayer.masksToBounds = true
    }
}

// MARK: - Loom Screen + Audio + MP4 Recorder Studio

public enum RecordingAreaMode: String, Codable, CaseIterable, Sendable {
    case fullscreen
    case area
    case cameraOnly
}

public struct TakeOutputPlan: Equatable, Sendable {
    public let baseName: String
    public let takeDirectoryURL: URL?
    public let primaryVideoURL: URL
    public let screenVideoURL: URL?
    public let cameraVideoURL: URL?
    public let microphoneStemURL: URL?
    public let systemAudioStemURL: URL?

    public var recordsScreen: Bool { screenVideoURL != nil }
    public var recordsCamera: Bool { cameraVideoURL != nil }
}

public final class ScreenRecordingStudio: NSObject, ObservableObject, @unchecked Sendable {
    public static let shared = ScreenRecordingStudio()
    fileprivate static let screenRecordingPermissionError =
        "Allow this copy of Catch in Screen & System Audio Recording, then quit and reopen it before trying again."

    public enum StudioState: Equatable, Sendable {
        case idle
        case preparing
        case recording(startedAt: Date)
        case paused(elapsed: TimeInterval)
        case finishing

        public var isActive: Bool {
            switch self {
            case .recording, .paused: return true
            default: return false
            }
        }
    }

    @Published public private(set) var state: StudioState = .idle
    @Published public var captureMode: RecordingAreaMode = .fullscreen {
        didSet {
            guard oldValue != captureMode else { return }
            syncCameraPresenterState()
        }
    }
    @Published public var selectedRect: CGRect?
    @Published public var includeMicrophone: Bool = true
    @Published public var includeSystemAudio: Bool {
        didSet {
            guard !isSyncingSystemAudio else { return }
            if settings.recordingRecordSystemAudio != includeSystemAudio {
                isSyncingSystemAudio = true
                settings.recordingRecordSystemAudio = includeSystemAudio
                isSyncingSystemAudio = false
            }
        }
    }
    @Published public var cameraRecordingMode: CameraRecordingMode {
        didSet {
            guard !isSyncingCameraMode else { return }
            if settings.recordingCameraMode != cameraRecordingMode {
                isSyncingCameraMode = true
                settings.recordingCameraMode = cameraRecordingMode
                isSyncingCameraMode = false
            }
            syncCameraPresenterState()
        }
    }
    @Published public var cameraAspectRatio: CameraAspectRatioPreference {
        didSet {
            guard !isSyncingCameraAspectRatio else { return }
            let changed = oldValue != cameraAspectRatio
            if settings.recordingCameraAspectRatio != cameraAspectRatio {
                isSyncingCameraAspectRatio = true
                settings.recordingCameraAspectRatio = cameraAspectRatio
                isSyncingCameraAspectRatio = false
            }
            if changed {
                reloadCameraForAspectRatioChangeIfNeeded()
            }
        }
    }
    @Published public var exportAudioStems: Bool {
        didSet {
            guard !isSyncingAudioStems else { return }
            if settings.recordingExportAudioStems != exportAudioStems {
                isSyncingAudioStems = true
                settings.recordingExportAudioStems = exportAudioStems
                isSyncingAudioStems = false
            }
        }
    }
    @Published public var showCameraBubble: Bool = true
    @Published public var showTeleprompter: Bool = true
    @Published public private(set) var elapsedSeconds: Int = 0
    @Published public private(set) var lastRecordedVideoURL: URL?
    @Published public private(set) var lastRecordedBundle: RecordedTakeBundle?
    @Published public var recordingError: String?
    private let settings: SettingsStore
    private var cancellables: Set<AnyCancellable> = []
    private var isSyncingSystemAudio = false
    private var isSyncingCameraMode = false
    private var isSyncingCameraAspectRatio = false
    private var isSyncingAudioStems = false
    private var syntheticTake = false
    private var preparingStopCompletion: (@Sendable (URL?, CaptureHistoryItem?) -> Void)?

    private var controlBarPanel: NSPanel?
    private var elapsedTimer: Timer?
    private var accumulatedElapsed: TimeInterval = 0
    private var activeRecordingStart: Date?

    private let writerQueue = DispatchQueue(label: "com.catchapp.loom.writer")
    private var scStream: SCStream?
    private var streamOutput: RecordingStreamOutput?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var microphoneSamples = 0
    private var pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var cameraWriter: CameraTrackWriter?
    private var micStemWriter: AudioStemWriter?
    private var systemAudioStemWriter: AudioStemWriter?
    private var syncBarrier = DualTrackSyncBarrier(requiresScreen: true, requiresCamera: false)
    private var activeSessionClock: CMClock = CMClockGetHostTimeClock()
    private var cameraVideoClockNormalizer = StreamClockNormalizer()
    private var cameraAudioClockNormalizer = StreamClockNormalizer()
    private var activeTakePlan: TakeOutputPlan?
    private var activeOutputURL: URL?
    private var activeCameraResolution: String?
    private var activeCameraSessionRunning = false
    private var sessionStarted = false
    private var recordedDimensions: CGSize = CGSize(width: 1280, height: 720)
    private var frameCounter: Int64 = 0
    private var streamFailure: String?
    private var streamInterrupted = false
    private var cameraFailure: String?
    private var cameraInterrupted = false
    private var writerAcceptingSamples = false
    private var pausedAtClockTime: CMTime?
    private var removedPauseDuration: CMTime = .zero
    private var timestampGuard = MonotonicTimestampGuard()

    public convenience override init() {
        self.init(settings: .shared)
    }

    public init(settings: SettingsStore) {
        self.settings = settings
        self.includeSystemAudio = settings.recordingRecordSystemAudio
        self.cameraRecordingMode = settings.recordingCameraMode
        self.cameraAspectRatio = settings.recordingCameraAspectRatio
        self.exportAudioStems = settings.recordingExportAudioStems
        super.init()
        settings.$recordingRecordSystemAudio
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self, !self.isSyncingSystemAudio else { return }
                self.isSyncingSystemAudio = true
                if self.includeSystemAudio != enabled {
                    self.includeSystemAudio = enabled
                }
                self.isSyncingSystemAudio = false
            }
            .store(in: &cancellables)
        settings.$recordingCameraMode
            .dropFirst()
            .sink { [weak self] mode in
                guard let self, !self.isSyncingCameraMode else { return }
                self.isSyncingCameraMode = true
                if self.cameraRecordingMode != mode {
                    self.cameraRecordingMode = mode
                }
                self.isSyncingCameraMode = false
                self.syncCameraPresenterState()
            }
            .store(in: &cancellables)
        settings.$recordingCameraAspectRatio
            .dropFirst()
            .sink { [weak self] aspectRatio in
                guard let self, !self.isSyncingCameraAspectRatio else { return }
                let changed = self.cameraAspectRatio != aspectRatio
                self.isSyncingCameraAspectRatio = true
                if changed {
                    self.cameraAspectRatio = aspectRatio
                }
                self.isSyncingCameraAspectRatio = false
                if changed {
                    self.reloadCameraForAspectRatioChangeIfNeeded()
                }
            }
            .store(in: &cancellables)
        settings.$recordingExportAudioStems
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self, !self.isSyncingAudioStems else { return }
                self.isSyncingAudioStems = true
                if self.exportAudioStems != enabled {
                    self.exportAudioStems = enabled
                }
                self.isSyncingAudioStems = false
            }
            .store(in: &cancellables)
    }

    public static func makeTakeOutputPlan(
        rootDirectory: URL,
        baseName: String,
        captureMode: RecordingAreaMode,
        cameraRecordingMode: CameraRecordingMode,
        includeCamera: Bool,
        includeMicrophone: Bool,
        includeSystemAudio: Bool,
        exportAudioStems: Bool
    ) -> TakeOutputPlan {
        let recordsScreen = captureMode != .cameraOnly
        let recordsCamera = captureMode == .cameraOnly || (includeCamera && cameraRecordingMode == .separateFullResFile)
        let wantsMicStem = exportAudioStems && includeMicrophone
        let wantsSystemStem = exportAudioStems && recordsScreen && includeSystemAudio
        let needsTakeFolder = (recordsScreen && recordsCamera) || wantsMicStem || wantsSystemStem

        if needsTakeFolder {
            let folder = rootDirectory.appendingPathComponent(baseName, isDirectory: true)
            let screenURL = recordsScreen ? folder.appendingPathComponent("\(baseName)-screen.mp4") : nil
            let cameraURL = recordsCamera ? folder.appendingPathComponent("\(baseName)-camera.mp4") : nil
            let micStemURL = wantsMicStem ? folder.appendingPathComponent("\(baseName)-mic.wav") : nil
            let sysStemURL = wantsSystemStem ? folder.appendingPathComponent("\(baseName)-system-audio.wav") : nil
            let primary = screenURL ?? cameraURL ?? folder.appendingPathComponent("\(baseName).mp4")
            return TakeOutputPlan(
                baseName: baseName,
                takeDirectoryURL: folder,
                primaryVideoURL: primary,
                screenVideoURL: screenURL,
                cameraVideoURL: cameraURL,
                microphoneStemURL: micStemURL,
                systemAudioStemURL: sysStemURL
            )
        } else if recordsCamera {
            let cameraURL = rootDirectory.appendingPathComponent("\(baseName)-camera.mp4")
            return TakeOutputPlan(
                baseName: baseName,
                takeDirectoryURL: nil,
                primaryVideoURL: cameraURL,
                screenVideoURL: nil,
                cameraVideoURL: cameraURL,
                microphoneStemURL: nil,
                systemAudioStemURL: nil
            )
        } else {
            let screenURL = rootDirectory.appendingPathComponent("\(baseName).mp4")
            return TakeOutputPlan(
                baseName: baseName,
                takeDirectoryURL: nil,
                primaryVideoURL: screenURL,
                screenVideoURL: screenURL,
                cameraVideoURL: nil,
                microphoneStemURL: nil,
                systemAudioStemURL: nil
            )
        }
    }

    private func reloadCameraForAspectRatioChangeIfNeeded() {
        guard self === ScreenRecordingStudio.shared, state == .idle else { return }
        DispatchQueue.main.async {
            CameraBubbleController.shared.reloadSelectedCamera()
        }
    }

    private func syncCameraPresenterState() {
        guard self === ScreenRecordingStudio.shared, state == .idle else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let camera = CameraBubbleController.shared
            if self.captureMode == .cameraOnly {
                camera.hideFromScreenCapture = false
                camera.preferMaxResolution = true
                camera.displayStyle = .fullFrameMonitor
                if self.controlBarPanel != nil {
                    camera.show()
                }
            } else {
                let isISO = self.cameraRecordingMode == .separateFullResFile
                camera.hideFromScreenCapture = isISO
                camera.preferMaxResolution = isISO
                camera.displayStyle = .floatingBubble
                if self.controlBarPanel != nil {
                    if self.showCameraBubble {
                        camera.show()
                    } else {
                        camera.hide()
                    }
                }
            }
        }
    }

    public func presentStudio(
        initialRect: CGRect? = nil,
        displayIndex: Int? = nil,
        showPresenterOverlays: Bool = true,
        captureMode presetCaptureMode: RecordingAreaMode? = nil,
        cameraMode presetCameraMode: CameraRecordingMode? = nil,
        exportWAVStems: Bool? = nil
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.state == .idle {
                if let presetCaptureMode {
                    self.captureMode = presetCaptureMode
                }
                if let presetCameraMode {
                    self.cameraRecordingMode = presetCameraMode
                }
                if let exportWAVStems {
                    self.exportAudioStems = exportWAVStems
                }
                if presetCaptureMode == .cameraOnly {
                    self.showCameraBubble = true
                    self.showTeleprompter = true
                } else if presetCameraMode == .separateFullResFile {
                    self.showCameraBubble = true
                }
            }
            if let initialRect {
                self.captureMode = .area
                self.selectedRect = initialRect
            }
            let screen = CaptureEngine.shared.resolveScreen(displayIndex: displayIndex)

            if showPresenterOverlays {
                let camera = CameraBubbleController.shared
                if self.captureMode == .cameraOnly {
                    camera.hideFromScreenCapture = false
                    camera.preferMaxResolution = true
                    camera.displayStyle = .fullFrameMonitor
                    camera.show(on: screen)
                } else if self.showCameraBubble {
                    let isISO = self.cameraRecordingMode == .separateFullResFile
                    camera.hideFromScreenCapture = isISO
                    camera.preferMaxResolution = isISO
                    camera.displayStyle = .floatingBubble
                    if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
                        camera.show(on: screen)
                    } else if isISO {
                        // In Dual 4K ISO mode, request camera access via show() rather than silently turning off camera.
                        camera.show(on: screen)
                    } else {
                        self.showCameraBubble = false
                    }
                }
            }
            if showPresenterOverlays && self.showTeleprompter {
                TeleprompterController.shared.show(on: screen)
            }

            if let existing = self.controlBarPanel {
                existing.orderFrontRegardless()
                return
            }

            let width: CGFloat = min(920, max(760, screen.visibleFrame.width - 24))
            let height: CGFloat = 102
            let frame = CGRect(
                x: screen.frame.midX - width / 2,
                y: screen.visibleFrame.minY + 28,
                width: width,
                height: height
            )

            let panel = KeyableHUDPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isMovableByWindowBackground = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            // Control pill itself stays invisible to recorded viewers
            panel.sharingType = .none

            let hosting = NSHostingView(rootView: LoomStudioBarView(studio: self))
            panel.contentView = hosting
            panel.invalidateShadow()
            panel.orderFrontRegardless()
            self.controlBarPanel = panel
        }
    }

    public func dismissStudio() {
        StudioMicrophoneMeter.shared.stop()
        if state.isActive || state == .preparing {
            stopRecording()
        }
        DispatchQueue.main.async { [weak self] in
            self?.controlBarPanel?.orderOut(nil)
            self?.controlBarPanel = nil
            if self?.captureMode == .cameraOnly {
                CameraBubbleController.shared.hide()
            }
        }
    }

    public func selectRecordingArea() {
        let screen = CaptureEngine.shared.resolveScreen(displayIndex: nil)
        SelectionOverlayController.shared.beginAreaSelection(
            on: screen,
            frozenImage: nil,
            initialRect: selectedRect
        ) { [weak self] rect, _ in
            guard let self, let rect else { return }
            self.selectedRect = rect
            self.captureMode = .area
        }
    }

    public func startRecording(outputDirectory: URL? = nil, headlessSynthetic: Bool = false) {
        guard state == .idle else { return }
        StudioMicrophoneMeter.shared.stop()
        recordingError = nil
        lastRecordedVideoURL = nil
        lastRecordedBundle = nil

        let mode = captureMode
        let camMode = cameraRecordingMode
        let wantsCamera = showCameraBubble || mode == .cameraOnly
        let wantsMicrophone = includeMicrophone
        let wantsSystemAudio = mode != .cameraOnly && includeSystemAudio
        let wantsStems = exportAudioStems

        if !headlessSynthetic && mode != .cameraOnly && !CGPreflightScreenCaptureAccess() {
            recordingError = Self.screenRecordingPermissionError
            return
        }

        state = .preparing
        elapsedSeconds = 0
        accumulatedElapsed = 0
        syntheticTake = headlessSynthetic
        if !headlessSynthetic { LocalStudioBridge.shared.snapshotForTake() }

        let dir = outputDirectory ?? HistoryStore.shared.rootDirectory.appendingPathComponent("Recordings", isDirectory: true)
        let fileName = FileNameFormatter.format(pattern: SettingsStore.shared.fileNameFormat)
        let baseName = "\(fileName)-\(UUID().uuidString.prefix(6))"
        let plan: TakeOutputPlan
        if headlessSynthetic {
            let flatURL = dir.appendingPathComponent("\(baseName).mp4")
            plan = TakeOutputPlan(
                baseName: baseName,
                takeDirectoryURL: nil,
                primaryVideoURL: flatURL,
                screenVideoURL: flatURL,
                cameraVideoURL: nil,
                microphoneStemURL: nil,
                systemAudioStemURL: nil
            )
        } else {
            plan = Self.makeTakeOutputPlan(
                rootDirectory: dir,
                baseName: baseName,
                captureMode: mode,
                cameraRecordingMode: camMode,
                includeCamera: wantsCamera,
                includeMicrophone: wantsMicrophone,
                includeSystemAudio: wantsSystemAudio,
                exportAudioStems: wantsStems
            )
        }

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let takeDir = plan.takeDirectoryURL {
                try FileManager.default.createDirectory(at: takeDir, withIntermediateDirectories: true)
            }
        } catch {
            recordingError = "Could not create the recording folder: \(error.localizedDescription)"
            state = .idle
            return
        }

        let selectedMicrophoneID = SettingsStore.shared.recordingMicrophoneID
        let selectedCameraID = SettingsStore.shared.recordingCameraID
        let preferredFPS = Double(max(15, SettingsStore.shared.recordingFrameRate))

        Task {
            let started: Bool
            if headlessSynthetic {
                await prepareFallbackWriter(to: plan.primaryVideoURL)
                started = assetWriter != nil
            } else if mode == .cameraOnly {
                started = await startCameraOnlyRecording(
                    plan: plan,
                    cameraID: selectedCameraID,
                    wantsMicrophone: wantsMicrophone,
                    selectedMicrophoneID: selectedMicrophoneID,
                    preferredFPS: preferredFPS
                )
            } else {
                let microphoneID = wantsMicrophone ? await prepareMicrophone(selectedID: selectedMicrophoneID, forScreenCapture: true) : nil
                if wantsMicrophone && microphoneID == nil {
                    started = false
                } else if plan.recordsCamera {
                    started = await startDualTrackRecording(
                        plan: plan,
                        cameraID: selectedCameraID,
                        microphoneID: microphoneID,
                        includeSystemAudio: wantsSystemAudio,
                        preferredFPS: preferredFPS
                    )
                } else {
                    started = await startScreenCaptureKitRecording(
                        to: plan.primaryVideoURL,
                        microphoneID: microphoneID,
                        includeSystemAudio: wantsSystemAudio,
                        micStemURL: plan.microphoneStemURL,
                        systemStemURL: plan.systemAudioStemURL,
                        excludeCameraBubble: false,
                        requiresCameraBarrier: false
                    )
                }
            }

            await MainActor.run {
                if self.state == .finishing {
                    Task {
                        if let stream = self.scStream { try? await stream.stopCapture() }
                        self.scStream = nil
                        if self.activeCameraSessionRunning {
                            CameraBubbleController.shared.stopRecordingCapture()
                            self.activeCameraSessionRunning = false
                        }
                        self.writerQueue.sync {
                            self.cancelAllWritersLocked()
                            self.resetWriterState()
                        }
                        Self.cleanupPlanArtifacts(plan)
                        await MainActor.run {
                            self.state = .idle
                            self.preparingStopCompletion?(nil, nil)
                            self.preparingStopCompletion = nil
                        }
                    }
                    return
                }
                guard started else {
                    if let stream = self.scStream {
                        Task { try? await stream.stopCapture() }
                        self.scStream = nil
                    }
                    if self.activeCameraSessionRunning {
                        CameraBubbleController.shared.stopRecordingCapture()
                        self.activeCameraSessionRunning = false
                    }
                    self.writerQueue.sync {
                        self.cancelAllWritersLocked()
                        self.resetWriterState()
                    }
                    Self.cleanupPlanArtifacts(plan)
                    if self.recordingError == nil {
                        self.recordingError = mode == .cameraOnly
                            ? "Camera recording could not start. Check your camera and microphone in Studio."
                            : "Screen recording could not start. Reopen Studio and try again."
                    }
                    self.state = .idle
                    return
                }
                self.writerQueue.sync { self.writerAcceptingSamples = true }
                self.activeTakePlan = plan
                self.activeOutputURL = plan.primaryVideoURL
                self.activeRecordingStart = Date()
                self.state = .recording(startedAt: Date())
                self.startElapsedTimer()
            }
        }
    }

    private static func cleanupPlanArtifacts(_ plan: TakeOutputPlan) {
        let fm = FileManager.default
        if let dir = plan.takeDirectoryURL {
            try? fm.removeItem(at: dir)
        } else {
            try? fm.removeItem(at: plan.primaryVideoURL)
            if let cam = plan.cameraVideoURL { try? fm.removeItem(at: cam) }
            if let mic = plan.microphoneStemURL { try? fm.removeItem(at: mic) }
            if let sys = plan.systemAudioStemURL { try? fm.removeItem(at: sys) }
        }
    }

    private func prepareMicrophone(selectedID: String?, forScreenCapture: Bool) async -> String? {
        if forScreenCapture {
            guard #available(macOS 15.0, *) else {
                await MainActor.run { self.recordingError = "Microphone recording alongside screen capture requires macOS 15 or later." }
                return nil
            }
        }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else {
            await MainActor.run { self.recordingError = "Allow microphone access in System Settings before recording." }
            return nil
        }
        guard let device = StudioCaptureDevices.resolve(selectedID, mediaType: .audio) else {
            await MainActor.run { self.recordingError = "The selected microphone is unavailable. Choose a connected input in Studio." }
            return nil
        }
        return device.uniqueID
    }

    private func prepareCameraAccess() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        if !granted {
            await MainActor.run {
                self.recordingError = "Allow Camera access in System Settings before recording."
            }
        }
        return granted
    }

    private func startCameraOnlyRecording(
        plan: TakeOutputPlan,
        cameraID: String?,
        wantsMicrophone: Bool,
        selectedMicrophoneID: String?,
        preferredFPS: Double
    ) async -> Bool {
        guard await prepareCameraAccess() else { return false }
        let micID: String?
        if wantsMicrophone {
            micID = await prepareMicrophone(selectedID: selectedMicrophoneID, forScreenCapture: false)
            guard micID != nil else { return false }
        } else {
            micID = nil
        }
        guard let cameraURL = plan.cameraVideoURL else { return false }

        let result = await CameraBubbleController.shared.startRecordingCapture(
            deviceID: cameraID,
            microphoneID: micID,
            preferredFPS: preferredFPS,
            onVideoSample: { [weak self] buffer, sessionClock, portClock in
                self?.appendCameraVideoSample(buffer, sessionClock: sessionClock, portClock: portClock)
            },
            onAudioSample: { [weak self] buffer, sessionClock, portClock in
                self?.appendCameraAudioSample(buffer, sessionClock: sessionClock, portClock: portClock)
            },
            onRuntimeError: { [weak self] message in
                self?.cameraStreamStopped(with: message)
            }
        )

        switch result {
        case .failure(let error):
            await MainActor.run { self.recordingError = "Camera capture could not start: \(error.localizedDescription)" }
            return false
        case .success(let feed):
            let configured: Bool = writerQueue.sync {
                self.resetWriterState()
                guard let camWriter = CameraTrackWriter(
                    outputURL: cameraURL,
                    width: Int(feed.dimensions.width),
                    height: Int(feed.dimensions.height),
                    frameRate: feed.frameRate,
                    includeMicrophoneAudio: feed.includesMicrophone,
                    preferHEVC: true
                ) else {
                    return false
                }
                self.cameraWriter = camWriter
                if let micStemURL = plan.microphoneStemURL, feed.includesMicrophone {
                    self.micStemWriter = AudioStemWriter(outputURL: micStemURL, channelCount: 1)
                }
                self.syncBarrier.reset(requiresScreen: false, requiresCamera: true)
                self.activeSessionClock = CMClockGetHostTimeClock()
                self.recordedDimensions = feed.dimensions
                self.activeCameraResolution = "\(camWriter.width)×\(camWriter.height)"
                return true
            }
            guard configured else {
                CameraBubbleController.shared.stopRecordingCapture()
                await MainActor.run { self.recordingError = "Catch could not initialize the HEVC camera encoder." }
                return false
            }
            self.activeCameraSessionRunning = true
            return true
        }
    }

    private func startDualTrackRecording(
        plan: TakeOutputPlan,
        cameraID: String?,
        microphoneID: String?,
        includeSystemAudio: Bool,
        preferredFPS: Double
    ) async -> Bool {
        guard await prepareCameraAccess() else { return false }
        guard let screenURL = plan.screenVideoURL, let cameraURL = plan.cameraVideoURL else { return false }

        // Ensure floating self-view bubble is marked private before SCShareableContent is queried.
        await MainActor.run {
            CameraBubbleController.shared.hideFromScreenCapture = true
        }

        let cameraResult = await CameraBubbleController.shared.startRecordingCapture(
            deviceID: cameraID,
            microphoneID: nil, // Microphone is captured once by SCStream and fanned out to both writers.
            preferredFPS: preferredFPS,
            onVideoSample: { [weak self] buffer, sessionClock, portClock in
                self?.appendCameraVideoSample(buffer, sessionClock: sessionClock, portClock: portClock)
            },
            onAudioSample: { _, _, _ in },
            onRuntimeError: { [weak self] message in
                self?.cameraStreamStopped(with: message)
            }
        )

        let feed: ActiveCameraRecordingFeed
        switch cameraResult {
        case .failure(let error):
            await MainActor.run { self.recordingError = "Camera ISO could not start: \(error.localizedDescription)" }
            return false
        case .success(let activeFeed):
            feed = activeFeed
            self.activeCameraSessionRunning = true
        }

        let screenStarted = await startScreenCaptureKitRecording(
            to: screenURL,
            microphoneID: microphoneID,
            includeSystemAudio: includeSystemAudio,
            micStemURL: plan.microphoneStemURL,
            systemStemURL: plan.systemAudioStemURL,
            excludeCameraBubble: true,
            requiresCameraBarrier: true,
            cameraISOConfig: (cameraURL, feed)
        )

        if !screenStarted {
            CameraBubbleController.shared.stopRecordingCapture()
            self.activeCameraSessionRunning = false
            return false
        }
        return true
    }

    public func pauseRecording() {
        guard case .recording = state else { return }
        if let start = activeRecordingStart {
            accumulatedElapsed += Date().timeIntervalSince(start)
        }
        activeRecordingStart = nil
        writerQueue.sync {
            writerAcceptingSamples = false
            pausedAtClockTime = CMClockGetTime(activeSessionClock)
        }
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        state = .paused(elapsed: accumulatedElapsed)
    }

    public func resumeRecording() {
        guard case .paused = state else { return }
        writerQueue.sync {
            if let pausedAtClockTime {
                removedPauseDuration = CMTimeAdd(
                    removedPauseDuration,
                    CMTimeSubtract(CMClockGetTime(activeSessionClock), pausedAtClockTime)
                )
            }
            pausedAtClockTime = nil
            writerAcceptingSamples = true
        }
        activeRecordingStart = Date()
        state = .recording(startedAt: Date())
        startElapsedTimer()
    }

    public func stopRecording(
        historyStore: HistoryStore = .shared,
        presentQuickAccess: Bool = true,
        completion: (@Sendable (URL?, CaptureHistoryItem?) -> Void)? = nil
    ) {
        guard state.isActive || state == .preparing else {
            completion?(nil, nil)
            return
        }

        if state == .preparing {
            state = .finishing
            preparingStopCompletion = completion
            return
        }
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        StudioInkOverlay.shared.clear()
        state = .finishing

        writerQueue.sync { writerAcceptingSamples = false }
        let capturedStream = scStream
        scStream = nil
        let stopCameraCapture = activeCameraSessionRunning
        activeCameraSessionRunning = false
        let plan = activeTakePlan
        let outputURL = activeOutputURL
        let cameraResLabel = activeCameraResolution
        let fps = max(15, SettingsStore.shared.recordingFrameRate)
        let size = recordedDimensions

        Task {
            if let capturedStream {
                try? await capturedStream.stopCapture()
            }
            if stopCameraCapture {
                CameraBubbleController.shared.stopRecordingCapture()
            }

            let finalize = await finalizeTakeWriters(plan: plan, fallbackSize: size, fps: fps)

            var recoveredFiles: [String] = []
            if finalize.screenFailure != nil, let screenURL = plan?.screenVideoURL ?? (plan == nil ? outputURL : nil) {
                if let recovered = await Self.resolveFailedOutput(
                    at: screenURL,
                    allowInterruptedRecovery: finalize.allowScreenInterruptedRecovery
                ) {
                    recoveredFiles.append(recovered.lastPathComponent)
                }
            }
            if finalize.cameraFailure != nil, let cameraURL = plan?.cameraVideoURL {
                if let recovered = await Self.resolveFailedOutput(
                    at: cameraURL,
                    allowInterruptedRecovery: finalize.allowCameraInterruptedRecovery
                ) {
                    recoveredFiles.append(recovered.lastPathComponent)
                }
            }

            let finalScreenURL = (finalize.screenFailure == nil && plan?.recordsScreen != false)
                ? (plan?.screenVideoURL ?? outputURL)
                : nil
            let finalCameraURL = (finalize.cameraFailure == nil) ? finalize.cameraURL : nil

            let primaryURL: URL?
            if let plan {
                if plan.recordsScreen && plan.recordsCamera {
                    primaryURL = (finalize.screenFailure == nil && finalize.cameraFailure == nil) ? finalScreenURL : nil
                } else if plan.recordsCamera {
                    primaryURL = finalCameraURL
                } else {
                    primaryURL = finalScreenURL
                }
            } else {
                primaryURL = finalize.screenFailure == nil ? outputURL : nil
            }

            let combinedFailure: String? = [finalize.screenFailure, finalize.cameraFailure]
                .compactMap { $0 }
                .joined(separator: " ")
                .nilIfEmpty

            // Remove empty take folder if everything failed and nothing was recovered.
            if primaryURL == nil, let takeDir = plan?.takeDirectoryURL {
                let remaining = (try? FileManager.default.contentsOfDirectory(atPath: takeDir.path)) ?? []
                if remaining.isEmpty {
                    try? FileManager.default.removeItem(at: takeDir)
                }
            }

            let bundle: RecordedTakeBundle?
            if let primaryURL {
                bundle = RecordedTakeBundle(
                    primaryVideoURL: primaryURL,
                    screenVideoURL: finalScreenURL,
                    cameraVideoURL: finalCameraURL,
                    cameraResolution: finalCameraURL != nil ? cameraResLabel : nil,
                    microphoneStemURL: finalize.micStemURL,
                    systemAudioStemURL: finalize.systemStemURL,
                    takeDirectoryURL: plan?.takeDirectoryURL
                )
            } else {
                bundle = nil
            }

            var historyItem: CaptureHistoryItem?
            if let bundle,
               FileManager.default.fileExists(atPath: bundle.primaryVideoURL.path) {
                let poster = Self.generatePosterImage(from: bundle.primaryVideoURL, fallbackSize: size)
                let title = plan?.baseName ?? bundle.primaryVideoURL.deletingPathExtension().lastPathComponent
                historyItem = historyStore.recordExistingMedia(
                    poster: poster,
                    fileURL: bundle.primaryVideoURL,
                    title: title,
                    mediaType: .video
                )
                if presentQuickAccess {
                    TakeReviewWindowController.shared.show(bundle: bundle)
                }
            }

            let createdItem = historyItem
            let recoveredSnapshot = recoveredFiles
            await MainActor.run {
                self.lastRecordedVideoURL = bundle?.primaryVideoURL
                self.lastRecordedBundle = bundle
                if let bundle, !self.syntheticTake {
                    do { try LocalStudioBridge.shared.saveHandoff(for: bundle.primaryVideoURL, bundle: bundle) }
                    catch { self.recordingError = "The video was saved, but its edit handoff could not be written: \(error.localizedDescription)" }
                }
                self.activeOutputURL = nil
                self.activeTakePlan = nil
                self.activeCameraResolution = nil
                if let combinedFailure {
                    if !recoveredSnapshot.isEmpty {
                        let joined = recoveredSnapshot.joined(separator: ", ")
                        self.recordingError = "\(combinedFailure) Partial recording saved as \(joined). No take was added to History."
                    } else {
                        self.recordingError = "\(combinedFailure) No take was added to History."
                    }
                }
                self.state = .idle
                completion?(bundle?.primaryVideoURL, createdItem)
            }
        }
    }

    // MARK: - Private Stream & AssetWriter Pipeline

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let start = self.activeRecordingStart else { return }
            self.elapsedSeconds = Int(self.accumulatedElapsed + Date().timeIntervalSince(start))
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func startScreenCaptureKitRecording(
        to outputURL: URL,
        microphoneID: String?,
        includeSystemAudio: Bool,
        micStemURL: URL? = nil,
        systemStemURL: URL? = nil,
        excludeCameraBubble: Bool = false,
        requiresCameraBarrier: Bool = false,
        cameraISOConfig: (url: URL, feed: ActiveCameraRecordingFeed)? = nil
    ) async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let screen = CaptureEngine.shared.resolveScreen(displayIndex: nil)
            let targetDisplayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                ?? CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == targetDisplayID }) ?? content.displays.first else {
                return false
            }

            let excludedIDs = await MainActor.run { () -> Set<CGWindowID> in
                var ids: Set<CGWindowID> = []
                if TeleprompterController.shared.hideFromCapture,
                   let tpNum = TeleprompterController.shared.windowNumber,
                   tpNum > 0 {
                    ids.insert(CGWindowID(tpNum))
                }
                if let ctrlNum = self.controlBarPanel?.windowNumber, ctrlNum > 0 {
                    ids.insert(CGWindowID(ctrlNum))
                }
                if excludeCameraBubble,
                   CameraBubbleController.shared.isVisible,
                   CameraBubbleController.shared.displayStyle == .floatingBubble,
                   let camNum = CameraBubbleController.shared.windowNumber,
                   camNum > 0 {
                    ids.insert(CGWindowID(camNum))
                }
                return ids
            }
            guard let filter = Self.buildContentFilter(display: display, windows: content.windows, excludedIDs: excludedIDs) else {
                await MainActor.run {
                    self.recordingError = "Catch could not exclude a private presenter window. Close the teleprompter or reopen Studio before retrying."
                }
                return false
            }
            let scale = SettingsStore.shared.recordingScaleRetinaTo1x ? 1.0 : max(1.0, screen.backingScaleFactor)
            let region = (captureMode == .area ? selectedRect : nil) ?? screen.frame
            let targetWidth = max(320, (Int(region.width * scale) / 2) * 2)
            let targetHeight = max(240, (Int(region.height * scale) / 2) * 2)

            let config = SCStreamConfiguration()
            config.width = targetWidth
            config.height = targetHeight
            let fps = max(15, SettingsStore.shared.recordingFrameRate)
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = true
            config.capturesAudio = includeSystemAudio
            if #available(macOS 15.0, *) {
                config.captureMicrophone = microphoneID != nil
                config.microphoneCaptureDeviceID = microphoneID
            }

            if captureMode == .area, let rect = selectedRect {
                let relativeX = max(0, rect.minX - screen.frame.minX)
                let relativeY = max(0, screen.frame.maxY - rect.maxY)
                config.sourceRect = CGRect(x: relativeX, y: relativeY, width: rect.width, height: rect.height)
            }

            let writerConfigured = setupAssetWriter(
                to: outputURL,
                width: targetWidth,
                height: targetHeight,
                includeAudio: includeSystemAudio,
                includeMicrophone: microphoneID != nil
            )
            guard writerConfigured else { return false }

            let companionsReady: Bool = writerQueue.sync {
                if let cameraISOConfig {
                    guard let camWriter = CameraTrackWriter(
                        outputURL: cameraISOConfig.url,
                        width: Int(cameraISOConfig.feed.dimensions.width),
                        height: Int(cameraISOConfig.feed.dimensions.height),
                        frameRate: cameraISOConfig.feed.frameRate,
                        includeMicrophoneAudio: microphoneID != nil,
                        preferHEVC: true
                    ) else {
                        return false
                    }
                    self.cameraWriter = camWriter
                    self.activeCameraResolution = "\(camWriter.width)×\(camWriter.height)"
                }
                if let micStemURL, microphoneID != nil {
                    self.micStemWriter = AudioStemWriter(outputURL: micStemURL, channelCount: 1)
                }
                if let systemStemURL, includeSystemAudio {
                    self.systemAudioStemWriter = AudioStemWriter(outputURL: systemStemURL, channelCount: 2)
                }
                self.syncBarrier.reset(requiresScreen: true, requiresCamera: requiresCameraBarrier)
                self.activeSessionClock = CMClockGetHostTimeClock()
                return true
            }
            guard companionsReady else {
                await MainActor.run { self.recordingError = "Catch could not initialize the full-resolution camera encoder." }
                return false
            }

            let handler = RecordingStreamOutput(studio: self)
            let stream = SCStream(filter: filter, configuration: config, delegate: handler)
            try stream.addStreamOutput(handler, type: .screen, sampleHandlerQueue: writerQueue)
            if includeSystemAudio {
                try stream.addStreamOutput(handler, type: .audio, sampleHandlerQueue: writerQueue)
            }
            if #available(macOS 15.0, *), microphoneID != nil {
                try stream.addStreamOutput(handler, type: .microphone, sampleHandlerQueue: writerQueue)
            }
            try await stream.startCapture()

            self.streamOutput = handler
            self.scStream = stream
            return true
        } catch let error as SCStreamError where error.code == .userDeclined {
            await MainActor.run { self.recordingError = Self.screenRecordingPermissionError }
            return false
        } catch {
            await MainActor.run { self.recordingError = "Screen capture could not start: \(error.localizedDescription)" }
            return false
        }
    }

    private static func buildContentFilter(display: SCDisplay, windows: [SCWindow], excludedIDs: Set<CGWindowID>) -> SCContentFilter? {
        let excludedWindows = windows.filter { excludedIDs.contains($0.windowID) }
        guard Set(excludedWindows.map(\.windowID)) == excludedIDs else { return nil }
        return SCContentFilter(display: display, excludingWindows: excludedWindows)
    }

    private func prepareFallbackWriter(to outputURL: URL) async {
        let w = 1280
        let h = 720
        _ = setupAssetWriter(to: outputURL, width: w, height: h, includeAudio: false)
    }

    struct MonotonicTimestampGuard {
        private(set) var sessionStartPTS: CMTime?
        private(set) var lastVideoPTS: CMTime?
        private(set) var lastSystemAudioPTS: CMTime?
        private(set) var lastMicrophonePTS: CMTime?

        mutating func reset() {
            sessionStartPTS = nil
            lastVideoPTS = nil
            lastSystemAudioPTS = nil
            lastMicrophonePTS = nil
        }

        mutating func startSession(at pts: CMTime) -> Bool {
            guard pts.isValid, pts.isNumeric else { return false }
            sessionStartPTS = pts
            return true
        }

        func shouldAccept(pts: CMTime, for type: SCStreamOutputType) -> Bool {
            guard pts.isValid, pts.isNumeric else { return false }
            if let sessionStartPTS, CMTimeCompare(pts, sessionStartPTS) < 0 {
                return false
            }
            switch type {
            case .screen:
                if let last = lastVideoPTS, CMTimeCompare(pts, last) <= 0 {
                    return false
                }
                return true
            case .audio:
                if let last = lastSystemAudioPTS, CMTimeCompare(pts, last) <= 0 {
                    return false
                }
                return true
            default:
                if #available(macOS 15.0, *), type == .microphone {
                    if let last = lastMicrophonePTS, CMTimeCompare(pts, last) <= 0 {
                        return false
                    }
                    return true
                }
                return false
            }
        }

        mutating func recordAppended(pts: CMTime, for type: SCStreamOutputType) {
            switch type {
            case .screen:
                lastVideoPTS = pts
            case .audio:
                lastSystemAudioPTS = pts
            default:
                if #available(macOS 15.0, *), type == .microphone {
                    lastMicrophonePTS = pts
                }
            }
        }
    }

    struct FinalizeResult: Sendable {
        let failure: String?
        let allowInterruptedRecovery: Bool
    }

    private struct TakeFinalizeResult: Sendable {
        let screenFailure: String?
        let allowScreenInterruptedRecovery: Bool
        let cameraURL: URL?
        let cameraFailure: String?
        let allowCameraInterruptedRecovery: Bool
        let micStemURL: URL?
        let systemStemURL: URL?
    }

    static func shouldAcceptSampleBuffer(_ sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) -> Bool {
        guard CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer) else {
            return false
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, pts.isNumeric else { return false }

        if type == .screen {
            guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let attachments = attachmentsArray.first,
                  let statusRawValue = attachments[.status] as? Int,
                  let status = SCFrameStatus(rawValue: statusRawValue),
                  status == .complete else {
                return false
            }
            guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else {
                return false
            }
            return true
        }

        return CMSampleBufferGetNumSamples(sampleBuffer) > 0
    }

    static func interruptedURL(for outputURL: URL) -> URL {
        let baseName = outputURL.deletingPathExtension().lastPathComponent
        let ext = outputURL.pathExtension
        let taggedName = baseName.hasSuffix("-interrupted") ? baseName : "\(baseName)-interrupted"
        let dir = outputURL.deletingLastPathComponent()
        return ext.isEmpty
            ? dir.appendingPathComponent(taggedName)
            : dir.appendingPathComponent(taggedName).appendingPathExtension(ext)
    }

    static func isPlayableVideo(at url: URL) async -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attrs[.size] as? NSNumber,
              fileSize.int64Value > 0 else {
            return false
        }
        let asset = AVURLAsset(url: url)
        guard let isPlayable = try? await asset.load(.isPlayable), isPlayable,
              let videoTracks = try? await asset.loadTracks(withMediaType: .video), !videoTracks.isEmpty,
              let duration = try? await asset.load(.duration),
              duration.isValid, duration.isNumeric, CMTimeGetSeconds(duration) > 0 else {
            return false
        }
        return true
    }

    static func resolveFailedOutput(at outputURL: URL, allowInterruptedRecovery: Bool) async -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: outputURL.path) else { return nil }
        if allowInterruptedRecovery, await isPlayableVideo(at: outputURL) {
            let destination = interruptedURL(for: outputURL)
            try? fm.removeItem(at: destination)
            do {
                try fm.moveItem(at: outputURL, to: destination)
                return destination
            } catch {
                try? fm.removeItem(at: outputURL)
                return nil
            }
        }
        try? fm.removeItem(at: outputURL)
        return nil
    }

    private func cancelAllWritersLocked() {
        assetWriter?.cancelWriting()
        cameraWriter?.cancel()
        micStemWriter?.cancel()
        systemAudioStemWriter?.cancel()
    }

    private func resetWriterState() {
        assetWriter = nil
        videoInput = nil
        audioInput = nil
        microphoneInput = nil
        pixelAdaptor = nil
        cameraWriter = nil
        micStemWriter = nil
        systemAudioStemWriter = nil
        syncBarrier.reset(requiresScreen: true, requiresCamera: false)
        activeSessionClock = CMClockGetHostTimeClock()
        cameraVideoClockNormalizer.reset()
        cameraAudioClockNormalizer.reset()
        sessionStarted = false
        frameCounter = 0
        microphoneSamples = 0
        streamFailure = nil
        streamInterrupted = false
        cameraFailure = nil
        cameraInterrupted = false
        writerAcceptingSamples = false
        pausedAtClockTime = nil
        removedPauseDuration = .zero
        timestampGuard.reset()
    }

    func setWriterAcceptingSamples(_ accepting: Bool) {
        writerQueue.sync { writerAcceptingSamples = accepting }
    }

    func setupAssetWriter(to outputURL: URL, width: Int, height: Int, includeAudio: Bool, includeMicrophone: Bool = false) -> Bool {
        writerQueue.sync {
            try? FileManager.default.removeItem(at: outputURL)
            guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else {
                return false
            }

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 6_000_000,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
            let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            vInput.expectsMediaDataInRealTime = true

            let adaptorAttrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: vInput,
                sourcePixelBufferAttributes: adaptorAttrs
            )

            guard writer.canAdd(vInput) else { return false }
            writer.add(vInput)

            var aInput: AVAssetWriterInput?
            if includeAudio {
                var audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 128_000
                ]
                if let layoutData = AssetWriterDiagnostics.channelLayoutData(for: 2) {
                    audioSettings[AVChannelLayoutKey] = layoutData
                }
                let candidate = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                candidate.expectsMediaDataInRealTime = true
                guard writer.canAdd(candidate) else { return false }
                writer.add(candidate)
                aInput = candidate
            }

            var micInput: AVAssetWriterInput?
            if includeMicrophone {
                var settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 128_000
                ]
                if let layoutData = AssetWriterDiagnostics.channelLayoutData(for: 1) {
                    settings[AVChannelLayoutKey] = layoutData
                }
                let candidate = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
                candidate.expectsMediaDataInRealTime = true
                guard writer.canAdd(candidate) else { return false }
                writer.add(candidate)
                micInput = candidate
            }
            self.assetWriter = writer
            self.microphoneInput = micInput
            self.microphoneSamples = 0
            self.videoInput = vInput
            self.audioInput = aInput
            self.pixelAdaptor = adaptor
            self.cameraWriter = nil
            self.micStemWriter = nil
            self.systemAudioStemWriter = nil
            self.syncBarrier.reset(requiresScreen: true, requiresCamera: false)
            self.activeSessionClock = CMClockGetHostTimeClock()
            self.cameraVideoClockNormalizer.reset()
            self.cameraAudioClockNormalizer.reset()
            self.sessionStarted = false
            self.frameCounter = 0
            self.streamFailure = nil
            self.streamInterrupted = false
            self.cameraFailure = nil
            self.cameraInterrupted = false
            self.writerAcceptingSamples = false
            self.pausedAtClockTime = nil
            self.removedPauseDuration = .zero
            self.timestampGuard.reset()
            self.recordedDimensions = CGSize(width: width, height: height)
            return true
        }
    }

    private func startSynchronizedSessionLocked(_ resolution: DualTrackSyncBarrier.Resolution) -> Bool {
        let startPTS = resolution.startPTS
        if let writer = assetWriter {
            guard writer.startWriting() else {
                streamFailure = Self.writerFailure(writer, fallback: "The video encoder could not start.")
                return false
            }
            writer.startSession(atSourceTime: startPTS)
            _ = timestampGuard.startSession(at: startPTS)
        }
        if let camWriter = cameraWriter {
            guard camWriter.startSession(at: startPTS) else {
                cameraFailure = camWriter.failure ?? "The camera encoder could not start."
                return false
            }
        }
        _ = micStemWriter?.startSession(at: startPTS)
        _ = systemAudioStemWriter?.startSession(at: startPTS)
        sessionStarted = true

        if let initialScreen = resolution.initialScreen {
            appendScreenVideoLocked(initialScreen.sample, pts: initialScreen.pts)
        }
        if let initialCamera = resolution.initialCamera {
            cameraWriter?.appendVideo(initialCamera.sample)
        }
        return true
    }

    private func appendScreenVideoLocked(_ sampleBuffer: CMSampleBuffer, pts: CMTime) {
        guard let writer = assetWriter, writer.status == .writing else {
            if let writer = assetWriter {
                streamFailure = Self.writerFailure(writer, fallback: "The video writer failed.")
            }
            return
        }
        guard timestampGuard.shouldAccept(pts: pts, for: .screen) else { return }
        if let vInput = videoInput, vInput.isReadyForMoreMediaData {
            if vInput.append(sampleBuffer) {
                timestampGuard.recordAppended(pts: pts, for: .screen)
                frameCounter += 1
            } else {
                streamFailure = Self.writerFailure(writer, fallback: "Video writer rejected a frame.")
            }
        }
    }

    func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard Self.shouldAcceptSampleBuffer(sampleBuffer, of: type) else { return }
        writerQueue.async { [weak self] in
            guard let self,
                  let writer = self.assetWriter,
                  self.writerAcceptingSamples,
                  self.streamFailure == nil,
                  let sampleBuffer = Self.removingPause(self.removedPauseDuration, from: sampleBuffer) else { return }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard pts.isValid, pts.isNumeric else { return }

            if !self.sessionStarted {
                guard type == .screen else { return }
                if let resolution = self.syncBarrier.ingestInitialScreen(sampleBuffer, pts: pts) {
                    _ = self.startSynchronizedSessionLocked(resolution)
                }
                return
            }

            guard writer.status == .writing else {
                self.streamFailure = Self.writerFailure(writer, fallback: "The video writer failed.")
                return
            }
            guard self.timestampGuard.shouldAccept(pts: pts, for: type) else { return }

            switch type {
            case .screen:
                self.appendScreenVideoLocked(sampleBuffer, pts: pts)
            case .audio:
                let sanitizedAudio = SampleBufferTimingHelper.sanitizingAudioChannelLayoutIfNeeded(sampleBuffer)
                if let aInput = self.audioInput, aInput.isReadyForMoreMediaData {
                    if aInput.append(sanitizedAudio) {
                        self.timestampGuard.recordAppended(pts: pts, for: type)
                    } else {
                        self.streamFailure = Self.writerFailure(writer, fallback: "System audio writer rejected a sample.")
                    }
                }
                self.systemAudioStemWriter?.append(sanitizedAudio)
            default:
                if #available(macOS 15.0, *), type == .microphone {
                    let sanitizedMic = SampleBufferTimingHelper.sanitizingAudioChannelLayoutIfNeeded(sampleBuffer)
                    if let input = self.microphoneInput, input.isReadyForMoreMediaData {
                        if input.append(sanitizedMic) {
                            self.timestampGuard.recordAppended(pts: pts, for: type)
                            self.microphoneSamples += 1
                        } else {
                            self.streamFailure = Self.writerFailure(writer, fallback: "Microphone writer rejected a sample.")
                        }
                    }
                    // Fan out the exact same mic audio to the camera ISO MP4 and optional WAV stem.
                    self.cameraWriter?.appendAudio(sanitizedMic)
                    self.micStemWriter?.append(sanitizedMic)
                }
            }
        }
    }

    func appendCameraVideoSample(
        _ sampleBuffer: CMSampleBuffer,
        sessionClock: CMClock?,
        portClock: CMClock?,
        hostNow: CMTime? = nil
    ) {
        guard CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer),
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
        writerQueue.async { [weak self] in
            guard let self,
                  self.cameraWriter != nil,
                  self.writerAcceptingSamples,
                  self.cameraFailure == nil else { return }

            guard let aligned = self.cameraVideoClockNormalizer.normalizeSampleBuffer(
                sampleBuffer,
                sessionClock: sessionClock,
                portClock: portClock,
                hostNow: hostNow
            ) else { return }

            guard let adjusted = Self.removingPause(self.removedPauseDuration, from: aligned) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(adjusted)
            guard pts.isValid, pts.isNumeric else { return }

            if !self.sessionStarted {
                if let resolution = self.syncBarrier.ingestInitialCamera(adjusted, pts: pts) {
                    _ = self.startSynchronizedSessionLocked(resolution)
                }
                return
            }

            self.cameraWriter?.appendVideo(adjusted)
        }
    }

    func appendCameraAudioSample(
        _ sampleBuffer: CMSampleBuffer,
        sessionClock: CMClock?,
        portClock: CMClock?,
        hostNow: CMTime? = nil
    ) {
        guard CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer),
              CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        writerQueue.async { [weak self] in
            guard let self,
                  self.sessionStarted,
                  self.cameraWriter != nil,
                  self.writerAcceptingSamples,
                  self.cameraFailure == nil else { return }

            guard let aligned = self.cameraAudioClockNormalizer.normalizeSampleBuffer(
                sampleBuffer,
                sessionClock: sessionClock,
                portClock: portClock,
                hostNow: hostNow
            ) else { return }

            guard let adjusted = Self.removingPause(self.removedPauseDuration, from: aligned) else { return }

            self.cameraWriter?.appendAudio(adjusted)
            self.micStemWriter?.append(adjusted)
        }
    }

    func streamStopped(with error: Error) {
        writerQueue.async { [weak self] in
            guard let self else { return }
            self.streamInterrupted = true
            if self.streamFailure == nil {
                self.streamFailure = "Screen capture stopped unexpectedly: \(error.localizedDescription)."
            }
            DispatchQueue.main.async {
                guard self.state.isActive else { return }
                self.stopRecording(presentQuickAccess: false)
            }
        }
    }

    private func cameraStreamStopped(with message: String) {
        writerQueue.async { [weak self] in
            guard let self else { return }
            self.cameraInterrupted = true
            if self.cameraFailure == nil {
                self.cameraFailure = message
            }
            DispatchQueue.main.async {
                guard self.state.isActive else { return }
                self.stopRecording(presentQuickAccess: false)
            }
        }
    }

    private static func removingPause(_ offset: CMTime, from sample: CMSampleBuffer) -> CMSampleBuffer? {
        SampleBufferTimingHelper.subtractingOffset(offset, from: sample)
    }

    private static func writerFailure(_ writer: AVAssetWriter, fallback: String) -> String {
        guard let error = writer.error as NSError? else { return fallback }
        let cause = (error.userInfo[NSUnderlyingErrorKey] as? NSError).map { " — \($0.domain) \($0.code)" } ?? ""
        return "\(fallback) \(error.localizedDescription) (\(error.domain) \(error.code)\(cause))"
    }

    func finalizeWriter(fallbackSize: CGSize, fps: Int) async -> FinalizeResult {
        let result = await finalizeTakeWriters(plan: nil, fallbackSize: fallbackSize, fps: fps)
        return FinalizeResult(
            failure: result.screenFailure,
            allowInterruptedRecovery: result.allowScreenInterruptedRecovery
        )
    }

    private func finalizeTakeWriters(plan: TakeOutputPlan?, fallbackSize: CGSize, fps: Int) async -> TakeFinalizeResult {
        let snapshot: (
            writer: AVAssetWriter?,
            vInput: AVAssetWriterInput?,
            aInput: AVAssetWriterInput?,
            mInput: AVAssetWriterInput?,
            adaptor: AVAssetWriterInputPixelBufferAdaptor?,
            camWriter: CameraTrackWriter?,
            micStem: AudioStemWriter?,
            sysStem: AudioStemWriter?,
            synthetic: Bool,
            sessionStarted: Bool,
            frameCounter: Int64,
            micSamples: Int,
            streamFailure: String?,
            streamInterrupted: Bool,
            cameraFailure: String?,
            cameraInterrupted: Bool
        ) = writerQueue.sync {
            let result = (
                assetWriter,
                videoInput,
                audioInput,
                microphoneInput,
                pixelAdaptor,
                cameraWriter,
                micStemWriter,
                systemAudioStemWriter,
                syntheticTake,
                sessionStarted,
                frameCounter,
                microphoneSamples,
                streamFailure,
                streamInterrupted,
                cameraFailure,
                cameraInterrupted
            )
            resetWriterState()
            return result
        }

        // 1. Finalize Screen MP4 (if present)
        var screenFailure: String? = nil
        var allowScreenRecovery = false
        if let writer = snapshot.writer {
            var didStartSession = snapshot.sessionStarted
            if snapshot.synthetic && !didStartSession,
               let vInput = snapshot.vInput,
               let adaptor = snapshot.adaptor {
                writer.startWriting()
                writer.startSession(atSourceTime: .zero)
                didStartSession = true

                let width = Int(fallbackSize.width)
                let height = Int(fallbackSize.height)
                let timescale = CMTimeScale(max(15, fps))
                for frameIndex in 0..<5 {
                    if let pb = Self.makeSolidPixelBuffer(width: width, height: height) {
                        while !vInput.isReadyForMoreMediaData {
                            try? await Task.sleep(for: .milliseconds(5))
                        }
                        let time = CMTime(value: CMTimeValue(frameIndex), timescale: timescale)
                        adaptor.append(pb, withPresentationTime: time)
                    }
                }
            }

            let pendingFailure: String?
            var canRecover = false
            if let sf = snapshot.streamFailure {
                pendingFailure = sf
                canRecover = snapshot.streamInterrupted
                    && writer.status == .writing
                    && didStartSession
                    && snapshot.frameCounter > 0
                    && (snapshot.mInput == nil || snapshot.micSamples > 0)
            } else if writer.status == .failed {
                pendingFailure = Self.writerFailure(writer, fallback: "Catch could not write the MP4.")
            } else if !didStartSession || (!snapshot.synthetic && snapshot.frameCounter == 0) {
                pendingFailure = "Catch received no usable screen frames."
            } else if snapshot.mInput != nil && snapshot.micSamples == 0 {
                pendingFailure = "Catch received no audio from the selected microphone. Check the input in Studio or turn off the microphone for a silent take."
            } else if writer.status != .writing {
                pendingFailure = Self.writerFailure(writer, fallback: "The MP4 writer stopped before the take could be saved.")
            } else {
                pendingFailure = nil
            }

            if let pendingFailure, !canRecover {
                if writer.status == .writing { writer.cancelWriting() }
                screenFailure = pendingFailure
                allowScreenRecovery = false
            } else {
                snapshot.vInput?.markAsFinished()
                snapshot.aInput?.markAsFinished()
                snapshot.mInput?.markAsFinished()
                let completed: Bool = await withCheckedContinuation { continuation in
                    writer.finishWriting {
                        continuation.resume(returning: writer.status == .completed)
                    }
                }
                if let pendingFailure {
                    screenFailure = pendingFailure
                    allowScreenRecovery = completed
                } else if !completed {
                    screenFailure = Self.writerFailure(writer, fallback: "Catch could not finish the MP4.")
                }
            }
        } else if plan == nil || plan?.recordsScreen == true {
            screenFailure = "Catch could not open the video writer for this take."
        }

        // 2. Finalize Full-Res Camera HEVC MP4 (if present)
        var cameraURL: URL? = nil
        var cameraFailure: String? = nil
        var allowCameraRecovery = false
        if let camWriter = snapshot.camWriter {
            let camResult = await camWriter.finish(interrupted: snapshot.cameraInterrupted)
            cameraURL = camResult.url
            cameraFailure = snapshot.cameraFailure ?? camResult.failure
            allowCameraRecovery = camResult.allowInterruptedRecovery || (snapshot.cameraFailure != nil && camResult.url != nil)
        } else if plan?.recordsCamera == true {
            cameraFailure = snapshot.cameraFailure ?? "Catch could not open the camera video writer for this take."
        }

        // 3. Finalize optional uncompressed WAV audio stems
        let micStemURL = await snapshot.micStem?.finish()
        let systemStemURL = await snapshot.sysStem?.finish()

        return TakeFinalizeResult(
            screenFailure: screenFailure,
            allowScreenInterruptedRecovery: allowScreenRecovery,
            cameraURL: cameraURL,
            cameraFailure: cameraFailure,
            allowCameraInterruptedRecovery: allowCameraRecovery,
            micStemURL: micStemURL,
            systemStemURL: systemStemURL
        )
    }

    static func makeSolidPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &buffer
        ) == kCVReturnSuccess, let pb = buffer else {
            return nil
        }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
            memset(base, 0x1E, bytesPerRow * height)
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    public static func generatePosterImage(from videoURL: URL, fallbackSize: CGSize) -> CGImage {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        if let cg = try? generator.copyCGImage(at: .zero, actualTime: nil) {
            return cg
        }
        return CaptureEngine.makeSyntheticImage(
            width: max(320, Int(fallbackSize.width)),
            height: max(240, Int(fallbackSize.height)),
            label: "Catch Video"
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private final class RecordingStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private weak var studio: ScreenRecordingStudio?

    init(studio: ScreenRecordingStudio) {
        self.studio = studio
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard ScreenRecordingStudio.shouldAcceptSampleBuffer(sampleBuffer, of: type) else { return }
        studio?.appendSampleBuffer(sampleBuffer, of: type)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        studio?.streamStopped(with: error)
    }
}

// MARK: - Loom Studio Control Bar View

private struct LoomStudioBarView: View {
    @ObservedObject var studio: ScreenRecordingStudio

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            transport
            StudioInputSelectors(studio: studio, compact: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .raycastLiquidGlass(cornerRadius: 18, tintAlpha: 0.85)
        .preferredColorScheme(.dark)
        .alert("Recording error", isPresented: Binding(
            get: { studio.recordingError != nil },
            set: { if !$0 { studio.recordingError = nil } }
        ), presenting: studio.recordingError) { error in
            if error == ScreenRecordingStudio.screenRecordingPermissionError {
                Button("Open System Settings") {
                    SystemPermissionsManager.shared.openScreenRecordingSettings()
                }
            }
            Button("OK", role: .cancel) { studio.recordingError = nil }
        } message: { error in
            Text(error)
        }
    }

    private var transport: some View {
        HStack(spacing: 10) {
            // Live indicator & timer
            HStack(spacing: 6) {
                Circle()
                    .fill(studio.state.isActive ? RaycastTheme.accent : Color.green)
                    .frame(width: 8, height: 8)
                Text(formattedTime)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(RaycastTheme.textPrimary)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(0.08)))

            // Mode selector
            if !studio.state.isActive {
                Picker("", selection: $studio.captureMode) {
                    Text("Display").tag(RecordingAreaMode.fullscreen)
                    Text("Area").tag(RecordingAreaMode.area)
                    Text("Camera").tag(RecordingAreaMode.cameraOnly)
                }
                .pickerStyle(.segmented)
                .frame(width: 186)

                if studio.captureMode == .area {
                    Button("Select") {
                        studio.selectRecordingArea()
                    }
                    .controlSize(.small)
                }
            }

            // Camera Bubble / Full-Res Camera Toggle
            Button {
                guard studio.captureMode != .cameraOnly else { return }
                studio.showCameraBubble.toggle()
                if studio.showCameraBubble {
                    let isISO = studio.cameraRecordingMode == .separateFullResFile
                    CameraBubbleController.shared.hideFromScreenCapture = isISO
                    CameraBubbleController.shared.preferMaxResolution = isISO
                    CameraBubbleController.shared.displayStyle = .floatingBubble
                    CameraBubbleController.shared.show()
                } else {
                    CameraBubbleController.shared.hide()
                }
            } label: {
                let cameraOn = studio.captureMode == .cameraOnly || studio.showCameraBubble
                Image(systemName: cameraOn ? "video.fill" : "video.slash.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(cameraOn ? .white : RaycastTheme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(cameraOn ? RaycastTheme.accent.opacity(0.75) : Color.white.opacity(0.08))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(studio.state != .idle || studio.captureMode == .cameraOnly)
            .help(studio.captureMode == .cameraOnly
                  ? "Camera is always active in Camera Podcast mode"
                  : (studio.cameraRecordingMode == .separateFullResFile
                     ? "Toggle Separate Full-Res Camera Recording"
                     : "Toggle Camera Bubble"))

            // Microphone Toggle
            Button {
                studio.includeMicrophone.toggle()
                if !studio.includeMicrophone { StudioMicrophoneMeter.shared.stop() }
            } label: {
                Image(systemName: studio.includeMicrophone ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(studio.includeMicrophone ? .white : RaycastTheme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(studio.includeMicrophone ? RaycastTheme.accent.opacity(0.75) : Color.white.opacity(0.08))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(studio.state != .idle)
            .help("Toggle Microphone")
            if studio.includeMicrophone && studio.state == .idle { StudioMicrophoneMeterView() }

            // Teleprompter Toggle
            Button {
                studio.showTeleprompter.toggle()
                if studio.showTeleprompter {
                    TeleprompterController.shared.show()
                } else {
                    TeleprompterController.shared.hide()
                }
            } label: {
                Image(systemName: "text.justify.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(studio.showTeleprompter ? .white : RaycastTheme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(studio.showTeleprompter ? RaycastTheme.accent.opacity(0.75) : Color.white.opacity(0.08))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(studio.state != .idle)
            .help("Toggle Hidden Teleprompter")

            Spacer()

            // Transport Record / Pause / Stop
            if studio.state.isActive {
                if studio.captureMode != .cameraOnly {
                    Button("Clear Ink") { StudioInkOverlay.shared.clear() }
                        .help("Hold Option-Shift-Command-D to draw")
                        .controlSize(.small)
                }
                Button {
                    if case .paused = studio.state {
                        studio.resumeRecording()
                    } else {
                        studio.pauseRecording()
                    }
                } label: {
                    Image(systemName: isPaused ? "play.fill" : "pause.fill")
                }
                .raycastGlassButton(prominent: false)
                .controlSize(.small)

                Button {
                    studio.stopRecording()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .raycastGlassButton(prominent: true)
                .tint(RaycastTheme.accent)
                .controlSize(.small)
            } else {
                if studio.state == .preparing {
                    Button("Cancel") { studio.stopRecording() }
                        .controlSize(.small)
                } else if studio.state == .finishing {
                    Text("Finishing…").foregroundStyle(RaycastTheme.textSecondary)
                } else {
                    Button {
                        studio.startRecording()
                    } label: {
                        Label("Record", systemImage: "record.circle")
                    }
                    .raycastGlassButton(prominent: true)
                    .tint(RaycastTheme.accent)
                    .controlSize(.small)
                }

                Button {
                    studio.dismissStudio()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(RaycastTheme.textSecondary)
            }
        }
    }

    private var isPaused: Bool {
        if case .paused = studio.state { return true }
        return false
    }

    private var formattedTime: String {
        let mins = studio.elapsedSeconds / 60
        let secs = studio.elapsedSeconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

private final class KeyableHUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
