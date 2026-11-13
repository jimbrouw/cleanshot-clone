import SwiftUI

/// Rive-style 60fps interactive vector animations rendered via SwiftUI `TimelineView(.animation)` + `Canvas`.
/// Each stage runs a deterministic looping state machine with spring easing so users immediately understand
/// what CleanShot Clone needs and what every tool does.

private func smoothStep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
    let t = max(0, min(1, (x - edge0) / max(0.0001, edge1 - edge0)))
    return t * t * (3 - 2 * t)
}

private func springOvershoot(_ t: Double) -> Double {
    let clamped = max(0, min(1, t))
    if clamped == 0 { return 0 }
    if clamped == 1 { return 1 }
    return 1 - pow(2, -9 * clamped) * cos(clamped * .pi * 2.4)
}

// MARK: - Stage 1: Permissions (Shield + Live Toggle Vector State Machine)

public struct PermissionsStageAnimationView: View {
    public let hasScreenRecording: Bool
    public let hasAccessibility: Bool

    public init(hasScreenRecording: Bool, hasAccessibility: Bool) {
        self.hasScreenRecording = hasScreenRecording
        self.hasAccessibility = hasAccessibility
    }

    public var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let center = CGPoint(x: size.width * 0.5, y: size.height * 0.44)
                let pulse = (sin(t * 2.4) + 1) * 0.5

                // Ambient glowing rings
                for i in 0..<3 {
                    let phase = (t * 0.45 + Double(i) * 0.33).truncatingRemainder(dividingBy: 1.0)
                    let radius = 44 + phase * 82
                    let alpha = (1 - phase) * 0.22
                    let ringRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                    let color = (hasScreenRecording && hasAccessibility) ? Color.green : Color.accentColor
                    ctx.stroke(Path(ellipseIn: ringRect), with: .color(color.opacity(alpha)), lineWidth: 2)
                }

                // Shield body
                let shieldW: CGFloat = 78
                let shieldH: CGFloat = 92
                var shield = Path()
                shield.move(to: CGPoint(x: center.x, y: center.y - shieldH * 0.5))
                shield.addLine(to: CGPoint(x: center.x + shieldW * 0.5, y: center.y - shieldH * 0.30))
                shield.addQuadCurve(
                    to: CGPoint(x: center.x, y: center.y + shieldH * 0.5),
                    control: CGPoint(x: center.x + shieldW * 0.46, y: center.y + shieldH * 0.25)
                )
                shield.addQuadCurve(
                    to: CGPoint(x: center.x - shieldW * 0.5, y: center.y - shieldH * 0.30),
                    control: CGPoint(x: center.x - shieldW * 0.46, y: center.y + shieldH * 0.25)
                )
                shield.closeSubpath()

                let shieldColor = (hasScreenRecording && hasAccessibility) ? Color.green : Color.blue
                ctx.fill(shield, with: .linearGradient(
                    Gradient(colors: [shieldColor.opacity(0.95), shieldColor.opacity(0.6)]),
                    startPoint: CGPoint(x: center.x, y: center.y - shieldH * 0.5),
                    endPoint: CGPoint(x: center.x, y: center.y + shieldH * 0.5)
                ))
                ctx.stroke(shield, with: .color(.white.opacity(0.45)), lineWidth: 1.5)

                // Inner checkmark or lock glyph
                var glyph = Path()
                if hasScreenRecording && hasAccessibility {
                    glyph.move(to: CGPoint(x: center.x - 16, y: center.y + 2))
                    glyph.addLine(to: CGPoint(x: center.x - 4, y: center.y + 15))
                    glyph.addLine(to: CGPoint(x: center.x + 18, y: center.y - 12))
                } else {
                    let lift = CGFloat(pulse * 3)
                    glyph.addRoundedRect(in: CGRect(x: center.x - 13, y: center.y - 2, width: 26, height: 20), cornerSize: CGSize(width: 5, height: 5))
                    glyph.addArc(center: CGPoint(x: center.x, y: center.y - 4 - lift), radius: 9, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                }
                ctx.stroke(glyph, with: .color(.white), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))

