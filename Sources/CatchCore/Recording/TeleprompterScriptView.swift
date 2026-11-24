import AppKit
import SwiftUI

struct TeleprompterScriptView: NSViewRepresentable {
    let layout: TeleprompterTextLayout
    let script: String
    let fontSize: Double
    let progress: Double
    let anchor: Int?
    let readUpTo: Int
    let nextSpokenWord: NSRange?
    let allowBackwardTransition: Bool
    var onTapCharacter: ((Int) -> Void)?
    var onManualScroll: ((Double) -> Void)?

    func makeNSView(context: Context) -> TeleprompterScriptCanvas {
        TeleprompterScriptCanvas(layout: layout)
    }

    func updateNSView(_ view: TeleprompterScriptCanvas, context: Context) {
        view.onTapCharacter = onTapCharacter
        view.onManualScroll = onManualScroll
        view.update(
            script: script,
            fontSize: fontSize,
            progress: progress,
            anchor: anchor,
            readUpTo: readUpTo,
            nextSpokenWord: nextSpokenWord,
            allowBackwardTransition: allowBackwardTransition
        )
    }
}

final class TeleprompterScriptCanvas: NSView {
    private let scriptLayout: TeleprompterTextLayout
    private var script = ""
    private var fontSize = 22.0
    private var progress = 0.0
    private var anchor: Int?
    private var readUpTo = 0
    private var nextSpokenWord: NSRange?

    private var displayedOffset: CGFloat = 0
    private var targetOffset: CGFloat = 0
    private var hasInitializedOffset = false
    private var smoothTimer: Timer?

    var onTapCharacter: ((Int) -> Void)?
    var onManualScroll: ((Double) -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(layout: TeleprompterTextLayout) {
        scriptLayout = layout
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        smoothTimer?.invalidate()
    }

    func update(
        script: String,
        fontSize: Double,
        progress: Double,
        anchor: Int?,
        readUpTo: Int,
        nextSpokenWord: NSRange?,
        allowBackwardTransition: Bool
    ) {
        let scriptChanged = self.script != script
        if scriptChanged {
            self.script = script
            setAccessibilityValue(script)
            hasInitializedOffset = false
        }
        self.fontSize = fontSize
        self.progress = progress
        self.anchor = anchor
        self.readUpTo = readUpTo
        self.nextSpokenWord = nextSpokenWord
        prepareLayout()

        let nextTarget = scriptLayout.position(progress: progress, anchor: anchor)
        if !hasInitializedOffset {
            displayedOffset = nextTarget
            targetOffset = nextTarget
            hasInitializedOffset = true
            stopSmoothing()
        } else if allowBackwardTransition || nextTarget >= targetOffset - 0.5 {
            targetOffset = nextTarget
            if abs(targetOffset - displayedOffset) > 0.75 {
                startSmoothingIfNeeded()
            } else {
                displayedOffset = targetOffset
                stopSmoothing()
            }
        }
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        prepareLayout()
        targetOffset = scriptLayout.position(progress: progress, anchor: anchor)
        displayedOffset = targetOffset
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        scriptLayout.draw(
            at: NSPoint(x: 14, y: 22 - displayedOffset),
            within: bounds,
            highlighting: nextSpokenWord
        )
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let origin = NSPoint(x: 14, y: 22 - displayedOffset)
        if let charIndex = scriptLayout.wordStartCharacter(at: point, origin: origin) {
            onTapCharacter?(charIndex)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let maxOffset = scriptLayout.maxLineOffset
        guard maxOffset > 0 else { return }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
        let nextOffset = max(0, min(maxOffset, displayedOffset - delta))
        displayedOffset = nextOffset
        targetOffset = nextOffset
        stopSmoothing()
        needsDisplay = true
        let newProgress = Double(nextOffset / maxOffset)
        onManualScroll?(newProgress)
    }

    private func startSmoothingIfNeeded() {
        guard smoothTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let delta = self.targetOffset - self.displayedOffset
            if abs(delta) <= 0.45 {
                self.displayedOffset = self.targetOffset
                self.stopSmoothing()
            } else {
                self.displayedOffset += delta * 0.22
            }
            self.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        smoothTimer = timer
    }

    private func stopSmoothing() {
        smoothTimer?.invalidate()
        smoothTimer = nil
    }

    private func prepareLayout() {
        scriptLayout.update(
            script: script,
            fontSize: fontSize,
            width: max(1, bounds.width - 28),
            readUpTo: readUpTo
        )
    }
}

final class TeleprompterTextLayout {
    private let storage = NSTextStorage()
    private let manager = NSLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude))
    private var script = ""
    private var fontSize = 0.0
    private var width = 0.0
    private var readUpTo = 0
    private var lines: [CGFloat] = []
    private var cachedCues: [NSRange] = []
    private(set) var stageDirections: [StageDirection] = []

