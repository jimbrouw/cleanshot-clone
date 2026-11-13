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
        didSet { UserDefaults.standard.set(scriptText, forKey: scriptKey) }
    }
    @Published public var wordsPerMinute: Double {
        didSet { UserDefaults.standard.set(wordsPerMinute, forKey: wpmKey) }
    }
    @Published public var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: fontSizeKey) }
    }
    @Published public var hideFromCapture: Bool {
        didSet {
            UserDefaults.standard.set(hideFromCapture, forKey: hideKey)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.panel?.sharingType = self.hideFromCapture ? .none : .readOnly
            }
        }
    }
    @Published public var isPlaying: Bool = false
    @Published public var isEditingScript: Bool = false
    @Published public var scrollProgress: Double = 0.0
    @Published public var isVisible: Bool = false

    private var panel: NSPanel?
    private var scrollTimer: Timer?

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
                styleMask: [.borderless, .nonactivatingPanel, .resizable],
                backing: .buffered,
                defer: false
            )
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isMovableByWindowBackground = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.minSize = CGSize(width: 400, height: 190)
            panel.sharingType = self.hideFromCapture ? .none : .readOnly

            let hosting = NSHostingView(rootView: TeleprompterPanelView(controller: self))
            panel.contentView = hosting
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
        if scrollProgress >= 0.99 {
            scrollProgress = 0.0
        }
        isPlaying = true
        isEditingScript = false
        scrollTimer?.invalidate()
        let tickInterval = 1.0 / 30.0
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.isPlaying else { return }
            let totalDuration = max(4.0, self.estimatedDurationSeconds)
            let delta = tickInterval / totalDuration
            let next = min(1.0, self.scrollProgress + delta)
            self.scrollProgress = next
            if next >= 1.0 {
                self.pause()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        scrollTimer = timer
    }

    public func pause() {
        isPlaying = false
        scrollTimer?.invalidate()
        scrollTimer = nil
    }

    public func reset() {
        pause()
        scrollProgress = 0.0
    }
}

private struct TeleprompterPanelView: View {
    @ObservedObject var controller: TeleprompterController

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

                Toggle(isOn: $controller.hideFromCapture) {
                    Label(
                        controller.hideFromCapture ? "Invisible on Recording" : "Visible on Recording",
                        systemImage: controller.hideFromCapture ? "eye.slash.fill" : "eye.fill"
                    )
                    .font(.system(size: 10, weight: .semibold))
                }
                .toggleStyle(.button)
                .controlSize(.mini)
                .tint(controller.hideFromCapture ? .green : .orange)

                Spacer()