                // Two animated permission pill cards below shield
                drawTogglePill(ctx: ctx, origin: CGPoint(x: size.width * 0.5 - 128, y: size.height - 68), width: 120, label: "Screen Rec.", active: hasScreenRecording, animTime: t, phaseOffset: 0)
                drawTogglePill(ctx: ctx, origin: CGPoint(x: size.width * 0.5 + 8, y: size.height - 68), width: 120, label: "Accessibility", active: hasAccessibility, animTime: t, phaseOffset: 0.9)
            }
        }
    }

    private func drawTogglePill(ctx: GraphicsContext, origin: CGPoint, width: CGFloat, label: String, active: Bool, animTime: Double, phaseOffset: Double) {
        let rect = CGRect(x: origin.x, y: origin.y, width: width, height: 36)
        let bg = RoundedRectangle(cornerRadius: 10).path(in: rect)
        ctx.fill(bg, with: .color(Color.white.opacity(0.08)))
        ctx.stroke(bg, with: .color((active ? Color.green : Color.orange).opacity(0.55)), lineWidth: 1.2)

        let cycle = ((animTime + phaseOffset) * 0.55).truncatingRemainder(dividingBy: 1.0)
        let demoProgress = active ? 1.0 : smoothStep(0.35, 0.7, cycle)

        // Toggle track
        let trackRect = CGRect(x: origin.x + 8, y: origin.y + 10, width: 28, height: 16)
        let trackPath = RoundedRectangle(cornerRadius: 8).path(in: trackRect)
        ctx.fill(trackPath, with: .color(active ? Color.green : Color.gray.opacity(0.35 + 0.45 * demoProgress)))

        let knobX = trackRect.minX + 2 + CGFloat(demoProgress) * 12
        let knobRect = CGRect(x: knobX, y: trackRect.minY + 2, width: 12, height: 12)
        ctx.fill(Path(ellipseIn: knobRect), with: .color(.white))

        let text = Text(label).font(.system(size: 11, weight: .semibold)).foregroundColor(.white.opacity(0.92))
        ctx.draw(text, at: CGPoint(x: origin.x + 76, y: origin.y + 18))
    }
}

// MARK: - Stage 2: Shortcuts Conflict & Conflict-Free Keycaps

public struct ShortcutsStageAnimationView: View {
    public let macShortcutsDisabled: Bool

    public init(macShortcutsDisabled: Bool) {
        self.macShortcutsDisabled = macShortcutsDisabled
    }

    public var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let cycle = t.truncatingRemainder(dividingBy: 3.6)
            let pressAmount = smoothStep(0.35, 0.6, cycle) * (1 - smoothStep(1.6, 2.0, cycle))
            let hudReveal = springOvershoot(smoothStep(0.65, 1.4, cycle)) * (1 - smoothStep(2.6, 3.2, cycle))

