import Foundation
import AppKit

public final class SelectionOverlayController {
    public static let shared = SelectionOverlayController()

    private var overlayWindow: SelectionOverlayWindow?

    public func beginAreaSelection(
        on screen: NSScreen,
        frozenImage: CGImage?,
        initialRect: CGRect? = nil,
        completion: @escaping (CGRect?, Bool) -> Void
    ) {
        DispatchQueue.main.async {
            self.overlayWindow?.orderOut(nil)
            let win = SelectionOverlayWindow(screen: screen, frozenImage: frozenImage, initialRect: initialRect) { rect, shiftPressed in
                self.overlayWindow = nil
                completion(rect, shiftPressed)
            }
            self.overlayWindow = win
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private final class SelectionOverlayWindow: NSWindow {
    private let completion: (CGRect?, Bool) -> Void

    init(screen: NSScreen, frozenImage: CGImage?, initialRect: CGRect?, completion: @escaping (CGRect?, Bool) -> Void) {
        self.completion = completion
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        self.level = .screenSaver
        self.isOpaque = false
        self.backgroundColor = .clear
        self.acceptsMouseMovedEvents = true
        self.hasShadow = false
        self.isReleasedWhenClosed = false

        let view = SelectionOverlayView(
            frame: CGRect(origin: .zero, size: screen.frame.size),
            screenFrame: screen.frame,
            frozenImage: frozenImage,
            initialRect: initialRect
        ) { [weak self] rect, shift in
            self?.orderOut(nil)
            self?.completion(rect, shift)
        }
        self.contentView = view
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class SelectionOverlayView: NSView {
    private let screenFrame: CGRect
    private let frozenImage: CGImage?
    private let onComplete: (CGRect?, Bool) -> Void

    private var dragStart: CGPoint?
    private var currentMouse: CGPoint = .zero
    private var selectionRect: CGRect?
    private var trackingAreaRef: NSTrackingArea?

    init(frame: CGRect, screenFrame: CGRect, frozenImage: CGImage?, initialRect: CGRect?, onComplete: @escaping (CGRect?, Bool) -> Void) {
        self.screenFrame = screenFrame
        self.frozenImage = frozenImage
        self.onComplete = onComplete
        super.init(frame: frame)
        if let initialRect {
            self.selectionRect = CGRect(
                x: initialRect.minX - screenFrame.minX,
                y: initialRect.minY - screenFrame.minY,
                width: initialRect.width,
                height: initialRect.height
            )
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onComplete(nil, false)
        } else if event.keyCode == 36, let rect = selectionRect { // Return confirms previous selection
            let global = rect.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY)
            onComplete(global, event.modifierFlags.contains(.shift))
        }
    }

    override func mouseMoved(with event: NSEvent) {
        currentMouse = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        currentMouse = dragStart!
        selectionRect = CGRect(origin: dragStart!, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let pt = convert(event.locationInWindow, from: nil)
        currentMouse = pt
        var width = abs(pt.x - start.x)
        var height = abs(pt.y - start.y)
        if event.modifierFlags.contains(.option) {
            // Option locks 1:1 square aspect ratio while dragging
            let side = max(width, height)
            width = side
            height = side
        }
        let originX = pt.x >= start.x ? start.x : start.x - width
        let originY = pt.y >= start.y ? start.y : start.y - height
        selectionRect = CGRect(x: originX, y: originY, width: width, height: height)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let rect = selectionRect, rect.width >= 4, rect.height >= 4 else {
            onComplete(nil, false)
            return
        }
        let global = rect.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY)
        onComplete(global, event.modifierFlags.contains(.shift))
    }

    override func draw(_ dirtyRect: NSRect) {
        if let frozenImage, let ctx = NSGraphicsContext.current?.cgContext {
            ctx.draw(frozenImage, in: bounds)
        }

        // Dim overlay
        NSColor.black.withAlphaComponent(0.32).setFill()
        let dimPath = NSBezierPath(rect: bounds)
        if let sel = selectionRect, sel.width > 1, sel.height > 1 {
            dimPath.appendRect(sel)
            dimPath.windingRule = .evenOdd
        }
        dimPath.fill()

        // Crosshair hairlines
        let settings = SettingsStore.shared
        if settings.crosshairMode == .enabled {
            NSColor.white.withAlphaComponent(0.75).setStroke()
            let hLine = NSBezierPath()
            hLine.move(to: CGPoint(x: 0, y: currentMouse.y))
            hLine.line(to: CGPoint(x: bounds.width, y: currentMouse.y))
            hLine.lineWidth = 1
            hLine.stroke()

            let vLine = NSBezierPath()
            vLine.move(to: CGPoint(x: currentMouse.x, y: 0))
            vLine.line(to: CGPoint(x: currentMouse.x, y: bounds.height))
            vLine.lineWidth = 1
            vLine.stroke()
        }

        // Selection border & dimension badge
        if let sel = selectionRect, sel.width > 1, sel.height > 1 {
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: sel)
            border.lineWidth = 1.5
            border.stroke()

            let dimText = "\(Int(sel.width)) × \(Int(sel.height))"
            drawBadge(text: dimText, near: CGPoint(x: sel.maxX + 8, y: sel.minY - 26))
        }

        // Magnifier loupe when Crosshair + Show Magnifier enabled
        if settings.crosshairMode == .enabled && settings.showMagnifier, let frozenImage {
            drawMagnifier(at: currentMouse, frozenImage: frozenImage)
        }
    }

    private func drawBadge(text: String, near point: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let box = CGRect(
            x: min(bounds.width - size.width - 20, max(8, point.x)),
            y: min(bounds.height - size.height - 16, max(8, point.y)),
            width: size.width + 14,
            height: size.height + 8
        )
        NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        (text as NSString).draw(at: CGPoint(x: box.minX + 7, y: box.minY + 4), withAttributes: attrs)
    }

    private func drawMagnifier(at point: CGPoint, frozenImage: CGImage) {
        let loupeSize: CGFloat = 96
        let offset = CGPoint(x: 20, y: 20)
        let loupeRect = CGRect(
            x: min(bounds.width - loupeSize - 12, point.x + offset.x),
            y: min(bounds.height - loupeSize - 12, point.y + offset.y),
            width: loupeSize,
            height: loupeSize
        )
        let scale = CGFloat(frozenImage.width) / max(1, bounds.width)
        let sampleSize: CGFloat = 16 * scale
        let sampleRect = CGRect(
            x: max(0, point.x * scale - sampleSize / 2),
            y: max(0, (bounds.height - point.y) * scale - sampleSize / 2),
            width: sampleSize,
            height: sampleSize
        )
        guard let patch = frozenImage.cropping(to: sampleRect),
              let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.saveGState()
        let clip = CGPath(ellipseIn: loupeRect, transform: nil)
        ctx.addPath(clip)
        ctx.clip()
        ctx.interpolationQuality = .none
        ctx.draw(patch, in: loupeRect)
        ctx.restoreGState()

        NSColor.white.setStroke()
        let ring = NSBezierPath(ovalIn: loupeRect)
        ring.lineWidth = 2
        ring.stroke()
    }
}
