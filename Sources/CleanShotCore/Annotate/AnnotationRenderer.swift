import Foundation
import CoreGraphics
import CoreImage
import AppKit

public enum AnnotationRenderer {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    public struct CanvasExpansion: Equatable, Sendable {
        public let bounds: CGRect
        public let imageOffset: CGPoint
    }

    /// Computes expanded canvas bounds when annotations or combined layers extend past the base image.
    public static func computeCanvasBounds(baseSize: CGSize, state: AnnotationDocumentState) -> CanvasExpansion {
        var unionRect = CGRect(origin: .zero, size: baseSize)
        guard state.autoExpandCanvas else {
            return CanvasExpansion(bounds: unionRect, imageOffset: .zero)
        }

        for layer in state.combinedImages {
            unionRect = unionRect.union(layer.frame.cgRect)
        }

        for item in state.annotations {
            switch item.kind {
            case .arrow, .line:
                if let s = item.startPoint?.cgPoint, let e = item.endPoint?.cgPoint {
                    let pad = max(24.0, item.strokeWidth * 3)
                    let r = CGRect(
                        x: min(s.x, e.x) - pad,
                        y: min(s.y, e.y) - pad,
                        width: abs(e.x - s.x) + pad * 2,
                        height: abs(e.y - s.y) + pad * 2
                    )
                    unionRect = unionRect.union(r)
                    if let c = item.controlPoint?.cgPoint {
                        unionRect = unionRect.union(CGRect(x: c.x - pad, y: c.y - pad, width: pad * 2, height: pad * 2))
                    }
                }
            case .pencil, .highlighter:
                for p in item.points {
                    let pad = max(12.0, item.strokeWidth * 2)
                    unionRect = unionRect.union(CGRect(x: p.x - pad, y: p.y - pad, width: pad * 2, height: pad * 2))
                }
            case .spotlight:
                break
            default:
                unionRect = unionRect.union(item.rect.cgRect.insetBy(dx: -8, dy: -8))
            }
        }

        let offset = CGPoint(x: max(0, -unionRect.minX), y: max(0, -unionRect.minY))
        return CanvasExpansion(
            bounds: CGRect(x: 0, y: 0, width: ceil(unionRect.width), height: ceil(unionRect.height)),
            imageOffset: offset
        )
    }

