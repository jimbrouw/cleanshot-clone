import Foundation
import CoreGraphics
import AppKit

public enum AnnotationToolKind: String, Codable, CaseIterable, Sendable {
    case select
    case cropResize
    case arrow
    case rectangle
    case filledRectangle
    case ellipse
    case line
    case pencil
    case highlighter
    case text
    case counter
    case spotlight
    case pixelate
    case blur
}

public enum ArrowStyle: String, Codable, CaseIterable, Sendable {
    case straight
    case curved
    case tapered
    case doubleHeaded
}

public enum BlurMode: String, Codable, CaseIterable, Sendable {
    case smooth
    case secure
}

public enum TextAnnotationStyle: String, Codable, CaseIterable, Sendable {
    case standard = "Standard"
    case roundedBoxed = "Rounded Boxed"
    case rounded = "Rounded"
    case monospaced = "Monospaced"
    case monospacedBoxed = "Monospaced Boxed"
    case outlined = "Outlined"
    case boxed = "Boxed"
}

public struct CodableColor: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init(hex: String, alpha: Double = 1.0) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)
        if cleaned.count == 6 {
            self.red = Double((int >> 16) & 0xFF) / 255.0
            self.green = Double((int >> 8) & 0xFF) / 255.0
            self.blue = Double(int & 0xFF) / 255.0
            self.alpha = alpha
        } else if cleaned.count == 8 {
            self.red = Double((int >> 24) & 0xFF) / 255.0
            self.green = Double((int >> 16) & 0xFF) / 255.0
            self.blue = Double((int >> 8) & 0xFF) / 255.0
            self.alpha = Double(int & 0xFF) / 255.0
        } else {
            self.red = 0.05
            self.green = 0.27
            self.blue = 0.91
            self.alpha = alpha
        }
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    public var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    public var hexString: String {
        let r = Int(round(max(0, min(1, red)) * 255))
        let g = Int(round(max(0, min(1, green)) * 255))
        let b = Int(round(max(0, min(1, blue)) * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

public struct CodablePoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public init(_ point: CGPoint) {
        self.x = point.x
        self.y = point.y
    }

    public var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

public struct CodableRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rect: CGRect) {
        self.x = rect.origin.x
        self.y = rect.origin.y
        self.width = rect.size.width
        self.height = rect.size.height
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

public struct AnnotationItem: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: AnnotationToolKind
    public var rect: CodableRect
    public var startPoint: CodablePoint?
    public var endPoint: CodablePoint?
    public var controlPoint: CodablePoint?
    public var points: [CodablePoint]
    public var color: CodableColor
    public var strokeWidth: Double
    public var cornerRadius: Double
    public var arrowStyle: ArrowStyle
    public var invertArrow: Bool
    public var text: String
    public var fontSize: Double
    public var textStyle: TextAnnotationStyle
    public var counterNumber: Int
    public var blurMode: BlurMode
    public var redactionIntensity: Double
    public var randomSeed: UInt64
    public var drawShadow: Bool

    public init(
        id: UUID = UUID(),
        kind: AnnotationToolKind,
        rect: CodableRect = CodableRect(x: 0, y: 0, width: 100, height: 60),
        startPoint: CodablePoint? = nil,
        endPoint: CodablePoint? = nil,
        controlPoint: CodablePoint? = nil,
        points: [CodablePoint] = [],
        color: CodableColor = CodableColor(hex: "#0D44E8"),
        strokeWidth: Double = 4.0,
        cornerRadius: Double = 6.0,
        arrowStyle: ArrowStyle = .straight,
        invertArrow: Bool = false,
        text: String = "",
        fontSize: Double = 18.0,
        textStyle: TextAnnotationStyle = .roundedBoxed,
        counterNumber: Int = 1,
        blurMode: BlurMode = .secure,
        redactionIntensity: Double = 16.0,
        randomSeed: UInt64 = UInt64.random(in: 1...UInt64.max),
        drawShadow: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.rect = rect
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.controlPoint = controlPoint
        self.points = points
        self.color = color
        self.strokeWidth = strokeWidth
        self.cornerRadius = cornerRadius
        self.arrowStyle = arrowStyle
        self.invertArrow = invertArrow
        self.text = text
        self.fontSize = fontSize
        self.textStyle = textStyle
        self.counterNumber = counterNumber
        self.blurMode = blurMode
        self.redactionIntensity = redactionIntensity
        self.randomSeed = randomSeed
        self.drawShadow = drawShadow
    }
}

public struct CombinedImageLayer: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var pngData: Data
    public var frame: CodableRect
    public var opacity: Double

    public init(id: UUID = UUID(), pngData: Data, frame: CodableRect, opacity: Double = 1.0) {
        self.id = id
        self.pngData = pngData
        self.frame = frame
        self.opacity = opacity
    }
}

public enum BackgroundMode: String, Codable, CaseIterable, Sendable {
    case none
    case gradient
    case wallpaper
    case blurred
    case plainColor
    case customImage
}

public enum AspectRatioPreset: String, Codable, CaseIterable, Sendable {
    case auto = "Auto"
    case r16_9 = "16:9"
    case r4_3 = "4:3"
    case r1_1 = "1:1"
    case r9_16 = "9:16"
    case twitter = "16:9 Social"
    case instagram = "4:5 Portrait"

    public var ratio: Double? {
        switch self {
        case .auto: return nil
        case .r16_9, .twitter: return 16.0 / 9.0
        case .r4_3: return 4.0 / 3.0
        case .r1_1: return 1.0
        case .r9_16: return 9.0 / 16.0
        case .instagram: return 4.0 / 5.0
        }
    }
}

public enum BackgroundInsetAlignment: String, Codable, CaseIterable, Sendable {
    case center
    case top
    case bottom
    case left
    case right
}

public struct BackgroundGradientPreset: Identifiable, Codable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let startHex: String
    public let endHex: String
    public let angleDegrees: Double

    public init(id: Int, name: String, startHex: String, endHex: String, angleDegrees: Double = 135) {
        self.id = id
        self.name = name
        self.startHex = startHex
        self.endHex = endHex
        self.angleDegrees = angleDegrees
    }
}

