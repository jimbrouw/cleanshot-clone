import Foundation
import AppKit
import Vision
import SwiftUI

public enum ScrollingStitcher {
    /// Stitches consecutive vertically scrolled frames into a single seamless tall image,
    /// detecting overlap via row-signature correlation and Vision translational registration.
    public static func stitchVertical(frames: [CGImage]) -> CGImage? {
        guard let first = frames.first else { return nil }
        if frames.count == 1 { return first }

        var strips: [(image: CGImage, cropTop: Int, cropBottom: Int)] = []
        strips.append((first, 0, first.height))

        for i in 1..<frames.count {
            let prev = frames[i - 1]
            let curr = frames[i]
            guard prev.width == curr.width else { continue }
            let shift = estimateVerticalScrollOffset(previous: prev, current: curr)
            if shift > 2 && shift < curr.height {
                strips.append((curr, curr.height - shift, curr.height))
            }
        }

        let totalHeight = strips.reduce(0) { $0 + ($1.cropBottom - $1.cropTop) }
        let width = first.width
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        guard totalHeight > 0,
              let ctx = CGContext(
                data: nil,
                width: width,
                height: totalHeight,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return first
        }

        // Draw from top to bottom in CGContext (bottom-left origin)
        var currentY = totalHeight
        for strip in strips {
            let sliceH = strip.cropBottom - strip.cropTop
            let cropRect = CGRect(x: 0, y: strip.cropTop, width: width, height: sliceH)
            if let cropped = strip.image.cropping(to: cropRect) {
                currentY -= sliceH
                ctx.draw(cropped, in: CGRect(x: 0, y: currentY, width: width, height: sliceH))
            }
        }
        return ctx.makeImage() ?? first
    }

    public static func estimateVerticalScrollOffset(previous: CGImage, current: CGImage) -> Int {
        // First try fast exact row-signature overlap matching (handles deterministic UI scrolls and sticky headers cleanly)
        if let rowOffset = matchByRowSignatures(previous: previous, current: current) {
            return rowOffset
        }

        // Fallback to Apple Vision translational registration
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: current)
        let handler = VNImageRequestHandler(cgImage: previous, options: [:])
        try? handler.perform([request])
        if let obs = request.results?.first as? VNImageTranslationAlignmentObservation {
            let dy = Int(round(abs(obs.alignmentTransform.ty)))
            if dy > 2 && dy < current.height {
                return dy
            }
        }
        return max(16, current.height / 3)
    }

    private static func matchByRowSignatures(previous: CGImage, current: CGImage) -> Int? {
        guard let prevRows = rowHashes(for: previous), let currRows = rowHashes(for: current) else { return nil }
        let h = min(prevRows.count, currRows.count)
        guard h > 32 else { return nil }

        // Skip any static top header (rows identical at index 0..k in both frames)
        var stickyTop = 0
        while stickyTop < h / 4 && prevRows[stickyTop] == currRows[stickyTop] {
            stickyTop += 1
        }
        // Skip any static bottom footer
        var stickyBottom = 0
        while stickyBottom < h / 4 && prevRows[h - 1 - stickyBottom] == currRows[h - 1 - stickyBottom] {
            stickyBottom += 1
        }

        let probeCount = min(16, max(6, (h - stickyTop - stickyBottom) / 6))
        let probeStart = stickyTop + max(4, (h - stickyTop - stickyBottom) / 3)
        guard probeStart + probeCount < h - stickyBottom else { return nil }

        let targetSlice = Array(currRows[stickyTop..<(stickyTop + probeCount)])
        var bestShift: Int?
        var bestMatches = 0

        for shift in 4..<(h - stickyTop - stickyBottom - probeCount) {
            let prevStart = stickyTop + shift
            guard prevStart + probeCount <= h - stickyBottom else { break }
            var matches = 0
            for k in 0..<probeCount {
                if prevRows[prevStart + k] == targetSlice[k] {
                    matches += 1
                }
            }
            if matches >= probeCount - 1 && matches > bestMatches {
                bestMatches = matches
                bestShift = shift
            }
        }
        return bestShift
    }

    private static func rowHashes(for image: CGImage) -> [UInt64]? {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0,
              let ctx = CGContext(
                data: nil,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let ptr = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }

        var hashes = [UInt64](repeating: 0, count: h)
        let strideStep = max(1, w / 64)
        for y in 0..<h {
            var hash: UInt64 = 14695981039346656037
            let rowOffset = y * w * 4
            for x in stride(from: 0, to: w, by: strideStep) {
                let idx = rowOffset + x * 4
                let val = UInt64(ptr[idx]) ^ (UInt64(ptr[idx + 1]) << 8) ^ (UInt64(ptr[idx + 2]) << 16)
                hash ^= val
                hash = hash &* 1099511628211
            }
            hashes[y] = hash
        }
        return hashes
    }
}

public final class ScrollingCaptureController {
    public static let shared = ScrollingCaptureController()

    private var controlPanel: NSPanel?
    private var capturedFrames: [CGImage] = []
    private var scrollTimer: Timer?
    private var isCapturing = false
    private var targetRect: CGRect = .zero
    private var targetScreen: NSScreen?

