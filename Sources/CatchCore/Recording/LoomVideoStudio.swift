import Foundation
import AppKit
import SwiftUI
import AVFoundation
import CoreMedia
import CoreVideo
import ScreenCaptureKit

// MARK: - Teleprompter Controller (Viewer-Invisible Floating Script Panel)

public final class TeleprompterController: ObservableObject {
    public static let shared = TeleprompterController()

    private let scriptKey = "com.catchapp.teleprompter.script"
    private let wpmKey = "com.catchapp.teleprompter.wpm"
    private let fontSizeKey = "com.catchapp.teleprompter.fontSize"
    private let hideKey = "com.catchapp.teleprompter.hideFromCapture"

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
    @Published public var isPlaying: Bool = false
    @Published public var isEditingScript: Bool = false
    @Published public var scrollProgress: Double = 0.0
    @Published public var isVisible: Bool = false
    @Published private(set) var scrollMode: ScrollMode = .timed
    @Published private(set) var voiceStatus: VoiceStatus = .idle
    @Published private(set) var scriptAnchor: Int?
    @Published private(set) var nextSpokenWord: NSRange?
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
    private var scrollTimer: Timer?
    private var voiceMonitor: TeleprompterVoiceMonitor?
    private var voiceSession: UUID?
    private var voiceGate = TeleprompterVoiceGate()
    private var speechTask: Task<Void, Never>?
    private var stopSpeechSession: (() -> Void)?
    private var scriptMatcher: TeleprompterScriptMatcher?
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
            if let existing = self.panel {
                existing.sharingType = self.hideFromCapture ? .none : .readOnly
                existing.orderFrontRegardless()
                return
            }

            let targetScreen = screen ?? CaptureEngine.shared.resolveScreen(displayIndex: nil)
            let width: CGFloat = 500
            let height: CGFloat = 248
            let origin = CGPoint(
                x: targetScreen.frame.midX - width / 2,
                y: targetScreen.visibleFrame.maxY - height - 10
            )