            Canvas { ctx, size in
                let centerX = size.width * 0.5
                let keysY = size.height * 0.68

                // Floating preview HUD above keyboard
                let hudW: CGFloat = 240
                let hudH: CGFloat = 76
                let hudScale = 0.85 + 0.15 * hudReveal
                let hudOrigin = CGPoint(x: centerX - (hudW * hudScale) * 0.5, y: 24 + (1 - hudReveal) * 16)
                let hudRect = CGRect(origin: hudOrigin, size: CGSize(width: hudW * hudScale, height: hudH * hudScale))
                let hudPath = RoundedRectangle(cornerRadius: 14).path(in: hudRect)
                ctx.fill(hudPath, with: .color(Color(red: 0.10, green: 0.14, blue: 0.22).opacity(0.2 + 0.78 * hudReveal)))
                ctx.stroke(hudPath, with: .color((macShortcutsDisabled ? Color.green : Color.cyan).opacity(0.7 * hudReveal)), lineWidth: 1.5)

                let hudTitle = macShortcutsDisabled ? "CleanShot HUD Ready (⇧⌘5)" : "Conflict-Free HUD (⌥⇧⌘5)"
                ctx.draw(
                    Text(hudTitle).font(.system(size: 12, weight: .bold)).foregroundColor(.white.opacity(0.25 + 0.75 * hudReveal)),
                    at: CGPoint(x: hudRect.midX, y: hudRect.minY + 24 * hudScale)
                )

                // Mini HUD icons
                let icons = ["crop", "macwindow", "scroll", "text.viewfinder"]
                for (idx, icon) in icons.enumerated() {
                    let ix = hudRect.midX + CGFloat(idx - 1) * 44 * hudScale - 22 * hudScale
                    let pill = CGRect(x: ix - 14, y: hudRect.midY + 2, width: 28, height: 22)
                    ctx.fill(RoundedRectangle(cornerRadius: 6).path(in: pill), with: .color(.white.opacity(0.12 * hudReveal)))
                    ctx.draw(Image(systemName: icon), at: CGPoint(x: pill.midX, y: pill.midY))
                }

                // Keycaps row
                let keyLabels: [String] = macShortcutsDisabled ? ["⇧", "⌘", "5"] : ["⌥", "⇧", "⌘", "5"]
                let keyW: CGFloat = 54
                let spacing: CGFloat = 10
                let totalW = CGFloat(keyLabels.count) * keyW + CGFloat(keyLabels.count - 1) * spacing
                let startX = centerX - totalW * 0.5

                for (i, label) in keyLabels.enumerated() {
                    let stagger = max(0, min(1, pressAmount * 1.3 - Double(i) * 0.08))
                    let yDrop = CGFloat(stagger * 5)
                    let kx = startX + CGFloat(i) * (keyW + spacing)
                    let keyRect = CGRect(x: kx, y: keysY + yDrop, width: keyW, height: 50)
                    let keyShadow = CGRect(x: kx, y: keysY + 6, width: keyW, height: 50)
                    ctx.fill(RoundedRectangle(cornerRadius: 10).path(in: keyShadow), with: .color(.black.opacity(0.45)))

                    let activeColor = stagger > 0.25 ? Color.accentColor : Color(white: 0.22)
                    ctx.fill(RoundedRectangle(cornerRadius: 10).path(in: keyRect), with: .color(activeColor))
                    ctx.stroke(RoundedRectangle(cornerRadius: 10).path(in: keyRect), with: .color(.white.opacity(0.32)), lineWidth: 1)
                    ctx.draw(
                        Text(label).font(.system(size: 18, weight: .bold, design: .rounded)).foregroundColor(.white),
                        at: CGPoint(x: keyRect.midX, y: keyRect.midY)
                    )
                }
            }
        }
    }
}

// MARK: - Stage 3: Capture Modes (Crosshair Area, Window Snap, Scrolling Capture)

public struct CaptureModesStageAnimationView: View {
    public init() {}

    public var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let cycle = t.truncatingRemainder(dividingBy: 6.0)
            let mode = Int(cycle / 2.0) // 0: Area, 1: Window, 2: Scrolling
            let local = (cycle.truncatingRemainder(dividingBy: 2.0)) / 2.0