    public func beginScrollingCapture(
        rect: CGRect? = nil,
        displayIndex: Int? = nil,
        autoStart: Bool = false,
        autoScroll: Bool = false
    ) {
        let screen = CaptureEngine.shared.resolveScreen(displayIndex: displayIndex)
        if let rect, rect.width >= 20, rect.height >= 20 {
            presentControlPanel(rect: rect, on: screen, autoStart: autoStart, autoScroll: autoScroll)
            return
        }

        SelectionOverlayController.shared.beginAreaSelection(on: screen, frozenImage: nil, initialRect: nil) { [weak self] selected, _ in
            guard let self, let selected else { return }
            self.presentControlPanel(rect: selected, on: screen, autoStart: autoStart, autoScroll: autoScroll)
        }
    }

    private func presentControlPanel(rect: CGRect, on screen: NSScreen, autoStart: Bool, autoScroll: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.targetRect = rect
            self.targetScreen = screen
            self.capturedFrames.removeAll()
            self.isCapturing = false

            let panel = NSPanel(
                contentRect: CGRect(x: rect.midX - 170, y: max(screen.frame.minY + 24, rect.minY - 64), width: 340, height: 52),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .floating
            panel.backgroundColor = .clear
            panel.isOpaque = false

            let view = ScrollingCaptureHUD(
                autoStart: autoStart,
                autoScroll: autoScroll,
                onStart: { [weak self] useAutoScroll in
                    self?.startRecordingScroll(autoScroll: useAutoScroll)
                },
                onDone: { [weak self] in
                    self?.finishScrollingCapture()
                },
                onCancel: { [weak self] in
                    self?.cancel()
                }
            )
            panel.contentView = NSHostingView(rootView: view)
            panel.orderFrontRegardless()
            self.controlPanel = panel

            if autoStart {
                self.startRecordingScroll(autoScroll: autoScroll)
            }
        }
    }

    private func startRecordingScroll(autoScroll: Bool) {
        isCapturing = true
        capturedFrames.removeAll()
        let first = CaptureEngine.shared.captureRegionSync(rect: targetRect, on: targetScreen)
        capturedFrames.append(first)

        scrollTimer?.invalidate()
        scrollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.isCapturing else { return }
            if autoScroll {
                self.postScrollWheelEvent(deltaY: -6)
            }
            let frame = CaptureEngine.shared.captureRegionSync(rect: self.targetRect, on: self.targetScreen)
            self.capturedFrames.append(frame)
            if self.capturedFrames.count >= 40 {
                self.finishScrollingCapture()
            }
        }
    }

    private func postScrollWheelEvent(deltaY: Int32) {
        let screenH = targetScreen?.frame.height ?? 900
        let center = CGPoint(x: targetRect.midX, y: screenH - targetRect.midY)
        if let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: center, mouseButton: .left) {
            move.post(tap: .cghidEventTap)
        }
        if let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: deltaY, wheel2: 0, wheel3: 0) {
            scroll.post(tap: .cghidEventTap)
        }
    }

    private func finishScrollingCapture() {
        scrollTimer?.invalidate()
        scrollTimer = nil
        isCapturing = false
        controlPanel?.orderOut(nil)
        controlPanel = nil

        let stitched = ScrollingStitcher.stitchVertical(frames: capturedFrames)
            ?? CaptureEngine.shared.captureRegionSync(rect: targetRect, on: targetScreen)
        capturedFrames.removeAll()

        CaptureEngine.shared.finalizeCapture(
            rawImage: stitched,
            sourceRect: targetRect,
            displayScale: targetScreen?.backingScaleFactor ?? 2.0,
            windowTitle: "Scrolling Capture",
            appName: NSWorkspace.shared.frontmostApplication?.localizedName
        )
    }

    private func cancel() {
        scrollTimer?.invalidate()
        scrollTimer = nil
        isCapturing = false
        capturedFrames.removeAll()
        controlPanel?.orderOut(nil)
        controlPanel = nil
    }
}

private struct ScrollingCaptureHUD: View {
    @State private var started: Bool
    @State private var autoScroll: Bool
    let onStart: (Bool) -> Void
    let onDone: () -> Void
    let onCancel: () -> Void

    init(autoStart: Bool, autoScroll: Bool, onStart: @escaping (Bool) -> Void, onDone: @escaping () -> Void, onCancel: @escaping () -> Void) {
        _started = State(initialValue: autoStart)
        _autoScroll = State(initialValue: autoScroll)
        self.onStart = onStart
        self.onDone = onDone
        self.onCancel = onCancel
    }

    var body: some View {
        HStack(spacing: 10) {
            if !started {
                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                Button("Start Capture") {
                    started = true
                    onStart(autoScroll)
                }
                .buttonStyle(.borderedProminent)
            } else {
                ProgressView().controlSize(.small)
                Text("Capturing scroll...")
                    .font(.caption)
                Button("Done") {
                    onDone()
                }
                .buttonStyle(.borderedProminent)
            }
            Button("Cancel") {
                onCancel()
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