    /// Analyzes edge margins of `image` to compute symmetrical padding around detected foreground content.
    public static func computeAutoBalanceInsets(for image: CGImage) -> NSEdgeInsets {
        let w = image.width
        let h = image.height
        guard w > 8, h > 8,
              let ctx = CGContext(
                data: nil,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return NSEdgeInsets()
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let ptr = ctx.data?.assumingMemoryBound(to: UInt8.self) else {
            return NSEdgeInsets()
        }

        let bgR = Int(ptr[0])
        let bgG = Int(ptr[1])
        let bgB = Int(ptr[2])
        let threshold = 18

        func isBackground(_ x: Int, _ y: Int) -> Bool {
            let idx = (y * w + x) * 4
            return abs(Int(ptr[idx]) - bgR) < threshold &&
                   abs(Int(ptr[idx + 1]) - bgG) < threshold &&
                   abs(Int(ptr[idx + 2]) - bgB) < threshold
        }

        var minX = w
        var maxX = -1
        var minY = h
        var maxY = -1
        let step = max(1, min(w, h) / 200)

        for y in stride(from: 0, to: h, by: step) {
            for x in stride(from: 0, to: w, by: step) {
                if !isBackground(x, y) {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
        }

        guard maxX >= minX, maxY >= minY else {
            return NSEdgeInsets()
        }

        let leftMargin = CGFloat(minX)
        let rightMargin = CGFloat(w - 1 - maxX)
        let topMargin = CGFloat(minY)
        let bottomMargin = CGFloat(h - 1 - maxY)
        let maxMargin = max(leftMargin, rightMargin, topMargin, bottomMargin)

        return NSEdgeInsets(
            top: max(0, maxMargin - topMargin),
            left: max(0, maxMargin - leftMargin),
            bottom: max(0, maxMargin - bottomMargin),
            right: max(0, maxMargin - rightMargin)
        )
    }

    public static func renderComposite(baseImage: CGImage, state: AnnotationDocumentState) -> CGImage {
        var working = applyTransformAndCrop(to: baseImage, state: state)
        working = applyRedactions(to: working, annotations: state.annotations)

        let expansion = computeCanvasBounds(
            baseSize: CGSize(width: working.width, height: working.height),
            state: state
        )

        let foregroundWidth = Int(max(1, expansion.bounds.width))
        let foregroundHeight = Int(max(1, expansion.bounds.height))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        guard let fgCtx = CGContext(
            data: nil,
            width: foregroundWidth,
            height: foregroundHeight,
            bitsPerComponent: 8,
            bytesPerRow: foregroundWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return working
        }

        // Flip to top-left origin for intuitive UI coordinates
        fgCtx.translateBy(x: 0, y: CGFloat(foregroundHeight))
        fgCtx.scaleBy(x: 1, y: -1)

        // Draw base image at expansion offset
        let baseOrigin = expansion.imageOffset
        fgCtx.saveGState()
        fgCtx.translateBy(x: baseOrigin.x, y: baseOrigin.y + CGFloat(working.height))
        fgCtx.scaleBy(x: 1, y: -1)
        fgCtx.draw(working, in: CGRect(x: 0, y: 0, width: working.width, height: working.height))
        fgCtx.restoreGState()

        // Draw combined image layers
        for layer in state.combinedImages {
            if let layerImg = CleanShotDocument.cgImage(from: layer.pngData) {
                fgCtx.saveGState()
                fgCtx.setAlpha(layer.opacity)
                let f = layer.frame.cgRect.offsetBy(dx: baseOrigin.x, dy: baseOrigin.y)
                fgCtx.translateBy(x: f.minX, y: f.maxY)
                fgCtx.scaleBy(x: 1, y: -1)
                fgCtx.draw(layerImg, in: CGRect(origin: .zero, size: f.size))
                fgCtx.restoreGState()
            }
        }

        // Draw spotlight overlay if any spotlights exist
        let spotlights = state.annotations.filter { $0.kind == .spotlight }
        if !spotlights.isEmpty {
            drawSpotlights(spotlights, in: fgCtx, canvasSize: expansion.bounds.size, offset: baseOrigin)
        }

        // Draw vector annotations
        for item in state.annotations where item.kind != .pixelate && item.kind != .blur && item.kind != .spotlight && item.kind != .cropResize {
            drawAnnotation(item, in: fgCtx, offset: baseOrigin)
        }

        guard let foregroundImage = fgCtx.makeImage() else {
            return working
        }

        if state.background.mode == .none && !state.background.autoBalanceEnabled {
            return foregroundImage
        }

        return applyBackgroundTool(to: foregroundImage, config: state.background)
    }

    private static func applyTransformAndCrop(to image: CGImage, state: AnnotationDocumentState) -> CGImage {
        var result = image

        if let crop = state.cropRect?.cgRect {
            let bounds = CGRect(x: 0, y: 0, width: result.width, height: result.height)
            let clamped = crop.intersection(bounds).integral
            if clamped.width >= 2, clamped.height >= 2, let cropped = result.cropping(to: clamped) {
                result = cropped
            }
        }

        let turns = ((state.rotationQuarterTurns % 4) + 4) % 4
        if turns == 0 && !state.flipHorizontal && !state.flipVertical {
            return result
        }

        let w = CGFloat(result.width)
        let h = CGFloat(result.height)
        let outSize = (turns % 2 == 1) ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        guard let ctx = CGContext(
            data: nil,
            width: Int(outSize.width),
            height: Int(outSize.height),
            bitsPerComponent: 8,
            bytesPerRow: Int(outSize.width) * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return result
        }

        ctx.translateBy(x: outSize.width / 2, y: outSize.height / 2)
        ctx.rotate(by: -CGFloat(turns) * .pi / 2)
        ctx.scaleBy(x: state.flipHorizontal ? -1 : 1, y: state.flipVertical ? -1 : 1)
        ctx.draw(result, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        return ctx.makeImage() ?? result
    }

    private static func applyRedactions(to image: CGImage, annotations: [AnnotationItem]) -> CGImage {
        let redactions = annotations.filter { $0.kind == .pixelate || $0.kind == .blur }
        guard !redactions.isEmpty else { return image }

        let w = image.width
        let h = image.height
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        for item in redactions {
            let topLeftRect = item.rect.cgRect.standardized
            // Convert top-left coordinate rect to CGImage pixel rect (bottom-left)
            let cgRect = CGRect(
                x: topLeftRect.minX,
                y: CGFloat(h) - topLeftRect.maxY,
                width: topLeftRect.width,
                height: topLeftRect.height
            ).intersection(CGRect(x: 0, y: 0, width: w, height: h)).integral

            guard cgRect.width >= 2, cgRect.height >= 2,
                  let subImg = image.cropping(to: CGRect(x: topLeftRect.minX, y: topLeftRect.minY, width: topLeftRect.width, height: topLeftRect.height).intersection(CGRect(x: 0, y: 0, width: w, height: h)).integral) else {
                continue
            }

            if item.kind == .pixelate {
                let randomized = applyRandomizedPixelation(to: subImg, blockSize: max(6, Int(item.redactionIntensity)), seed: item.randomSeed)
                ctx.draw(randomized, in: cgRect)
            } else {
                let blurred = applyBlur(to: subImg, radius: max(4, item.redactionIntensity), mode: item.blurMode, seed: item.randomSeed)
                ctx.draw(blurred, in: cgRect)
            }
        }
        return ctx.makeImage() ?? image
    }

    /// Security pixelation: pixelates into coarse blocks and shuffles adjacent blocks within a 3x3 neighborhood using `seed`.
    public static func applyRandomizedPixelation(to image: CGImage, blockSize: Int, seed: UInt64) -> CGImage {
        let w = image.width
        let h = image.height
        let bs = max(4, blockSize)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        guard let srcCtx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ),
        let dstCtx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        srcCtx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let srcData = srcCtx.data?.assumingMemoryBound(to: UInt8.self) else {
            return image
        }

        let cols = max(1, (w + bs - 1) / bs)
        let rows = max(1, (h + bs - 1) / bs)
        var blockColors: [(CGFloat, CGFloat, CGFloat, CGFloat)] = []
        blockColors.reserveCapacity(cols * rows)

        for r in 0..<rows {
            for c in 0..<cols {
                let startX = c * bs
                let startY = r * bs
                let endX = min(w, startX + bs)
                let endY = min(h, startY + bs)
                var sumR = 0, sumG = 0, sumB = 0, sumA = 0, count = 0
                for y in startY..<endY {
                    for x in startX..<endX {
                        let idx = (y * w + x) * 4
                        sumR += Int(srcData[idx])
                        sumG += Int(srcData[idx + 1])
                        sumB += Int(srcData[idx + 2])
                        sumA += Int(srcData[idx + 3])
                        count += 1
                    }
                }
                let denom = max(1, count) * 255
                blockColors.append((
                    CGFloat(sumR) / CGFloat(denom),
                    CGFloat(sumG) / CGFloat(denom),
                    CGFloat(sumB) / CGFloat(denom),
                    CGFloat(sumA) / CGFloat(denom)
                ))
            }
        }

        var rng = SeededGenerator(seed: seed == 0 ? 42 : seed)
        for r in 0..<rows {
            for c in 0..<cols {
                let dr = Int.random(in: -1...1, using: &rng)
                let dc = Int.random(in: -1...1, using: &rng)
                let sr = max(0, min(rows - 1, r + dr))
                let sc = max(0, min(cols - 1, c + dc))
                let color = blockColors[sr * cols + sc]
                dstCtx.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: color.3)
                dstCtx.fill(CGRect(x: c * bs, y: h - min(h, (r + 1) * bs), width: bs, height: bs))
            }
        }

        return dstCtx.makeImage() ?? image
    }

    public static func applyBlur(to image: CGImage, radius: Double, mode: BlurMode, seed: UInt64) -> CGImage {
        var input = CIImage(cgImage: image)
        if mode == .secure {
            // Downsample + subtle noise jitter before Gaussian blur so original glyph contours cannot be deconvolved
            let pixelated = applyRandomizedPixelation(to: image, blockSize: max(4, Int(radius / 2)), seed: seed)
            input = CIImage(cgImage: pixelated)
        }

        let clamped = input.clampedToExtent()
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return image }
        filter.setValue(clamped, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: image.width, height: image.height)),
              let cgOut = ciContext.createCGImage(output, from: output.extent) else {
            return image
        }
        return cgOut
    }