    struct StageDirection: Equatable {
        let approach: Double
        let start: Double
        let end: Double
        let wordCount: Int
        let endsScript: Bool
    }

    var maxLineOffset: CGFloat {
        lines.last ?? 0
    }

    init() {
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.allowsNonContiguousLayout = false
    }

    func update(script: String, fontSize: Double, width: CGFloat, readUpTo: Int = 0) {
        let clampedRead = max(0, min(readUpTo, (script as NSString).length))
        let geometryChanged = self.script != script || self.fontSize != fontSize || self.width != width
        let readChanged = self.readUpTo != clampedRead
        guard geometryChanged || readChanged else { return }

        if geometryChanged {
            self.script = script
            self.fontSize = fontSize
            self.width = width
            self.readUpTo = clampedRead
            container.size.width = width

            let system = NSFont.systemFont(ofSize: fontSize, weight: .medium)
            let rounded = system.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: fontSize) } ?? system
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 6

            let cues = TeleprompterScriptMatcher(script: script).cues
            cachedCues = cues

            let text = NSMutableAttributedString(string: script, attributes: [
                .font: rounded,
                .foregroundColor: NSColor.white.withAlphaComponent(0.95),
                .paragraphStyle: paragraph
            ])
            applyColorAttributes(to: text, cues: cues, readUpTo: clampedRead)
            storage.setAttributedString(text)
            manager.ensureLayout(for: container)

            var starts: [CGFloat] = []
            manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { rect, _, _, _, _ in
                starts.append(rect.minY)
            }
            lines = starts

