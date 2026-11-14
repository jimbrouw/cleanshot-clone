import AppKit
import Carbon

/// A temporary, click-through-when-released ink layer for the recorded display.
final class StudioInkOverlay {
    static let shared = StudioInkOverlay()
    private var panel: NSPanel?
    private var canvas: InkCanvas?
    private var watchdog: Timer?

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.clear() }
    }

    func begin() {
        guard ScreenRecordingStudio.shared.state.isActive else { return }
        let screen = CaptureEngine.shared.resolveScreen(displayIndex: nil)
        if panel == nil || panel?.screen != screen {
            clear()
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.sharingType = .readOnly
            let canvas = InkCanvas(frame: NSRect(origin: .zero, size: screen.frame.size))
            panel.contentView = canvas
            self.panel = panel
            self.canvas = canvas
        }
        panel?.ignoresMouseEvents = false
        panel?.orderFrontRegardless()
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            let flags = CGEventSource.flagsState(.combinedSessionState)
            let required: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift]
            if !CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_ANSI_D)) || !flags.contains(required) {
                self?.end()
            }
        }
    }

    func end() {
        // Restore pointer input even while the last marks are fading.
        panel?.ignoresMouseEvents = true
        canvas?.finishStroke()
        watchdog?.invalidate()
        watchdog = nil
    }

    func clear() {
        watchdog?.invalidate()
        watchdog = nil
        panel?.ignoresMouseEvents = true
        panel?.orderOut(nil)
        panel = nil
        canvas = nil
    }
}

private final class InkCanvas: NSView {
    private struct Stroke { var points: [NSPoint]; var ended: Date? }
    private var strokes: [Stroke] = []
    private var fadeTimer: Timer?
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        strokes.append(Stroke(points: [convert(event.locationInWindow, from: nil)], ended: nil))
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard !strokes.isEmpty else { return }
        strokes[strokes.count - 1].points.append(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { finishStroke() }
    func finishStroke() {
        guard !strokes.isEmpty, strokes[strokes.count - 1].ended == nil else { return }
        strokes[strokes.count - 1].ended = Date()
        if fadeTimer == nil {
            fadeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                self.strokes.removeAll { $0.ended.map { Date().timeIntervalSince($0) > 3 } ?? false }
                self.needsDisplay = true
                if self.strokes.isEmpty { timer.invalidate(); self.fadeTimer = nil }
            }
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        for stroke in strokes where !stroke.points.isEmpty {
            let age = stroke.ended.map { Date().timeIntervalSince($0) } ?? 0
            let alpha = max(0, min(1, 3 - age))
            NSColor.systemRed.withAlphaComponent(alpha).setStroke()
            let path = NSBezierPath()
            path.lineWidth = 5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: stroke.points[0])
            for point in stroke.points.dropFirst() { path.line(to: point) }
            path.stroke()
        }
    }
}