    private static func drawSpotlights(_ spotlights: [AnnotationItem], in ctx: CGContext, canvasSize: CGSize, offset: CGPoint) {
        ctx.saveGState()
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: canvasSize))
        for sp in spotlights {
            let r = sp.rect.cgRect.offsetBy(dx: offset.x, dy: offset.y)
            path.addRoundedRect(in: r, cornerWidth: sp.cornerRadius, cornerHeight: sp.cornerRadius)
        }
        ctx.addPath(path)
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.55))
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }

    private static func drawAnnotation(_ item: AnnotationItem, in ctx: CGContext, offset: CGPoint) {
        ctx.saveGState()
        if item.drawShadow && item.kind != .highlighter {
            ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.25))
        }

        let r = item.rect.cgRect.offsetBy(dx: offset.x, dy: offset.y).standardized
        ctx.setStrokeColor(item.color.cgColor)
        ctx.setFillColor(item.color.cgColor)
        ctx.setLineWidth(item.strokeWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch item.kind {
        case .rectangle:
            let path = CGPath(roundedRect: r, cornerWidth: item.cornerRadius, cornerHeight: item.cornerRadius, transform: nil)
            ctx.addPath(path)
            ctx.strokePath()

        case .filledRectangle:
            let path = CGPath(roundedRect: r, cornerWidth: item.cornerRadius, cornerHeight: item.cornerRadius, transform: nil)
            ctx.addPath(path)
            ctx.fillPath()

        case .ellipse:
            ctx.strokeEllipse(in: r)

        case .line:
            let s = (item.startPoint?.cgPoint ?? CGPoint(x: r.minX, y: r.minY)).applying(.init(translationX: offset.x, y: offset.y))
            let e = (item.endPoint?.cgPoint ?? CGPoint(x: r.maxX, y: r.maxY)).applying(.init(translationX: offset.x, y: offset.y))
            ctx.move(to: s)
            ctx.addLine(to: e)
            ctx.strokePath()

        case .arrow:
            let rawStart = (item.startPoint?.cgPoint ?? CGPoint(x: r.minX, y: r.minY)).applying(.init(translationX: offset.x, y: offset.y))
            let rawEnd = (item.endPoint?.cgPoint ?? CGPoint(x: r.maxX, y: r.maxY)).applying(.init(translationX: offset.x, y: offset.y))
            let s = item.invertArrow ? rawEnd : rawStart
            let e = item.invertArrow ? rawStart : rawEnd
            let ctrl = item.controlPoint?.cgPoint.applying(.init(translationX: offset.x, y: offset.y))
            drawArrow(from: s, to: e, control: ctrl, style: item.arrowStyle, width: item.strokeWidth, color: item.color.cgColor, in: ctx)

        case .pencil:
            let pts = item.points.map { CGPoint(x: $0.x + offset.x, y: $0.y + offset.y) }
            drawSmoothPath(points: pts, in: ctx)
            ctx.strokePath()

        case .highlighter:
            ctx.setBlendMode(.multiply)
            let highlightColor = item.color.nsColor.withAlphaComponent(0.42).cgColor
            ctx.setStrokeColor(highlightColor)
            ctx.setLineWidth(max(14.0, item.strokeWidth * 3.5))
            let pts = item.points.map { CGPoint(x: $0.x + offset.x, y: $0.y + offset.y) }
            if pts.count >= 2 {
                drawSmoothPath(points: pts, in: ctx)
                ctx.strokePath()
            } else {
                ctx.setFillColor(highlightColor)
                ctx.fill(r)
            }

        case .counter:
            let diameter = max(28.0, item.fontSize * 1.65)
            let center = CGPoint(x: r.midX, y: r.midY)
            let circleRect = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
            ctx.setFillColor(item.color.cgColor)
            ctx.fillEllipse(in: circleRect)
            ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95))
            ctx.setLineWidth(2.0)
            ctx.strokeEllipse(in: circleRect)
            drawCenteredText("\(item.counterNumber)", in: circleRect, font: NSFont.systemFont(ofSize: diameter * 0.52, weight: .bold), color: .white, in: ctx)

        case .text:
            drawStyledText(item, rect: r, in: ctx)

        case .select, .cropResize, .spotlight, .pixelate, .blur:
            break
        }

        ctx.restoreGState()
    }

    private static func drawArrow(from start: CGPoint, to end: CGPoint, control: CGPoint?, style: ArrowStyle, width: Double, color: CGColor, in ctx: CGContext) {
        let headLength = max(14.0, width * 3.8)
        let headAngle: CGFloat = .pi / 6.5

        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(width)

        let tangentAngleEnd: CGFloat
        if style == .curved {
            let mid = control ?? CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 - 40)
            ctx.move(to: start)
            ctx.addQuadCurve(to: end, control: mid)
            ctx.strokePath()
            tangentAngleEnd = atan2(end.y - mid.y, end.x - mid.x)
        } else {
            ctx.move(to: start)
            ctx.addLine(to: end)
            ctx.strokePath()
            tangentAngleEnd = atan2(end.y - start.y, end.x - start.x)
        }

        drawArrowHead(tip: end, angle: tangentAngleEnd, length: headLength, spread: headAngle, in: ctx)

        if style == .doubleHeaded {
            let reverseAngle = atan2(start.y - end.y, start.x - end.x)
            drawArrowHead(tip: start, angle: reverseAngle, length: headLength, spread: headAngle, in: ctx)
        }
    }

    private static func drawArrowHead(tip: CGPoint, angle: CGFloat, length: CGFloat, spread: CGFloat, in ctx: CGContext) {
        let p1 = CGPoint(x: tip.x - length * cos(angle - spread), y: tip.y - length * sin(angle - spread))
        let p2 = CGPoint(x: tip.x - length * cos(angle + spread), y: tip.y - length * sin(angle + spread))
        ctx.beginPath()
        ctx.move(to: tip)
        ctx.addLine(to: p1)
        ctx.addLine(to: p2)
        ctx.closePath()
        ctx.fillPath()
    }

    private static func drawSmoothPath(points: [CGPoint], in ctx: CGContext) {
        guard let first = points.first else { return }
        ctx.beginPath()
        ctx.move(to: first)
        if points.count == 2 {
            ctx.addLine(to: points[1])
            return
        }
        for i in 1..<points.count {
            let prev = points[i - 1]
            let curr = points[i]
            let mid = CGPoint(x: (prev.x + curr.x) / 2, y: (prev.y + curr.y) / 2)
            ctx.addQuadCurve(to: mid, control: prev)
        }
        if let last = points.last {
            ctx.addLine(to: last)
        }
    }

    private static func drawStyledText(_ item: AnnotationItem, rect: CGRect, in ctx: CGContext) {
        let text = item.text.isEmpty ? "Annotation" : item.text
        let fontSize = CGFloat(item.fontSize)
        let isMono = item.textStyle == .monospaced || item.textStyle == .monospacedBoxed
        let isRounded = item.textStyle == .rounded || item.textStyle == .roundedBoxed
        let font: NSFont = {
            if isMono { return NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold) }
            if isRounded, let desc = NSFont.systemFont(ofSize: fontSize, weight: .bold).fontDescriptor.withDesign(.rounded),
               let f = NSFont(descriptor: desc, size: fontSize) {
                return f
            }
            return NSFont.systemFont(ofSize: fontSize, weight: .bold)
        }()

        let textColor: NSColor
        switch item.textStyle {
        case .roundedBoxed, .monospacedBoxed, .boxed:
            let radius: CGFloat = item.textStyle == .boxed ? 3.0 : 10.0
            let boxPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            ctx.setFillColor(item.color.cgColor)
            ctx.addPath(boxPath)
            ctx.fillPath()
            textColor = .white
        case .outlined:
            textColor = item.color.nsColor
        case .standard, .rounded, .monospaced:
            textColor = item.color.nsColor
        }

        if item.textStyle == .outlined {
            let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsCtx
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor,
                .strokeColor: NSColor.white,
                .strokeWidth: -4.0
            ]
            (text as NSString).draw(in: rect.insetBy(dx: 8, dy: 4), withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            drawCenteredText(text, in: rect.insetBy(dx: 8, dy: 4), font: font, color: textColor, in: ctx)
        }
    }

    private static func drawCenteredText(_ text: String, in rect: CGRect, font: NSFont, color: NSColor, in ctx: CGContext) {
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let target = CGRect(
            x: rect.minX,
            y: rect.midY - size.height / 2,
            width: rect.width,
            height: size.height
        )
        (text as NSString).draw(in: target, withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }

    public static func applyBackgroundTool(to image: CGImage, config: BackgroundToolConfig) -> CGImage {
        var prepared = image
        if config.autoBalanceEnabled {
            let insets = computeAutoBalanceInsets(for: image)
            if insets.top > 0 || insets.left > 0 || insets.bottom > 0 || insets.right > 0 {
                let paddedW = image.width + Int(insets.left + insets.right)
                let paddedH = image.height + Int(insets.top + insets.bottom)
                let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
                if let bCtx = CGContext(data: nil, width: paddedW, height: paddedH, bitsPerComponent: 8, bytesPerRow: paddedW * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    // Fill with corner pixel color
                    if let firstPx = image.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1)) {
                        bCtx.draw(firstPx, in: CGRect(x: 0, y: 0, width: paddedW, height: paddedH))
                    }
                    bCtx.draw(image, in: CGRect(x: insets.left, y: insets.bottom, width: CGFloat(image.width), height: CGFloat(image.height)))
                    if let balanced = bCtx.makeImage() {
                        prepared = balanced
                    }
                }
            }
        }

        if config.mode == .none {
            return prepared
        }

        let pad = CGFloat(config.padding)
        let fgW = CGFloat(prepared.width)
        let fgH = CGFloat(prepared.height)
        var outW = fgW + pad * 2
        var outH = fgH + pad * 2

        if let targetRatio = config.aspectRatioPreset.ratio {
            let currentRatio = outW / max(1, outH)
            if currentRatio < targetRatio {
                outW = outH * targetRatio
            } else {
                outH = outW / targetRatio
            }
        }

        let finalW = Int(ceil(outW))
        let finalH = Int(ceil(outH))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: finalW,
            height: finalH,
            bitsPerComponent: 8,
            bytesPerRow: finalW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return prepared
        }

        let canvasRect = CGRect(x: 0, y: 0, width: finalW, height: finalH)
        drawBackgroundBackdrop(config: config, sourceImage: prepared, in: ctx, rect: canvasRect)

        // Position foreground screenshot inside canvas per alignment
        let fgX: CGFloat
        let fgY: CGFloat
        switch config.insetAlignment {
        case .center:
            fgX = (CGFloat(finalW) - fgW) / 2
            fgY = (CGFloat(finalH) - fgH) / 2
        case .top:
            fgX = (CGFloat(finalW) - fgW) / 2
            fgY = CGFloat(finalH) - fgH - pad
        case .bottom:
            fgX = (CGFloat(finalW) - fgW) / 2
            fgY = pad
        case .left:
            fgX = pad
            fgY = (CGFloat(finalH) - fgH) / 2
        case .right:
            fgX = CGFloat(finalW) - fgW - pad
            fgY = (CGFloat(finalH) - fgH) / 2
        }

        let fgRect = CGRect(x: fgX, y: fgY, width: fgW, height: fgH)

        // Draw shadow + rounded clipped foreground
        ctx.saveGState()
        if config.shadowRadius > 0 && config.shadowOpacity > 0 {
            ctx.setShadow(
                offset: CGSize(width: 0, height: -config.shadowRadius * 0.25),
                blur: config.shadowRadius,
                color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: config.shadowOpacity)
            )
            let shadowPath = CGPath(roundedRect: fgRect, cornerWidth: config.cornerRadius, cornerHeight: config.cornerRadius, transform: nil)
            ctx.addPath(shadowPath)
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ctx.fillPath()
        }
        ctx.restoreGState()

        ctx.saveGState()
        let clipPath = CGPath(roundedRect: fgRect, cornerWidth: config.cornerRadius, cornerHeight: config.cornerRadius, transform: nil)
        ctx.addPath(clipPath)
        ctx.clip()
        ctx.draw(prepared, in: fgRect)
        ctx.restoreGState()

        return ctx.makeImage() ?? prepared
    }

    private static func drawBackgroundBackdrop(config: BackgroundToolConfig, sourceImage: CGImage, in ctx: CGContext, rect: CGRect) {
        switch config.mode {
        case .none:
            break
        case .plainColor:
            ctx.setFillColor(config.plainColor.cgColor)
            ctx.fill(rect)
        case .blurred:
            let blurred = applyBlur(to: sourceImage, radius: 42, mode: .smooth, seed: 1)
            ctx.draw(blurred, in: rect)
        case .customImage:
            if let data = config.customImageData, let customCG = CleanShotDocument.cgImage(from: data) {
                ctx.draw(customCG, in: rect)
            } else {
                drawPresetGradient(index: 0, in: ctx, rect: rect)
            }
        case .gradient, .wallpaper:
            drawPresetGradient(index: config.selectedBuiltInIndex, in: ctx, rect: rect)
        }
    }

    private static func drawPresetGradient(index: Int, in ctx: CGContext, rect: CGRect) {
        let presets = BackgroundToolConfig.builtInBackgrounds
        let preset = presets[max(0, min(presets.count - 1, index))]
        let c1 = CodableColor(hex: preset.startHex).cgColor
        let c2 = CodableColor(hex: preset.endHex).cgColor
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let gradient = CGGradient(colorsSpace: cs, colors: [c1, c2] as CFArray, locations: [0, 1]) else { return }

        let rad = CGFloat(preset.angleDegrees) * .pi / 180.0
        let dx = cos(rad) * rect.width * 0.5
        let dy = sin(rad) * rect.height * 0.5
        let center = CGPoint(x: rect.midX, y: rect.midY)
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: center.x - dx, y: center.y - dy),
            end: CGPoint(x: center.x + dx, y: center.y + dy),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