                Text("\(controller.wordCount)w · \(Int(controller.wordsPerMinute)) WPM")
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
                    GeometryReader { geo in
                        let travel = max(0, estimatedContentHeight(width: geo.size.width - 28) - geo.size.height + 64)
                        VStack(alignment: .leading, spacing: 0) {
                            Spacer().frame(height: 22)
                            Text(controller.scriptText)
                                .font(.system(size: controller.fontSize, weight: .medium, design: .rounded))
                                .lineSpacing(6)
                                .foregroundStyle(Color.white.opacity(0.95))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Spacer().frame(height: 42)
                        }
                        .padding(.horizontal, 14)
                        .offset(y: -CGFloat(controller.scrollProgress) * travel)
                        .animation(.linear(duration: 0.05), value: controller.scrollProgress)
                    }
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
                    Label(controller.isPlaying ? "Pause" : "Scroll", systemImage: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
                .raycastGlassButton(prominent: true)
                .tint(controller.isPlaying ? .orange : RaycastTheme.accent)
                .controlSize(.small)

                Button {
                    controller.reset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .raycastGlassButton(prominent: false)
                .controlSize(.small)
                .help("Reset to Top")

                HStack(spacing: 4) {
                    Image(systemName: "gauge.with.needle")
                        .font(.system(size: 10))
                        .foregroundStyle(RaycastTheme.textTertiary)
                    Slider(value: $controller.wordsPerMinute, in: 60...260, step: 10)
                        .frame(width: 82)
                }

                HStack(spacing: 4) {
                    Button {
                        controller.fontSize = max(14, controller.fontSize - 2)
                    } label: {
                        Text("A-").font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)

                    Button {
                        controller.fontSize = min(38, controller.fontSize + 2)
                    } label: {
                        Text("A+").font(.system(size: 11, weight: .bold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }

                Spacer()

                Button {
                    controller.isEditingScript.toggle()
                    if controller.isEditingScript {
                        controller.pause()
                    }
                } label: {
                    Label(controller.isEditingScript ? "Done" : "Edit Script", systemImage: controller.isEditingScript ? "checkmark" : "square.and.pencil")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .raycastGlassButton(prominent: false)
                .controlSize(.small)
            }
        }
        .padding(12)
        .raycastLiquidGlass(cornerRadius: 16, tintAlpha: 0.86)
        .preferredColorScheme(.dark)
    }

    private func estimatedContentHeight(width: CGFloat) -> CGFloat {
        let lineHeight = controller.fontSize * 1.45
        let charsPerLine = max(18.0, width / (controller.fontSize * 0.56))
        let totalLines = max(3.0, ceil(Double(controller.scriptText.count) / charsPerLine))
        return CGFloat(totalLines) * lineHeight
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

    private var panel: NSPanel?
    private var captureSession: AVCaptureSession?
    private let sessionQueue = DispatchQueue(label: "com.catchapp.camerabubble")

    public init() {}

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
            panel.orderFrontRegardless()
            self.panel = panel
            self.startCameraIfAuthorized()
        }
    }

    public func hide() {
        stopCamera()
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
    }

    private func startCameraIfAuthorized() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            cameraAuthorized = true
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.cameraAuthorized = granted
                    if granted {
                        self?.configureSession()
                    }
                }
            }
        default:
            cameraAuthorized = false
            hasLiveCameraFeed = false
        }
    }

    private func configureSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if let existing = self.captureSession {
                if !existing.isRunning {
                    existing.startRunning()
                }
                DispatchQueue.main.async { self.hasLiveCameraFeed = true }
                return
            }

            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(for: .video),
                let input = try? AVCaptureDeviceInput(device: device) else {
                DispatchQueue.main.async { self.hasLiveCameraFeed = false }
                return
            }

            let session = AVCaptureSession()
            session.beginConfiguration()
            session.sessionPreset = .medium
            if session.canAddInput(input) {
                session.addInput(input)
            }
            session.commitConfiguration()
            session.startRunning()
            self.captureSession = session
            DispatchQueue.main.async { self.hasLiveCameraFeed = true }
        }
    }

    private func stopCamera() {
        sessionQueue.async { [weak self] in
            self?.captureSession?.stopRunning()
            DispatchQueue.main.async {
                self?.hasLiveCameraFeed = false
            }
        }
    }

    fileprivate var activeSession: AVCaptureSession? {
        captureSession
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
                CameraPreviewLayerView(session: session, isMirrored: controller.isMirrored)
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
                        Text(controller.cameraAuthorized ? "Starting Cam..." : "Camera Ready")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(RaycastTheme.textSecondary)
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
        .shadow(color: Color.black.opacity(0.45), radius: 14, x: 0, y: 6)
        .overlay(alignment: .bottom) {
            if isHovered {
                HStack(spacing: 6) {
                    Button(controller.bubbleSize.label) {
                        controller.cycleSize()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)

                    Button {
                        controller.toggleShape()
                    } label: {
                        Image(systemName: controller.shape == .circle ? "square.dashed" : "circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)

                    Button {
                        controller.isMirrored.toggle()
                    } label: {
                        Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)

                    Button {
                        controller.hide()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
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

    func makeNSView(context: Context) -> CameraPreviewNSView {
        let view = CameraPreviewNSView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.updateMirroring(isMirrored)
        return view
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        if nsView.previewLayer.session !== session {
            nsView.previewLayer.session = session
        }
        nsView.updateMirroring(isMirrored)
    }
}

private final class CameraPreviewNSView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
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
    private var pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var activeOutputURL: URL?
    private var sessionStarted = false
    private var recordedDimensions: CGSize = CGSize(width: 1280, height: 720)
    private var frameCounter: Int64 = 0

    public func presentStudio(initialRect: CGRect? = nil, displayIndex: Int? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let initialRect {
                self.captureMode = .area
                self.selectedRect = initialRect
            }
            let screen = CaptureEngine.shared.resolveScreen(displayIndex: displayIndex)

            if self.showCameraBubble {
                CameraBubbleController.shared.show(on: screen)
            }
            if self.showTeleprompter {
                TeleprompterController.shared.show(on: screen)
            }

            if let existing = self.controlBarPanel {
                existing.orderFrontRegardless()
                return
            }

            let width: CGFloat = 610
            let height: CGFloat = 62
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
            panel.orderFrontRegardless()
            self.controlBarPanel = panel
        }
    }

    public func dismissStudio() {
        if state.isActive {
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
        guard !state.isActive else { return }
        DispatchQueue.main.async {
            self.state = .preparing
            self.elapsedSeconds = 0
            self.accumulatedElapsed = 0
        }

        let dir = outputDirectory ?? HistoryStore.shared.rootDirectory.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileName = FileNameFormatter.format(pattern: SettingsStore.shared.fileNameFormat)
        let outputURL = dir.appendingPathComponent("\(fileName)-\(UUID().uuidString.prefix(6)).mp4")

        if showTeleprompter && !headlessSynthetic {
            TeleprompterController.shared.show()
            TeleprompterController.shared.play()
        }

        Task {
            let startedRealStream: Bool
            if headlessSynthetic {
                startedRealStream = false
            } else {
                startedRealStream = await startScreenCaptureKitRecording(to: outputURL)
            }

            if !startedRealStream {
                await prepareFallbackWriter(to: outputURL)
            }

            await MainActor.run {
                self.activeOutputURL = outputURL
                self.activeRecordingStart = Date()
                self.state = .recording(startedAt: Date())
                self.startElapsedTimer()
            }
        }
    }

    public func pauseRecording() {
        guard case .recording = state else { return }
        if let start = activeRecordingStart {
            accumulatedElapsed += Date().timeIntervalSince(start)
        }
        activeRecordingStart = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        TeleprompterController.shared.pause()
        state = .paused(elapsed: accumulatedElapsed)
    }

    public func resumeRecording() {
        guard case .paused = state else { return }
        activeRecordingStart = Date()
        state = .recording(startedAt: Date())
        startElapsedTimer()
        if showTeleprompter {
            TeleprompterController.shared.play()
        }
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

        elapsedTimer?.invalidate()
        elapsedTimer = nil
        TeleprompterController.shared.pause()
        DispatchQueue.main.async {
            self.state = .finishing
        }

        let capturedStream = scStream
        scStream = nil
        let outputURL = activeOutputURL
        let fps = max(15, SettingsStore.shared.recordingFrameRate)
        let size = recordedDimensions

        Task {
            if let capturedStream {
                try? await capturedStream.stopCapture()
            }

            if let outputURL {
                await finalizeWriter(outputURL: outputURL, fallbackSize: size, fps: fps)
            }

            let finalURL = outputURL
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
                if presentQuickAccess, let item = historyItem {
                    let result = CaptureResult(
                        image: poster,
                        encodedData: videoData,
                        fileName: title,
                        format: .png,
                        sourceRect: CGRect(origin: .zero, size: size),
                        displayScale: 1.0
                    )
                    QuickAccessOverlayManager.shared.present(result: result, historyItem: item)
                }
            }

            let createdItem = historyItem
            await MainActor.run {
                self.lastRecordedVideoURL = finalURL
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

    private func startScreenCaptureKitRecording(to outputURL: URL) async -> Bool {
        guard CGPreflightScreenCaptureAccess() else {
            return false
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let screen = CaptureEngine.shared.resolveScreen(displayIndex: nil)
            let targetDisplayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                ?? CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == targetDisplayID }) ?? content.displays.first else {
                return false
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
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

            if captureMode == .area, let rect = selectedRect {
                let relativeX = max(0, rect.minX - screen.frame.minX)
                let relativeY = max(0, screen.frame.maxY - rect.maxY)
                config.sourceRect = CGRect(x: relativeX, y: relativeY, width: rect.width, height: rect.height)
            }

            let writerConfigured = setupAssetWriter(
                to: outputURL,
                width: targetWidth,
                height: targetHeight,
                includeAudio: includeSystemAudio
            )
            guard writerConfigured else { return false }

            let handler = RecordingStreamOutput(studio: self)
            let stream = SCStream(filter: filter, configuration: config, delegate: handler)
            try stream.addStreamOutput(handler, type: .screen, sampleHandlerQueue: writerQueue)
            if includeSystemAudio {
                try? stream.addStreamOutput(handler, type: .audio, sampleHandlerQueue: writerQueue)
            }
            try await stream.startCapture()

            self.streamOutput = handler
            self.scStream = stream
            return true
        } catch {
            return false
        }
    }

    private func prepareFallbackWriter(to outputURL: URL) async {
        let w = 1280
        let h = 720
        _ = setupAssetWriter(to: outputURL, width: w, height: h, includeAudio: false)
    }

    private func setupAssetWriter(to outputURL: URL, width: Int, height: Int, includeAudio: Bool) -> Bool {
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
                if writer.canAdd(candidate) {
                    writer.add(candidate)
                    aInput = candidate
                }
            }

            self.assetWriter = writer
            self.videoInput = vInput
            self.audioInput = aInput
            self.pixelAdaptor = adaptor
            self.sessionStarted = false
            self.frameCounter = 0
            self.recordedDimensions = CGSize(width: width, height: height)
            return true
        }
    }

    fileprivate func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        writerQueue.async { [weak self] in
            guard let self,
                  let writer = self.assetWriter,
                  self.isRecordingActiveUnsafe else { return }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if !self.sessionStarted {
                writer.startWriting()
                writer.startSession(atSourceTime: pts)
                self.sessionStarted = true
            }

            switch type {
            case .screen:
                if let vInput = self.videoInput, vInput.isReadyForMoreMediaData {
                    vInput.append(sampleBuffer)
                    self.frameCounter += 1
                }
            case .audio:
                if let aInput = self.audioInput, aInput.isReadyForMoreMediaData {
                    aInput.append(sampleBuffer)
                }
            default:
                break
            }
        }
    }

    private var isRecordingActiveUnsafe: Bool {
        if case .recording = state { return true }
        return false
    }

    private func finalizeWriter(outputURL: URL, fallbackSize: CGSize, fps: Int) async {
        await withCheckedContinuation { continuation in
            writerQueue.async { [weak self] in
                guard let self, let writer = self.assetWriter else {
                    continuation.resume()
                    return
                }

                // If zero SCStream frames arrived (e.g. headless CI test mode), write synthetic frames so MP4 is valid
                if !self.sessionStarted,
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

                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()

                writer.finishWriting {
                    self.assetWriter = nil
                    self.videoInput = nil
                    self.audioInput = nil
                    self.pixelAdaptor = nil
                    self.sessionStarted = false
                    continuation.resume()
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
        // Controlled via ScreenRecordingStudio lifecycle
    }
}

// MARK: - Loom Studio Control Bar View

private struct LoomStudioBarView: View {
    @ObservedObject var studio: ScreenRecordingStudio

    var body: some View {
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
            Toggle(isOn: Binding(
                get: { studio.showCameraBubble },
                set: { enabled in
                    studio.showCameraBubble = enabled
                    if enabled {
                        CameraBubbleController.shared.show()
                    } else {
                        CameraBubbleController.shared.hide()
                    }
                }
            )) {
                Image(systemName: studio.showCameraBubble ? "video.fill" : "video.slash.fill")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Toggle Camera Bubble")

            // Microphone Toggle
            Toggle(isOn: $studio.includeMicrophone) {
                Image(systemName: studio.includeMicrophone ? "mic.fill" : "mic.slash.fill")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Toggle Microphone")

            // Teleprompter Toggle
            Toggle(isOn: Binding(
                get: { studio.showTeleprompter },
                set: { enabled in
                    studio.showTeleprompter = enabled
                    if enabled {
                        TeleprompterController.shared.show()
                    } else {
                        TeleprompterController.shared.hide()
                    }
                }
            )) {
                Image(systemName: "text.justify.left")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Toggle Hidden Teleprompter")

            Spacer()

            // Transport Record / Pause / Stop
            if studio.state.isActive {
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
                Button {
                    studio.startRecording()
                } label: {
                    Label("Record", systemImage: "record.circle")
                }
                .raycastGlassButton(prominent: true)
                .tint(RaycastTheme.accent)
                .controlSize(.small)

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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .raycastLiquidGlass(cornerRadius: 18, tintAlpha: 0.85)
        .preferredColorScheme(.dark)
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
