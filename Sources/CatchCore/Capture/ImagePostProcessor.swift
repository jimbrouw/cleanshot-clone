import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

public enum ImagePostProcessor {
    public static func convertToSRGB(_ image: CGImage) -> CGImage {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return image }
        if image.colorSpace?.name == CGColorSpace.sRGB {
            return image
        }
        guard let ctx = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: srgb,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    public static func scaleTo1x(_ image: CGImage, scaleFactor: CGFloat) -> CGImage {
        guard scaleFactor > 1.01 else { return image }
        let targetW = max(1, Int(round(CGFloat(image.width) / scaleFactor)))
        let targetH = max(1, Int(round(CGFloat(image.height) / scaleFactor)))
        let cs = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: targetW * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        return ctx.makeImage() ?? image
    }

    public static func add1pxBorder(_ image: CGImage, borderColor: CGColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.25)) -> CGImage {
        let w = image.width
        let h = image.height
        let cs = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setStrokeColor(borderColor)
        ctx.setLineWidth(1.0)
        ctx.stroke(CGRect(x: 0.5, y: 0.5, width: CGFloat(w) - 1.0, height: CGFloat(h) - 1.0))
        return ctx.makeImage() ?? image
    }

    public static func renderWindowCapture(
        windowImage: CGImage,
        mode: WindowBackgroundMode,
        wallpaper: CGImage? = nil,
        plainColor: NSColor = NSColor(srgbRed: 0.12, green: 0.16, blue: 0.23, alpha: 1.0),
        padding: CGFloat = 40,
        includeShadow: Bool = true
    ) -> CGImage {
        let shadowPad: CGFloat = includeShadow ? 28 : 0
        let totalPad = mode == .withWallpaper ? max(0, padding) : shadowPad
        let outW = Int(CGFloat(windowImage.width) + totalPad * 2)
        let outH = Int(CGFloat(windowImage.height) + totalPad * 2)
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        guard let ctx = CGContext(
            data: nil,
            width: max(1, outW),
            height: max(1, outH),
            bitsPerComponent: 8,
            bytesPerRow: max(1, outW) * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return windowImage
        }

        let canvasRect = CGRect(x: 0, y: 0, width: outW, height: outH)
        if mode == .withWallpaper {
            if let wallpaper {
                ctx.draw(wallpaper, in: canvasRect)
            } else {
                ctx.setFillColor(plainColor.cgColor)
                ctx.fill(canvasRect)
            }
        } else {
            ctx.clear(canvasRect)
        }

        let winRect = CGRect(x: totalPad, y: totalPad, width: CGFloat(windowImage.width), height: CGFloat(windowImage.height))
        if includeShadow {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35))
            ctx.draw(windowImage, in: winRect)
            ctx.restoreGState()
        } else {
            ctx.draw(windowImage, in: winRect)
        }
        return ctx.makeImage() ?? windowImage
    }

    public static func applySettingsPipeline(to image: CGImage, scaleFactor: CGFloat, settings: SettingsStore = .shared, bypassBackgroundPreset: Bool = false) -> CGImage {
        var result = image
        if settings.convertToSRGB {
            result = convertToSRGB(result)
        }
        if settings.scaleRetinaTo1x {
            result = scaleTo1x(result, scaleFactor: scaleFactor)
        }
        if settings.add1pxBorder {
            result = add1pxBorder(result)
        }
        if !bypassBackgroundPreset, let presetId = settings.defaultBackgroundPresetId, let idx = Int(presetId) {
            let bg = BackgroundToolConfig(mode: .gradient, selectedBuiltInIndex: idx)
            result = AnnotationRenderer.applyBackgroundTool(to: result, config: bg)
        }
        return result
    }

    public static func encode(image: CGImage, format: ScreenshotFormat, quality: Double = 0.92) -> Data? {
        let utType: UTType = {
            switch format {
            case .png: return .png
            case .jpeg: return .jpeg
            case .heic: return .heic
            case .webp: return .webP
            }
        }()

        let data = NSMutableData()
        var dest = CGImageDestinationCreateWithData(data, utType.identifier as CFString, 1, nil)
        if dest == nil && format == .webp {
            dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        }
        guard let destination = dest else { return nil }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