            Canvas { ctx, size in
                let stage = CGRect(x: 24, y: 18, width: size.width - 48, height: size.height - 56)
                ctx.fill(RoundedRectangle(cornerRadius: 14).path(in: stage), with: .color(Color.white.opacity(0.06)))
                ctx.stroke(RoundedRectangle(cornerRadius: 14).path(in: stage), with: .color(.white.opacity(0.15)), lineWidth: 1)

                // Mock desktop window inside stage
                let winRect = stage.insetBy(dx: 28, dy: 20)
                ctx.fill(RoundedRectangle(cornerRadius: 10).path(in: winRect), with: .color(Color(red: 0.14, green: 0.17, blue: 0.24)))
                // Window traffic lights
                for (i, c) in [Color.red, Color.yellow, Color.green].enumerated() {
                    ctx.fill(Path(ellipseIn: CGRect(x: winRect.minX + 10 + CGFloat(i) * 12, y: winRect.minY + 9, width: 7, height: 7)), with: .color(c.opacity(0.85)))
                }

                // Content lines inside mock window
                let scrollShift = mode == 2 ? CGFloat(smoothStep(0.15, 0.85, local) * 34) : 0
                for row in 0..<5 {
                    let y = winRect.minY + 30 + CGFloat(row) * 18 - scrollShift * 0.4
                    if y > winRect.minY + 22 && y < winRect.maxY - 12 {
                        let lineW = winRect.width * (row % 2 == 0 ? 0.65 : 0.48)
                        let bar = CGRect(x: winRect.minX + 18, y: y, width: lineW, height: 8)
                        ctx.fill(RoundedRectangle(cornerRadius: 4).path(in: bar), with: .color(.white.opacity(0.16)))
                    }
                }

                if mode == 0 {
                    // Area Selection + Crosshair + Dimensions pill
                    let grow = CGFloat(smoothStep(0.1, 0.7, local))
                    let sel = CGRect(
                        x: winRect.minX + 14,
                        y: winRect.minY + 26,
                        width: 40 + (winRect.width - 54) * grow,
                        height: 24 + (winRect.height - 46) * grow
                    )
                    ctx.fill(Path(sel), with: .color(Color.cyan.opacity(0.18)))
                    ctx.stroke(Path(sel), with: .color(.cyan), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    ctx.draw(
                        Text("\(Int(sel.width * 3)) × \(Int(sel.height * 3))").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(.cyan),
                        at: CGPoint(x: sel.maxX - 38, y: sel.maxY + 11)
                    )
                } else if mode == 1 {
                    // Window snap glow
                    let snap = smoothStep(0.1, 0.5, local)
                    let glowRect = winRect.insetBy(dx: -3, dy: -3)
                    ctx.stroke(RoundedRectangle(cornerRadius: 12).path(in: glowRect), with: .color(Color.green.opacity(0.9 * snap)), lineWidth: 3)
                    ctx.draw(
                        Text("Window Snap + Shadow").font(.system(size: 11, weight: .bold)).foregroundColor(.green),
                        at: CGPoint(x: winRect.midX, y: winRect.maxY - 14)
                    )
                } else {
                    // Scrolling Capture down-arrow + stitch height indicator
                    let stitchH = Int(1080 + smoothStep(0.15, 0.85, local) * 2400)
                    ctx.stroke(RoundedRectangle(cornerRadius: 10).path(in: winRect), with: .color(.orange), lineWidth: 2)
                    ctx.draw(
                        Text("Scrolling Capture • \(stitchH)px stitched").font(.system(size: 11, weight: .bold)).foregroundColor(.orange),
                        at: CGPoint(x: winRect.midX, y: winRect.maxY - 14)
                    )
                }

                // Mode indicators footer
                let titles = ["Area + Crosshair", "Window Capture", "Scrolling Capture"]
                for (i, title) in titles.enumerated() {
                    let x = size.width * CGFloat(i + 1) / 4.0
                    let active = (i == mode)
                    ctx.draw(
                        Text(title).font(.system(size: 11, weight: active ? .bold : .medium)).foregroundColor(active ? .white : .white.opacity(0.45)),
                        at: CGPoint(x: x, y: size.height - 16)
                    )
                }
            }
        }
    }
}

// MARK: - Stage 4: Annotate & Background Tool

public struct AnnotateStageAnimationView: View {
    public init() {}

    public var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let cycle = t.truncatingRemainder(dividingBy: 4.5)
            let bgReveal = smoothStep(0.1, 0.8, cycle)
            let arrowReveal = smoothStep(0.9, 1.8, cycle)
            let counterScale = springOvershoot(smoothStep(1.8, 2.4, cycle))
            let blurSweep = smoothStep(2.4, 3.2, cycle)

