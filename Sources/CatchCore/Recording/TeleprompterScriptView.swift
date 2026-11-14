import AppKit
import SwiftUI

struct TeleprompterScriptView: NSViewRepresentable {
    let layout: TeleprompterTextLayout
    let script: String
    let fontSize: Double
    let progress: Double
    let anchor: Int?
    let nextSpokenWord: NSRange?

    func makeNSView(context: Context) -> TeleprompterScriptCanvas {
        TeleprompterScriptCanvas(layout: layout)
    }

    func updateNSView(_ view: TeleprompterScriptCanvas, context: Context) {
        view.update(script: script, fontSize: fontSize, progress: progress, anchor: anchor, nextSpokenWord: nextSpokenWord)
    }
}

final class TeleprompterScriptCanvas: NSView {
    private let scriptLayout: TeleprompterTextLayout
    private var script = ""
    private var fontSize = 22.0
    private var progress = 0.0
    private var anchor: Int?
    private var nextSpokenWord: NSRange?
    override var isFlipped: Bool { true }

    init(layout: TeleprompterTextLayout) {
        scriptLayout = layout
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { nil }

    func update(script: String, fontSize: Double, progress: Double, anchor: Int?, nextSpokenWord: NSRange?) {
        if self.script != script {
            self.script = script
            setAccessibilityValue(script)
        }
        self.fontSize = fontSize
        self.progress = progress
        self.anchor = anchor
        self.nextSpokenWord = nextSpokenWord
        prepareLayout()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        prepareLayout()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let offset = scriptLayout.position(progress: progress, anchor: anchor)
        scriptLayout.draw(at: NSPoint(x: 14, y: 22 - offset), within: bounds, highlighting: nextSpokenWord)
    }

    private func prepareLayout() {
        scriptLayout.update(script: script, fontSize: fontSize, width: max(1, bounds.width - 28))
    }
}

final class TeleprompterTextLayout {
    private let storage = NSTextStorage()
    private let manager = NSLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude))
    private var script = ""
    private var fontSize = 0.0
    private var width = 0.0
    private var lines: [CGFloat] = []
    private(set) var stageDirections: [StageDirection] = []

    struct StageDirection: Equatable {
        let approach: Double
        let start: Double
        let end: Double
        let wordCount: Int
        let endsScript: Bool
    }

    init() {
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.allowsNonContiguousLayout = false
    }

    func update(script: String, fontSize: Double, width: CGFloat) {
        guard self.script != script || self.fontSize != fontSize || self.width != width else { return }
        self.script = script
        self.fontSize = fontSize
        self.width = width
        container.size.width = width
        let system = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let rounded = system.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: fontSize) } ?? system
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 6
        let text = NSMutableAttributedString(string: script, attributes: [
            .font: rounded,
            .foregroundColor: NSColor.white.withAlphaComponent(0.95),
            .paragraphStyle: paragraph
        ])
        text.beginEditing()
        for cue in TeleprompterScriptMatcher(script: script).cues {
            text.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: cue)
        }
        text.endEditing()
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
            // If the reading band is in the paragraph gap, lead into the cue on silence.
            // Keep the preceding line of dialogue under normal voice control.
            let approach: Double
            if previous.location == NSNotFound {
                approach = 0
            } else {
                let previousY = position(progress: 0, anchor: previous.location)
                let nextY = lines.first { $0 > previousY } ?? previousY
                let nextProgress = normalized(nextY)
                // The band can already look empty between the last spoken baseline
                // and the start of the spacer line. Only extend across real gaps.
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