public struct BackgroundToolConfig: Codable, Equatable, Sendable {
    public var mode: BackgroundMode
    public var selectedBuiltInIndex: Int // 0..<20 (12 gradients + 8 procedural wallpapers)
    public var plainColor: CodableColor
    public var customImageData: Data?
    public var padding: Double
    public var cornerRadius: Double
    public var shadowRadius: Double
    public var shadowOpacity: Double
    public var insetAlignment: BackgroundInsetAlignment
    public var aspectRatioPreset: AspectRatioPreset
    public var autoBalanceEnabled: Bool

    public init(
        mode: BackgroundMode = .none,
        selectedBuiltInIndex: Int = 0,
        plainColor: CodableColor = CodableColor(hex: "#E2E8F0"),
        customImageData: Data? = nil,
        padding: Double = 48.0,
        cornerRadius: Double = 14.0,
        shadowRadius: Double = 24.0,
        shadowOpacity: Double = 0.35,
        insetAlignment: BackgroundInsetAlignment = .center,
        aspectRatioPreset: AspectRatioPreset = .auto,
        autoBalanceEnabled: Bool = false
    ) {
        self.mode = mode
        self.selectedBuiltInIndex = selectedBuiltInIndex
        self.plainColor = plainColor
        self.customImageData = customImageData
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadowRadius = shadowRadius
        self.shadowOpacity = shadowOpacity
        self.insetAlignment = insetAlignment
        self.aspectRatioPreset = aspectRatioPreset
        self.autoBalanceEnabled = autoBalanceEnabled
    }