            Canvas { ctx, size in
                // Background wrapper
                let bgRect = CGRect(x: 28, y: 16, width: size.width - 56, height: size.height - 44)
                let bgPath = RoundedRectangle(cornerRadius: 16).path(in: bgRect)
                ctx.fill(bgPath, with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 0.35, green: 0.25, blue: 0.90).opacity(0.2 + 0.75 * bgReveal),
                        Color(red: 0.92, green: 0.32, blue: 0.55).opacity(0.2 + 0.75 * bgReveal)
                    ]),
                    startPoint: bgRect.origin,
                    endPoint: CGPoint(x: bgRect.maxX, y: bgRect.maxY)
                ))

                // Framed screenshot inside background
                let inset = 12 + CGFloat(bgReveal * 10)
                let shotRect = bgRect.insetBy(dx: inset, dy: inset)
                let shotPath = RoundedRectangle(cornerRadius: 10).path(in: shotRect)
                ctx.fill(shotPath, with: .color(Color(red: 0.11, green: 0.13, blue: 0.18)))

                // Fake UI card inside screenshot
                let ctaRect = CGRect(x: shotRect.minX + 22, y: shotRect.minY + 24, width: 96, height: 26)
                ctx.fill(RoundedRectangle(cornerRadius: 7).path(in: ctaRect), with: .color(.blue.opacity(0.85)))
                ctx.draw(Text("Export PNG").font(.system(size: 11, weight: .bold)).foregroundColor(.white), at: CGPoint(x: ctaRect.midX, y: ctaRect.midY))

                // Redacted API key strip (pixelated by blurSweep)
                let secretRect = CGRect(x: shotRect.minX + 22, y: shotRect.maxY - 38, width: 146, height: 18)
                ctx.fill(RoundedRectangle(cornerRadius: 4).path(in: secretRect), with: .color(.white.opacity(0.14)))
                if blurSweep > 0.02 {
                    let cols = 12
                    let cellW = (secretRect.width * CGFloat(blurSweep)) / CGFloat(cols)
                    for c in 0..<cols {
                        for r in 0..<2 {
                            let cell = CGRect(x: secretRect.minX + CGFloat(c) * cellW, y: secretRect.minY + CGFloat(r) * 9, width: max(1, cellW - 0.5), height: 8.5)
                            let shade = ((c + r) % 2 == 0) ? 0.45 : 0.22
                            ctx.fill(Path(cell), with: .color(.gray.opacity(shade)))
                        }
                    }
                }

                // Vector Arrow animating along path
                if arrowReveal > 0.02 {
                    let p0 = CGPoint(x: shotRect.maxX - 42, y: shotRect.midY + 10)
                    let p1 = CGPoint(x: ctaRect.maxX + 10, y: ctaRect.midY)
                    let tip = CGPoint(x: p0.x + (p1.x - p0.x) * CGFloat(arrowReveal), y: p0.y + (p1.y - p0.y) * CGFloat(arrowReveal))
                    var arrow = Path()
                    arrow.move(to: p0)
                    arrow.addLine(to: tip)
                    ctx.stroke(arrow, with: .color(.red), style: StrokeStyle(lineWidth: 4, lineCap: .round))

                    if arrowReveal > 0.85 {
                        var head = Path()
                        head.move(to: tip)
                        head.addLine(to: CGPoint(x: tip.x + 10, y: tip.y - 6))
                        head.move(to: tip)
                        head.addLine(to: CGPoint(x: tip.x + 10, y: tip.y + 6))
                        ctx.stroke(head, with: .color(.red), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    }
                }

                // Numbered Counter Bubble
                if counterScale > 0.02 {
                    let r = 13 * CGFloat(counterScale)
                    let cCenter = CGPoint(x: ctaRect.minX - 6, y: ctaRect.minY - 6)
                    let circle = Path(ellipseIn: CGRect(x: cCenter.x - r, y: cCenter.y - r, width: r * 2, height: r * 2))
                    ctx.fill(circle, with: .color(.orange))
                    ctx.draw(Text("1").font(.system(size: 12 * CGFloat(counterScale), weight: .heavy)).foregroundColor(.white), at: cCenter)
                }

                ctx.draw(
                    Text("Background Padding • Arrows • Counters • Pixelate Redaction").font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.65)),
                    at: CGPoint(x: size.width * 0.5, y: size.height - 12)
                )
            }
        }
    }
}

// MARK: - Stage 5: OCR Text Recognition, Pin & Quick Access Workflow

public struct WorkflowStageAnimationView: View {
    public init() {}