            let source = script as NSString
            stageDirections = TeleprompterScriptMatcher.stageDirections(in: script).map { direction in
                let start = progress(for: direction.line.location)
                let prefix = NSRange(location: 0, length: direction.line.location)
                let previous = source.rangeOfCharacter(from: .whitespacesAndNewlines.inverted, options: .backwards, range: prefix)
                let approach: Double
                if previous.location == NSNotFound {
                    approach = 0
                } else {
                    let previousY = position(progress: 0, anchor: previous.location)
                    let nextY = lines.first { $0 > previousY } ?? previousY
                    let nextProgress = normalized(nextY)
                    approach = nextProgress < start
                        ? normalized((previousY + nextY) / 2)
                        : start
                }
                let tail = NSRange(location: NSMaxRange(direction.line), length: source.length - NSMaxRange(direction.line))
                let next = source.rangeOfCharacter(from: .whitespacesAndNewlines.inverted, range: tail)
                let words = source.substring(with: direction.cue).split(whereSeparator: \.isWhitespace).count
                let endsScript = next.location == NSNotFound
                return StageDirection(
                    approach: approach,
                    start: start,
                    end: endsScript ? 1 : progress(for: next.location),
                    wordCount: words,
                    endsScript: endsScript
                )
            }
        } else if readChanged {
            self.readUpTo = clampedRead
            storage.beginEditing()
            applyColorAttributes(to: storage, cues: cachedCues, readUpTo: clampedRead)
            storage.endEditing()
        }
    }

    private func applyColorAttributes(to text: NSMutableAttributedString, cues: [NSRange], readUpTo: Int) {
        let totalLength = text.length
        guard totalLength > 0 else { return }
        let fullRange = NSRange(location: 0, length: totalLength)
        text.addAttribute(.foregroundColor, value: NSColor.white.withAlphaComponent(0.95), range: fullRange)
        if readUpTo > 0 {
            let readRange = NSRange(location: 0, length: min(readUpTo, totalLength))
            text.addAttribute(.foregroundColor, value: NSColor.white.withAlphaComponent(0.36), range: readRange)
        }
        for cue in cues {
            let isReadCue = NSMaxRange(cue) <= readUpTo
            let cueColor = isReadCue ? NSColor.systemOrange.withAlphaComponent(0.45) : NSColor.systemOrange
            text.addAttribute(.foregroundColor, value: cueColor, range: cue)
        }
    }

    func position(progress: Double, anchor: Int?) -> CGFloat {
        let last = lines.last ?? 0
        guard let anchor, anchor < storage.length, anchor >= 0 else { return CGFloat(progress) * last }
        let glyph = manager.glyphIndexForCharacter(at: anchor)
        return min(last, manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY)
    }

    func rewind(progress: Double, anchor: Int?) -> Double {
        guard let last = lines.last, last > 0 else { return 0 }
        let y = position(progress: progress, anchor: anchor)
        let current = lines.lastIndex { $0 <= y + 0.5 } ?? 0
        return Double(lines[max(0, current - 2)] / last)
    }

    func progress(for anchor: Int) -> Double {
        normalized(position(progress: 0, anchor: anchor))
    }

    private func normalized(_ y: CGFloat) -> Double {
        guard let last = lines.last, last > 0 else { return 0 }
        return Double(y / last)
    }

    func character(at progress: Double) -> Int {
        guard manager.numberOfGlyphs > 0 else { return 0 }
        let y = position(progress: progress, anchor: nil)
        let start = lines.last { $0 <= y + 0.5 } ?? 0
        let glyph = manager.glyphIndex(for: NSPoint(x: 0, y: start + 1), in: container)
        return manager.characterIndexForGlyph(at: glyph)
    }

    /// Maps a click in view coordinates to the start character index of the tapped word.
    func wordStartCharacter(at viewPoint: NSPoint, origin: NSPoint) -> Int? {
        guard manager.numberOfGlyphs > 0, storage.length > 0 else { return nil }
        let textPoint = NSPoint(x: max(0, viewPoint.x - origin.x), y: max(0, viewPoint.y - origin.y))
        var fraction: CGFloat = 0
        let glyph = manager.glyphIndex(for: textPoint, in: container, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < manager.numberOfGlyphs else { return nil }
        let charIndex = min(manager.characterIndexForGlyph(at: glyph), storage.length - 1)
        let source = script as NSString
        var start = charIndex
        while start > 0 {
            let scalar = source.character(at: start - 1)
            if let unicode = UnicodeScalar(scalar), CharacterSet.whitespacesAndNewlines.contains(unicode) {
                break
            }
            start -= 1
        }
        return start
    }

    func draw(at origin: NSPoint, within bounds: NSRect, highlighting word: NSRange?) {
        let visible = bounds.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = manager.glyphRange(forBoundingRect: visible, in: container)
        if let word, NSMaxRange(word) <= storage.length {
            let wordGlyphs = manager.glyphRange(forCharacterRange: word, actualCharacterRange: nil)
            let rect = manager.boundingRect(forGlyphRange: wordGlyphs, in: container)
            let underline = NSRect(x: rect.minX + origin.x, y: rect.maxY + origin.y - 3, width: rect.width, height: 3)
            NSColor.systemTeal.setFill()
            NSBezierPath(roundedRect: underline, xRadius: 1.5, yRadius: 1.5).fill()
        }
        manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
    }
}