            let panel = KeyableHUDPanel(
                contentRect: CGRect(origin: origin, size: CGSize(width: width, height: height)),
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
            panel.sharingType = self.hideFromCapture ? .none : .readOnly

            let hosting = NSHostingView(rootView: TeleprompterPanelView(controller: self))
            panel.contentView = hosting
            panel.invalidateShadow()
            panel.orderFrontRegardless()
            self.panel = panel
        }
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
            reachedEnd = false
        }
        isPlaying = true
        isEditingScript = false
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
        if next >= 1 {
            reachedEnd = true
            pause()
        }
    }

    public func pause() {
        isPlaying = false
        scrollTimer?.invalidate()
        scrollTimer = nil
        voiceSession = nil
        voiceMonitor?.stop()
        voiceMonitor = nil
        speechTask?.cancel()
        speechTask = nil
        stopSpeechSession?()
        stopSpeechSession = nil
        scriptMatcher = nil
        nextSpokenWord = nil
        voiceGate = TeleprompterVoiceGate()
        voiceStatus = .idle
    }

    public func reset() {
        pause()
        reachedEnd = false
        scriptAnchor = nil
        scrollProgress = 0.0
    }

    func rewind() {
        pause()
        reachedEnd = false
        scrollProgress = scriptLayout.rewind(progress: scrollProgress, anchor: scriptAnchor)
        scriptAnchor = nil
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
            if #available(macOS 26, *) {
                startScriptTracking(session: session)
            } else {
                failVoiceScroll("Follow Script needs macOS 26. Choose Voice or Timed to continue.")
            }
        } else {
            openVoiceMonitor(session: session)
        }
    }

    @available(macOS 26, *)
    private func startScriptTracking(session: UUID) {
        speechTask = Task { @MainActor [weak self] in
            guard let self, self.voiceSession == session else { return }
            let speech = TeleprompterSpeechSession()
            self.stopSpeechSession = { speech.stop() }
            let offset = self.scriptAnchor ?? self.scriptLayout.character(at: self.scrollProgress)
            self.scriptMatcher = TeleprompterScriptMatcher(script: self.scriptText, at: offset)
            self.nextSpokenWord = self.stageDirection(at: self.readingProgress) == nil
                ? self.scriptMatcher?.nextSpokenWord : nil
            do {
                try await speech.start { [weak self] phrase, isFinal in
                    guard let self, self.voiceSession == session,
                          self.stageDirection(at: self.readingProgress) == nil,
                          let position = self.scriptMatcher?.advance(with: phrase, isFinal: isFinal) else { return }
                    self.scriptAnchor = position
                    self.nextSpokenWord = self.stageDirection(at: self.readingProgress) == nil
                        ? self.scriptMatcher?.nextSpokenWord : nil
                } onFailure: { [weak self] in
                    guard let self, self.voiceSession == session else { return }
                    self.failVoiceScroll("Speech tracking stopped. Press Scroll to try again.")
                }
                if self.voiceSession == session { self.voiceStatus = .waiting }
            } catch {
                guard self.voiceSession == session else { return }
                self.failVoiceScroll("Couldn't start Follow Script. Check your microphone or choose Voice.")
            }
        }
    }

    private func openVoiceMonitor(session: UUID) {
        let monitor = TeleprompterVoiceMonitor { [weak self] time in
            guard let self, self.voiceSession == session else { return }
            self.voiceGate.noteSpeech(at: time)
        } onFailure: { [weak self] in
            guard let self, self.voiceSession == session else { return }
            self.failVoiceScroll("Microphone changed or stopped. Press Scroll to try again.")
        }

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

private struct TeleprompterPanelView: View {
    @ObservedObject var controller: TeleprompterController

    private var statusText: String {
        switch controller.voiceStatus {
        case .idle:
            return "\(controller.wordCount)w · \(Int(controller.wordsPerMinute)) WPM"
        case .starting:
            return "Starting mic…"
        case .waiting:
            return controller.scrollMode == .followScript ? "Following script" : "Waiting for speech"
        case .speaking:
            return "Voice activity"
        case .stageDirection:
            return "Stage direction"
        case .unavailable:
            return "Voice unavailable"
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            // Top bar: notch-aligned camera indicator + privacy badge
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
                        Text(controller.hideFromCapture ? "Invisible on Recording" : "Visible on Recording")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(controller.hideFromCapture ? Color.green : Color.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
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
                .help("Change teleprompter visibility between takes")

                Spacer()

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
                        nextSpokenWord: controller.nextSpokenWord
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
                        .fill(Color.black.opacity(0.38))
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
                        Text(controller.isEditingScript ? "Done" : "Edit Script")
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
        .padding(12)
        .raycastLiquidGlass(cornerRadius: 16, tintAlpha: 0.86)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Floating Picture-in-Picture Camera Bubble

public enum CameraBubbleShape: String, Codable, CaseIterable, Sendable {
    case circle
    case squircle
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

public final class CameraBubbleController: ObservableObject {
    public static let shared = CameraBubbleController()

    @Published public var isVisible: Bool = false
    @Published public var shape: CameraBubbleShape = .circle {
        didSet { updatePanelSize() }
    }
    @Published public var bubbleSize: CameraBubbleSize = .medium {
        didSet { updatePanelSize() }
    }
    @Published public var isMirrored: Bool = true
    @Published public private(set) var cameraAuthorized: Bool = false
    @Published public private(set) var hasLiveCameraFeed: Bool = false
    @Published private(set) var cameraError: String?

    private var panel: NSPanel?
    // The main queue owns the preview reference and request token. The session
    // queue owns starting and stopping the capture session.
    private var previewSession: AVCaptureSession?
    private var captureSession: AVCaptureSession?
    private var captureDeviceID: String?
    private var cameraRequest = UUID()
    private var disconnectObserver: NSObjectProtocol?
    private let sessionQueue = DispatchQueue(label: "com.catchapp.camerabubble")

    public init() {
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, self.isVisible, let device = notification.object as? AVCaptureDevice,
                  self.previewSession?.inputs.contains(where: { ($0 as? AVCaptureDeviceInput)?.device.uniqueID == device.uniqueID }) == true else { return }
            self.stopCamera()
            self.cameraError = "\(device.localizedName) disconnected. Choose a camera in Studio."
        }
    }

    deinit {
        if let disconnectObserver { NotificationCenter.default.removeObserver(disconnectObserver) }
    }

    public func show(on screen: NSScreen? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isVisible = true
            if let existing = self.panel {
                self.updatePanelSize()
                existing.orderFrontRegardless()
                self.startCameraIfAuthorized()
                return
            }

            let targetScreen = screen ?? CaptureEngine.shared.resolveScreen(displayIndex: nil)
            let dim = self.bubbleSize.dimension
            let origin = CGPoint(
                x: targetScreen.visibleFrame.minX + 24,
                y: targetScreen.visibleFrame.minY + 24
            )
            let panel = NSPanel(
                contentRect: CGRect(origin: origin, size: CGSize(width: dim, height: dim)),
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
            // Keep camera bubble visible in recordings just like Loom
            panel.sharingType = .readOnly

            let hosting = NSHostingView(rootView: CameraBubbleView(controller: self))
            hosting.sizingOptions = []
            hosting.frame = CGRect(origin: .zero, size: CGSize(width: dim, height: dim))
            panel.contentView = hosting
            panel.invalidateShadow()
            panel.orderFrontRegardless()
            self.panel = panel
            self.startCameraIfAuthorized()
        }
    }

    public func hide() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isVisible = false
            self.stopCamera()
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

    public func cycleSize() {
        switch bubbleSize {
        case .small: bubbleSize = .medium
        case .medium: bubbleSize = .large
        case .large: bubbleSize = .small
        }
    }

    public func toggleShape() {
        shape = (shape == .circle) ? .squircle : .circle
    }

    private func updatePanelSize() {
        guard let panel else { return }
        let dim = bubbleSize.dimension
        let old = panel.frame
        let updated = CGRect(x: old.origin.x, y: old.origin.y, width: dim, height: dim)
        panel.setFrame(updated, display: true, animate: true)
        panel.contentView?.frame = CGRect(origin: .zero, size: CGSize(width: dim, height: dim))
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
        let selectedID = SettingsStore.shared.recordingCameraID
        hasLiveCameraFeed = false
        previewSession = nil
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                guard let device = StudioCaptureDevices.resolve(selectedID, mediaType: .video) else {
                    self.captureSession?.stopRunning()
                    self.captureSession = nil
                    throw CameraStartError.unavailable
                }
                if let existing = self.captureSession, self.captureDeviceID == device.uniqueID, existing.isRunning {
                    self.publishCamera(existing, error: nil, request: request)
                    return
                }
                self.captureSession?.stopRunning()
                self.captureSession = nil
                let input = try AVCaptureDeviceInput(device: device)
                let session = AVCaptureSession()
                guard session.canAddInput(input) else { throw CameraStartError.unavailable }
                session.addInput(input)
                if session.canSetSessionPreset(.medium) { session.sessionPreset = .medium }
                session.startRunning()
                guard session.isRunning else { throw CameraStartError.unavailable }
                self.captureSession = session
                self.captureDeviceID = device.uniqueID
                self.publishCamera(session, error: nil, request: request)
            } catch {
                self.publishCamera(nil, error: "Camera could not start: \(error.localizedDescription)", request: request)
            }
        }
    }

    private enum CameraStartError: LocalizedError {
        case unavailable
        var errorDescription: String? { "The selected camera is unavailable." }
    }

    private func publishCamera(_ session: AVCaptureSession?, error: String?, request: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.cameraRequest == request, self.isVisible else { return }
            self.previewSession = session
            self.hasLiveCameraFeed = session != nil
            self.cameraError = error
        }
    }

    private func stopCamera() {
        cameraRequest = UUID()
        previewSession = nil
        hasLiveCameraFeed = false
        sessionQueue.async { [weak self] in
            self?.captureSession?.stopRunning()
            self?.captureSession = nil
        }
    }

    fileprivate var activeSession: AVCaptureSession? {
        previewSession
    }
}

private struct CameraBubbleView: View {
    @ObservedObject var controller: CameraBubbleController
    @State private var isHovered = false

    var body: some View {
        let dim = controller.bubbleSize.dimension
        let radius: CGFloat = controller.shape == .circle ? dim / 2 : 28

        ZStack {
            if controller.hasLiveCameraFeed, let session = controller.activeSession {
                CameraPreviewLayerView(session: session, isMirrored: controller.isMirrored, cornerRadius: radius)
            } else {
                ZStack {
                    LinearGradient(
                        colors: [Color(red: 0.13, green: 0.16, blue: 0.24), Color(red: 0.08, green: 0.10, blue: 0.15)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    VStack(spacing: 6) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: dim * 0.34))
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
        .frame(width: dim, height: dim)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(RaycastTheme.specularGradient, lineWidth: 2)
        )
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
                        Image(systemName: controller.shape == .circle ? "square.dashed" : "circle")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(Circle().fill(Color.white.opacity(0.18)))
                    }
                    .buttonStyle(.plain)

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

private struct CameraPreviewLayerView: NSViewRepresentable {
    let session: AVCaptureSession
    let isMirrored: Bool
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> CameraPreviewNSView {
        let view = CameraPreviewNSView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.updateMirroring(isMirrored)
        view.updateCornerRadius(cornerRadius)
        return view
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        if nsView.previewLayer.session !== session {
            nsView.previewLayer.session = session
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
}

public final class ScreenRecordingStudio: NSObject, ObservableObject, @unchecked Sendable {
    public static let shared = ScreenRecordingStudio()

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
    @Published public var captureMode: RecordingAreaMode = .fullscreen
    @Published public var selectedRect: CGRect?
    @Published public var includeMicrophone: Bool = true
    @Published public var includeSystemAudio: Bool = SettingsStore.shared.recordingRecordSystemAudio
    @Published public var showCameraBubble: Bool = true
    @Published public var showTeleprompter: Bool = true
    @Published public private(set) var elapsedSeconds: Int = 0
    @Published public private(set) var lastRecordedVideoURL: URL?
    @Published public var recordingError: String?
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
    private var activeOutputURL: URL?
    private var sessionStarted = false
    private var recordedDimensions: CGSize = CGSize(width: 1280, height: 720)
    private var frameCounter: Int64 = 0
    private var streamFailure: String?
    private var writerAcceptingSamples = false
    private var pausedAtHostTime: CMTime?
    private var removedPauseDuration: CMTime = .zero

    public func presentStudio(initialRect: CGRect? = nil, displayIndex: Int? = nil, showPresenterOverlays: Bool = true) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let initialRect {
                self.captureMode = .area
                self.selectedRect = initialRect
            }
            let screen = CaptureEngine.shared.resolveScreen(displayIndex: displayIndex)

            if showPresenterOverlays && self.showCameraBubble {
                CameraBubbleController.shared.show(on: screen)
            }
            if showPresenterOverlays && self.showTeleprompter {
                TeleprompterController.shared.show(on: screen)
            }

            if let existing = self.controlBarPanel {
                existing.orderFrontRegardless()
                return
            }

            let width: CGFloat = min(760, screen.visibleFrame.width)
            let height: CGFloat = 94
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
        state = .preparing
        elapsedSeconds = 0
        accumulatedElapsed = 0
        syntheticTake = headlessSynthetic
        if !headlessSynthetic { LocalStudioBridge.shared.snapshotForTake() }

        let dir = outputDirectory ?? HistoryStore.shared.rootDirectory.appendingPathComponent("Recordings", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            recordingError = "Could not create the recording folder: \(error.localizedDescription)"
            state = .idle
            return
        }
        let fileName = FileNameFormatter.format(pattern: SettingsStore.shared.fileNameFormat)
        let outputURL = dir.appendingPathComponent("\(fileName)-\(UUID().uuidString.prefix(6)).mp4")
        let wantsMicrophone = includeMicrophone
        let selectedMicrophoneID = SettingsStore.shared.recordingMicrophoneID

        Task {
            let started: Bool
            if headlessSynthetic {
                await prepareFallbackWriter(to: outputURL)
                started = assetWriter != nil
            } else {
                let microphoneID = wantsMicrophone ? await prepareMicrophone(selectedID: selectedMicrophoneID) : nil
                if wantsMicrophone && microphoneID == nil {
                    started = false
                } else {
                    started = await startScreenCaptureKitRecording(to: outputURL, microphoneID: microphoneID)
                }
            }

            await MainActor.run {
                if self.state == .finishing {
                    Task {
                        if let stream = self.scStream { try? await stream.stopCapture() }
                        self.scStream = nil
                        self.writerQueue.sync { self.assetWriter?.cancelWriting(); self.assetWriter = nil }
                        try? FileManager.default.removeItem(at: outputURL)
                        await MainActor.run {
                            self.state = .idle
                            self.preparingStopCompletion?(nil, nil)
                            self.preparingStopCompletion = nil
                        }
                    }
                    return
                }
                guard started else {
                    self.writerQueue.sync { self.assetWriter?.cancelWriting(); self.assetWriter = nil }
                    try? FileManager.default.removeItem(at: outputURL)
                    if self.recordingError == nil { self.recordingError = "Screen recording could not start. Check Screen Recording permission and try again." }
                    self.state = .idle
                    return
                }
                self.writerQueue.sync { self.writerAcceptingSamples = true }
                self.activeOutputURL = outputURL
                self.activeRecordingStart = Date()
                self.state = .recording(startedAt: Date())
                self.startElapsedTimer()
            }
        }
    }

    private func prepareMicrophone(selectedID: String?) async -> String? {
        guard #available(macOS 15.0, *) else {
            await MainActor.run { self.recordingError = "Microphone recording requires macOS 15 or later." }
            return nil
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

    public func pauseRecording() {
        guard case .recording = state else { return }
        if let start = activeRecordingStart {
            accumulatedElapsed += Date().timeIntervalSince(start)
        }
        activeRecordingStart = nil
        writerQueue.sync {
            writerAcceptingSamples = false
            pausedAtHostTime = CMClockGetTime(CMClockGetHostTimeClock())
        }
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        state = .paused(elapsed: accumulatedElapsed)
    }

    public func resumeRecording() {
        guard case .paused = state else { return }
        writerQueue.sync {
            if let pausedAtHostTime {
                removedPauseDuration = CMTimeAdd(removedPauseDuration, CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), pausedAtHostTime))
            }
            pausedAtHostTime = nil
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
        let outputURL = activeOutputURL
        let fps = max(15, SettingsStore.shared.recordingFrameRate)
        let size = recordedDimensions

        Task {
            if let capturedStream {
                try? await capturedStream.stopCapture()
            }

            let succeeded: Bool
            if let outputURL {
                succeeded = await finalizeWriter(outputURL: outputURL, fallbackSize: size, fps: fps)
            } else {
                succeeded = false
            }

            let finalURL = succeeded ? outputURL : nil
            var historyItem: CaptureHistoryItem?
            if let finalURL,
               let videoData = try? Data(contentsOf: finalURL),
               !videoData.isEmpty {
                let poster = Self.generatePosterImage(from: finalURL, fallbackSize: size)
                let title = finalURL.deletingPathExtension().lastPathComponent
                historyItem = historyStore.recordCapture(
                    image: poster,
                    imageData: videoData,
                    title: title,
                    mediaType: .video,
                    fileExtension: "mp4"
                )
                if presentQuickAccess {
                    TakeReviewWindowController.shared.show(url: finalURL)
                }
            }

            let createdItem = historyItem
            await MainActor.run {
                self.lastRecordedVideoURL = finalURL
                if let finalURL, !self.syntheticTake {
                    do { try LocalStudioBridge.shared.saveHandoff(for: finalURL) }
                    catch { self.recordingError = "The video was saved, but its edit handoff could not be written: \(error.localizedDescription)" }
                }
                self.activeOutputURL = nil
                if !succeeded { self.recordingError = "Recording did not produce a valid video. No take was added to History." }
                self.state = .idle
                completion?(finalURL, createdItem)
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

    private func startScreenCaptureKitRecording(to outputURL: URL, microphoneID: String?) async -> Bool {
        guard CGPreflightScreenCaptureAccess() else {
            await MainActor.run { self.recordingError = "Screen Recording permission is required. Allow Catch in System Settings and restart it." }
            return false
        }
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

    private func setupAssetWriter(to outputURL: URL, width: Int, height: Int, includeAudio: Bool, includeMicrophone: Bool = false) -> Bool {
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
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 128_000
                ]
                let candidate = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                candidate.expectsMediaDataInRealTime = true
                guard writer.canAdd(candidate) else { return false }
                writer.add(candidate)
                aInput = candidate
            }

            var micInput: AVAssetWriterInput?
            if includeMicrophone {
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 96_000
                ]
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
            self.sessionStarted = false
            self.frameCounter = 0
            self.streamFailure = nil
            self.writerAcceptingSamples = false
            self.pausedAtHostTime = nil
            self.removedPauseDuration = .zero
            self.recordedDimensions = CGSize(width: width, height: height)
            return true
        }
    }

    fileprivate func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        writerQueue.async { [weak self] in
            guard let self,
                  let writer = self.assetWriter,
                  self.writerAcceptingSamples,
                  let sampleBuffer = Self.removingPause(self.removedPauseDuration, from: sampleBuffer) else { return }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if !self.sessionStarted {
                guard type == .screen else { return }
                writer.startWriting()
                writer.startSession(atSourceTime: pts)
                self.sessionStarted = true
            }

            switch type {
            case .screen:
                if let vInput = self.videoInput, vInput.isReadyForMoreMediaData {
                    if vInput.append(sampleBuffer) {
                        self.frameCounter += 1
                    } else {
                        self.streamFailure = writer.error?.localizedDescription ?? "Video writer rejected a frame."
                    }
                }
            case .audio:
                if let aInput = self.audioInput, aInput.isReadyForMoreMediaData {
                    if !aInput.append(sampleBuffer) {
                        self.streamFailure = writer.error?.localizedDescription ?? "Audio writer rejected a sample."
                    }
                }
            default:
                if #available(macOS 15.0, *), type == .microphone,
                   let input = self.microphoneInput, input.isReadyForMoreMediaData {
                    if input.append(sampleBuffer) {
                        self.microphoneSamples += 1
                    } else {
                        self.streamFailure = writer.error?.localizedDescription ?? "Microphone writer rejected a sample."
                    }
                }
            }
        }
    }

    fileprivate func streamStopped(with error: Error) {
        writerQueue.async { [weak self] in
            self?.streamFailure = error.localizedDescription
            DispatchQueue.main.async {
                guard let self, self.state.isActive else { return }
                self.stopRecording(presentQuickAccess: false) { _, _ in
                    DispatchQueue.main.async {
                        self.recordingError = "Screen capture stopped unexpectedly: \(error.localizedDescription). The take was not added to History."
                    }
                }
            }
        }
    }

    private static func removingPause(_ offset: CMTime, from sample: CMSampleBuffer) -> CMSampleBuffer? {
        guard CMTimeCompare(offset, .zero) > 0 else { return sample }
        var count = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr, count > 0 else { return nil }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count) == noErr else { return nil }
        for index in timings.indices {
            timings[index].presentationTimeStamp = CMTimeSubtract(timings[index].presentationTimeStamp, offset)
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = CMTimeSubtract(timings[index].decodeTimeStamp, offset)
            }
        }
        var adjusted: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: count, sampleTimingArray: &timings, sampleBufferOut: &adjusted) == noErr else { return nil }
        return adjusted
    }

    private func finalizeWriter(outputURL: URL, fallbackSize: CGSize, fps: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            writerQueue.async { [weak self] in
                guard let self, let writer = self.assetWriter else {
                    continuation.resume(returning: false)
                    return
                }

                // Synthetic frames are reserved for the explicit fixture path.
                if self.syntheticTake && !self.sessionStarted,
                   let vInput = self.videoInput,
                   let adaptor = self.pixelAdaptor {
                    writer.startWriting()
                    writer.startSession(atSourceTime: .zero)
                    self.sessionStarted = true

                    let width = Int(fallbackSize.width)
                    let height = Int(fallbackSize.height)
                    let timescale = CMTimeScale(max(15, fps))
                    for frameIndex in 0..<5 {
                        if let pb = Self.makeSolidPixelBuffer(width: width, height: height) {
                            while !vInput.isReadyForMoreMediaData {
                                Thread.sleep(forTimeInterval: 0.005)
                            }
                            let time = CMTime(value: CMTimeValue(frameIndex), timescale: timescale)
                            adaptor.append(pb, withPresentationTime: time)
                        }
                    }
                }

                guard self.sessionStarted, self.streamFailure == nil,
                      self.syntheticTake || (self.frameCounter > 0 && (self.microphoneInput == nil || self.microphoneSamples > 0)) else {
                    writer.cancelWriting()
                    self.assetWriter = nil
                    continuation.resume(returning: false)
                    return
                }
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                self.microphoneInput?.markAsFinished()

                writer.finishWriting {
                    self.assetWriter = nil
                    self.videoInput = nil
                    self.audioInput = nil
                    self.microphoneInput = nil
                    self.pixelAdaptor = nil
                    self.sessionStarted = false
                    continuation.resume(returning: writer.status == .completed)
                }
            }
        }
    }

    private static func makeSolidPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
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

private final class RecordingStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private weak var studio: ScreenRecordingStudio?

    init(studio: ScreenRecordingStudio) {
        self.studio = studio
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
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
        )) {
            Button("OK", role: .cancel) { studio.recordingError = nil }
        } message: {
            Text(studio.recordingError ?? "")
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
                }
                .pickerStyle(.segmented)
                .frame(width: 120)

                if studio.captureMode == .area {
                    Button("Select") {
                        studio.selectRecordingArea()
                    }
                    .controlSize(.small)
                }
            }

            // Camera Bubble Toggle
            Button {
                studio.showCameraBubble.toggle()
                if studio.showCameraBubble {
                    CameraBubbleController.shared.show()
                } else {
                    CameraBubbleController.shared.hide()
                }
            } label: {
                Image(systemName: studio.showCameraBubble ? "video.fill" : "video.slash.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(studio.showCameraBubble ? .white : RaycastTheme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(studio.showCameraBubble ? RaycastTheme.accent.opacity(0.75) : Color.white.opacity(0.08))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(studio.state != .idle)
            .help("Toggle Camera Bubble")

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
                Button("Clear Ink") { StudioInkOverlay.shared.clear() }
                    .help("Hold Option-Shift-Command-D to draw")
                    .controlSize(.small)
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