    public var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let cycle = t.truncatingRemainder(dividingBy: 4.0)
            let laserY = smoothStep(0.2, 1.4, cycle)
            let badgePop = springOvershoot(smoothStep(1.3, 1.9, cycle))
            let pinFloat = sin(t * 2.2) * 4

            Canvas { ctx, size in
                // Left Card: OCR Scanner
                let leftCard = CGRect(x: 24, y: 18, width: (size.width - 68) * 0.5, height: size.height - 46)
                ctx.fill(RoundedRectangle(cornerRadius: 12).path(in: leftCard), with: .color(Color.white.opacity(0.08)))
                ctx.stroke(RoundedRectangle(cornerRadius: 12).path(in: leftCard), with: .color(.white.opacity(0.18)), lineWidth: 1)
                ctx.draw(Text("OCR Text Capture").font(.system(size: 11, weight: .bold)).foregroundColor(.cyan), at: CGPoint(x: leftCard.midX, y: leftCard.minY + 18))

                for row in 0..<4 {
                    let y = leftCard.minY + 38 + CGFloat(row) * 20
                    let scanned = CGFloat(laserY) > CGFloat(row) * 0.25
                    let bar = CGRect(x: leftCard.minX + 16, y: y, width: leftCard.width - 32 - CGFloat((row % 2) * 24), height: 9)
                    ctx.fill(RoundedRectangle(cornerRadius: 4).path(in: bar), with: .color(scanned ? Color.cyan.opacity(0.55) : Color.white.opacity(0.15)))
                }

                // Laser bar
                if laserY > 0.01 && laserY < 0.99 {
                    let yPos = leftCard.minY + 32 + CGFloat(laserY) * (leftCard.height - 54)
                    var beam = Path()
                    beam.move(to: CGPoint(x: leftCard.minX + 10, y: yPos))
                    beam.addLine(to: CGPoint(x: leftCard.maxX - 10, y: yPos))
                    ctx.stroke(beam, with: .color(.cyan), lineWidth: 2.5)
                }

                if badgePop > 0.05 {
                    let pill = CGRect(x: leftCard.midX - 44, y: leftCard.maxY - 28, width: 88, height: 20)
                    ctx.fill(RoundedRectangle(cornerRadius: 10).path(in: pill), with: .color(.green.opacity(0.9 * badgePop)))
                    ctx.draw(Text("Text Copied!").font(.system(size: 10, weight: .bold)).foregroundColor(.white), at: CGPoint(x: pill.midX, y: pill.midY))
                }

                // Right Card: Floating Pin Always-On-Top
                let rightCard = CGRect(x: leftCard.maxX + 20, y: 18, width: (size.width - 68) * 0.5, height: size.height - 46)
                ctx.fill(RoundedRectangle(cornerRadius: 12).path(in: rightCard), with: .color(Color.white.opacity(0.08)))
                ctx.stroke(RoundedRectangle(cornerRadius: 12).path(in: rightCard), with: .color(.white.opacity(0.18)), lineWidth: 1)
                ctx.draw(Text("Pinned Floating Window").font(.system(size: 11, weight: .bold)).foregroundColor(.purple), at: CGPoint(x: rightCard.midX, y: rightCard.minY + 18))

                let pinRect = CGRect(
                    x: rightCard.midX - 58,
                    y: rightCard.midY - 26 + CGFloat(pinFloat),
                    width: 116,
                    height: 68
                )
                ctx.fill(RoundedRectangle(cornerRadius: 10).path(in: pinRect), with: .color(Color(red: 0.20, green: 0.18, blue: 0.34)))
                ctx.stroke(RoundedRectangle(cornerRadius: 10).path(in: pinRect), with: .color(.purple.opacity(0.85)), lineWidth: 2)
                ctx.draw(Image(systemName: "pin.fill"), at: CGPoint(x: pinRect.maxX - 14, y: pinRect.minY + 14))
                ctx.draw(Text("Always on Top").font(.system(size: 10, weight: .semibold)).foregroundColor(.white.opacity(0.85)), at: CGPoint(x: pinRect.midX, y: pinRect.midY + 6))
            }
        }
    }
}
