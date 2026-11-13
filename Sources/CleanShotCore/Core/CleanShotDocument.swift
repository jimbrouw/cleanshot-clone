import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public struct CleanShotProjectManifest: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var documentState: AnnotationDocumentState

    public init(
        formatVersion: Int = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        documentState: AnnotationDocumentState
    ) {
        self.formatVersion = formatVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.documentState = documentState
    }
}

public enum CleanShotDocumentError: Error, LocalizedError {
    case invalidBaseImage
    case missingBaseImage
    case encodingFailed
    case invalidManifest

    public var errorDescription: String? {
        switch self {
        case .invalidBaseImage: return "Unable to decode base screenshot image."
        case .missingBaseImage: return "The .cleanshot bundle does not contain base.png."
        case .encodingFailed: return "Failed to encode PNG data for .cleanshot bundle."
        case .invalidManifest: return "Unable to parse project.json in .cleanshot bundle."
        }
    }
}

public struct CleanShotDocument: Sendable {
    public var baseImage: CGImage
    public var manifest: CleanShotProjectManifest

    public init(baseImage: CGImage, manifest: CleanShotProjectManifest) {
        self.baseImage = baseImage
        self.manifest = manifest
    }

    public init(baseImage: CGImage, state: AnnotationDocumentState = AnnotationDocumentState()) {
        self.baseImage = baseImage
        self.manifest = CleanShotProjectManifest(documentState: state)
    }

    public func save(to bundleURL: URL) throws {
        let fm = FileManager.default
        let targetURL = bundleURL.pathExtension.lowercased() == "cleanshot"
            ? bundleURL
            : bundleURL.appendingPathExtension("cleanshot")

        let tempURL = targetURL.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).cleanshot.tmp", isDirectory: true)
        try fm.createDirectory(at: tempURL, withIntermediateDirectories: true)

        guard let basePNG = Self.pngData(from: baseImage) else {
            throw CleanShotDocumentError.encodingFailed
        }
        try basePNG.write(to: tempURL.appendingPathComponent("base.png"))

        let composite = AnnotationRenderer.renderComposite(baseImage: baseImage, state: manifest.documentState)
        if let previewPNG = Self.pngData(from: composite) {
            try previewPNG.write(to: tempURL.appendingPathComponent("preview.png"))
        }

        var updatedManifest = manifest
        updatedManifest.updatedAt = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(updatedManifest)
        try jsonData.write(to: tempURL.appendingPathComponent("project.json"))

        if fm.fileExists(atPath: targetURL.path) {
            try fm.removeItem(at: targetURL)
        }
        try fm.moveItem(at: tempURL, to: targetURL)
    }

    public static func load(from bundleURL: URL) throws -> CleanShotDocument {
        let baseURL = bundleURL.appendingPathComponent("base.png")
        let manifestURL = bundleURL.appendingPathComponent("project.json")

        guard FileManager.default.fileExists(atPath: baseURL.path) else {
            throw CleanShotDocumentError.missingBaseImage
        }
        guard let baseData = try? Data(contentsOf: baseURL),
              let baseImage = cgImage(from: baseData) else {
            throw CleanShotDocumentError.invalidBaseImage
        }
        guard let jsonData = try? Data(contentsOf: manifestURL) else {
            throw CleanShotDocumentError.invalidManifest
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(CleanShotProjectManifest.self, from: jsonData)
        return CleanShotDocument(baseImage: baseImage, manifest: manifest)
    }

    public static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    public static func cgImage(from data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