    // 20 built-in backgrounds (12 gradients + 8 multi-stop atmospheric wallpapers) matching CleanShot X's "20 built-in backgrounds"
    public static let builtInBackgrounds: [BackgroundGradientPreset] = [
        BackgroundGradientPreset(id: 0, name: "Oceanic Blue", startHex: "#0D44E8", endHex: "#38BDF8", angleDegrees: 135),
        BackgroundGradientPreset(id: 1, name: "Sunset Coral", startHex: "#FF512F", endHex: "#F09819", angleDegrees: 120),
        BackgroundGradientPreset(id: 2, name: "Royal Iris", startHex: "#6366F1", endHex: "#EC4899", angleDegrees: 145),
        BackgroundGradientPreset(id: 3, name: "Emerald Mist", startHex: "#059669", endHex: "#34D399", angleDegrees: 135),
        BackgroundGradientPreset(id: 4, name: "Midnight Slate", startHex: "#0F172A", endHex: "#334155", angleDegrees: 160),
        BackgroundGradientPreset(id: 5, name: "Peach Cream", startHex: "#FB7185", endHex: "#FDE047", angleDegrees: 125),
        BackgroundGradientPreset(id: 6, name: "Nordic Ice", startHex: "#E0F2FE", endHex: "#C7D2FE", angleDegrees: 135),
        BackgroundGradientPreset(id: 7, name: "Violet Dusk", startHex: "#4C1D95", endHex: "#9425E7", angleDegrees: 140),
        BackgroundGradientPreset(id: 8, name: "Amber Gold", startHex: "#D97706", endHex: "#FBBF24", angleDegrees: 135),
        BackgroundGradientPreset(id: 9, name: "Berry Rose", startHex: "#BE185D", endHex: "#FB7185", angleDegrees: 135),
        BackgroundGradientPreset(id: 10, name: "Teal Lagoon", startHex: "#0F766E", endHex: "#2DD4BF", angleDegrees: 135),
        BackgroundGradientPreset(id: 11, name: "Minimal Silver", startHex: "#F1F5F9", endHex: "#CBD5E1", angleDegrees: 180),
        // 8 mesh/wallpaper presets (12...19)
        BackgroundGradientPreset(id: 12, name: "Aurora Mesh", startHex: "#0EA5E9", endHex: "#8B5CF6", angleDegrees: 45),
        BackgroundGradientPreset(id: 13, name: "Sonoma Bloom", startHex: "#2563EB", endHex: "#F97316", angleDegrees: 60),
        BackgroundGradientPreset(id: 14, name: "Ventura Silk", startHex: "#1E3A8A", endHex: "#F59E0B", angleDegrees: 110),
        BackgroundGradientPreset(id: 15, name: "Monterey Wave", startHex: "#312E81", endHex: "#C026D3", angleDegrees: 150),
        BackgroundGradientPreset(id: 16, name: "Desert Dune", startHex: "#FDBA74", endHex: "#E11D48", angleDegrees: 90),
        BackgroundGradientPreset(id: 17, name: "Forest Canopy", startHex: "#064E3B", endHex: "#84CC16", angleDegrees: 130),
        BackgroundGradientPreset(id: 18, name: "Graphite Studio", startHex: "#18181B", endHex: "#52525B", angleDegrees: 135),
        BackgroundGradientPreset(id: 19, name: "Cotton Candy", startHex: "#A5B4FC", endHex: "#FBCFE8", angleDegrees: 135)
    ]
}

public struct BrandPreset: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var config: BackgroundToolConfig

    public init(id: UUID = UUID(), name: String, config: BackgroundToolConfig) {
        self.id = id
        self.name = name
        self.config = config
    }
}

public struct AnnotationDocumentState: Codable, Equatable, Sendable {
    public var annotations: [AnnotationItem]
    public var combinedImages: [CombinedImageLayer]
    public var cropRect: CodableRect?
    public var rotationQuarterTurns: Int
    public var flipHorizontal: Bool
    public var flipVertical: Bool
    public var background: BackgroundToolConfig
    public var autoExpandCanvas: Bool

    public init(
        annotations: [AnnotationItem] = [],
        combinedImages: [CombinedImageLayer] = [],
        cropRect: CodableRect? = nil,
        rotationQuarterTurns: Int = 0,
        flipHorizontal: Bool = false,
        flipVertical: Bool = false,
        background: BackgroundToolConfig = BackgroundToolConfig(),
        autoExpandCanvas: Bool = true
    ) {
        self.annotations = annotations
        self.combinedImages = combinedImages
        self.cropRect = cropRect
        self.rotationQuarterTurns = rotationQuarterTurns
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
        self.background = background
        self.autoExpandCanvas = autoExpandCanvas
    }
}
