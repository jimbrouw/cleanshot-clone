import Foundation
import AppKit
import CoreGraphics
import Vision
import Combine

// MARK: - Models

public enum ClipboardCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case all
    case text
    case image
    case file
    case link
    case email
    case color

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: return "All Types"
        case .text: return "Text Only"
        case .image: return "Images Only"
        case .file: return "Files Only"
        case .link: return "Links Only"
        case .email: return "Emails Only"
        case .color: return "Colors Only"
        }
    }

    public var typeLabel: String {
        switch self {
        case .all: return "All"
        case .text: return "Text"
        case .image: return "Image"
        case .file: return "File"
        case .link: return "Link"
        case .email: return "Email"
        case .color: return "Color"
        }
    }

    public var systemImage: String {
        switch self {
        case .all: return "list.bullet"
        case .text: return "doc.plaintext"
        case .image: return "photo"
        case .file: return "doc"
        case .link: return "link"
        case .email: return "at"
        case .color: return "eyedropper"
        }
    }
}

public enum ClipboardTagColor: String, Codable, CaseIterable, Sendable {
    case accent
    case green
    case blue
    case yellow
    case orange
    case red
    case magenta
    case purple
}

public struct ClipboardAppFilterRule: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var bundleIdentifier: String
    public var appName: String
    public var tags: [String]
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        bundleIdentifier: String,
        appName: String,
        tags: [String],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.tags = tags
        self.isEnabled = isEnabled
    }
}

public struct ClipboardEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var customTitle: String?
    public var categories: [ClipboardCategory]
    public var text: String?
    public var imagePNGData: Data?
    public var imageWidth: Int?
    public var imageHeight: Int?
    public var fileURLPath: String?
    public var fileSize: Int64?
    public var colorHex: String?
    public var recognizedOCRText: String?
    public var qrPayloads: [String]
    public var sourceAppName: String
    public var sourceAppBundleID: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var copyCount: Int
    public var pinnedOrder: Int?
    public var tags: [String]

    public init(
        id: UUID = UUID(),
        title: String,
        customTitle: String? = nil,
        categories: [ClipboardCategory],
        text: String? = nil,
        imagePNGData: Data? = nil,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil,
        fileURLPath: String? = nil,
        fileSize: Int64? = nil,
        colorHex: String? = nil,
        recognizedOCRText: String? = nil,
        qrPayloads: [String] = [],
        sourceAppName: String = "System",
        sourceAppBundleID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        copyCount: Int = 1,
        pinnedOrder: Int? = nil,
        tags: [String] = []
    ) {
        self.id = id
        self.title = title
        self.customTitle = customTitle
        self.categories = categories
        self.text = text
        self.imagePNGData = imagePNGData
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.fileURLPath = fileURLPath
        self.fileSize = fileSize
        self.colorHex = colorHex
        self.recognizedOCRText = recognizedOCRText
        self.qrPayloads = qrPayloads
        self.sourceAppName = sourceAppName
        self.sourceAppBundleID = sourceAppBundleID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.copyCount = copyCount
        self.pinnedOrder = pinnedOrder
        self.tags = tags
    }

    public var isPinned: Bool { pinnedOrder != nil }

    public var displayTitle: String {
        if let custom = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return custom
        }
        return title
    }

    public var primaryCategory: ClipboardCategory {
        if categories.contains(.color) { return .color }
        if categories.contains(.email) { return .email }
        if categories.contains(.link) { return .link }
        if categories.contains(.image) { return .image }
        if categories.contains(.file) { return .file }
        return categories.first ?? .text
    }

    public var characterCount: Int {
        text?.count ?? 0
    }

    public var wordCount: Int {
        guard let text else { return 0 }
        return text.split { $0.isWhitespace || $0.isNewline }.count
    }

    public var formattedJSON: String? {
        guard let text else { return nil }
        return ClipboardSmartDetector.prettyPrintedJSON(from: text)
    }

    public var colorFormats: [(label: String, value: String)] {
        guard let hex = colorHex else { return [] }
        return ClipboardSmartDetector.colorFormats(fromHex: hex)
    }

    public func timeSectionTitle(referenceDate: Date = Date(), calendar: Calendar = .current) -> String {
        if isPinned { return "Pinned" }
        if calendar.isDateInToday(updatedAt) { return "Today" }
        if calendar.isDateInYesterday(updatedAt) { return "Yesterday" }
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: referenceDate), updatedAt >= weekAgo {
            return "This Week"
        }
        if let monthAgo = calendar.date(byAdding: .month, value: -1, to: referenceDate), updatedAt >= monthAgo {
            return "This Month"
        }
        return "Older"
    }

    public var contentSignature: String {
        if let path = fileURLPath {
            return "file:\(path)"
        }
        if let hex = colorHex {
            return "color:\(hex)"
        }
        if let text {
            return "text:\(text)"
        }
        if let data = imagePNGData {
            return "img:\(data.count):\(data.prefix(64).base64EncodedString())"
        }
        return "id:\(id.uuidString)"
    }
}

// MARK: - Smart Detectors (Color, Link, Email, JSON)

public enum ClipboardSmartDetector {
    public struct ColorComponents: Equatable, Sendable {
        public let red: Double   // 0...1
        public let green: Double // 0...1
        public let blue: Double  // 0...1

        public var hex: String {
            let r = Int(round(max(0, min(1, red)) * 255))
            let g = Int(round(max(0, min(1, green)) * 255))
            let b = Int(round(max(0, min(1, blue)) * 255))
            return String(format: "#%02X%02X%02X", r, g, b)
        }
    }

    public static func detectCategories(for text: String) -> (categories: [ClipboardCategory], normalizedHex: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var categories: [ClipboardCategory] = [.text]
        var normalizedHex: String?

        if let color = parseColor(trimmed) {
            categories.append(.color)
            normalizedHex = color.hex
        }
        if isEmail(trimmed) {
            categories.append(.email)
            categories.append(.link)
        } else if isWebURL(trimmed) {
            categories.append(.link)
        }
        return (categories, normalizedHex)
    }

    public static func parseColor(_ input: String) -> ColorComponents? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 48 else { return nil }

        // #RGB, #RRGGBB, #RRGGBBAA
        if trimmed.hasPrefix("#") {
            let hex = String(trimmed.dropFirst())
            guard hex.allSatisfy({ $0.isHexDigit }) else { return nil }
            if hex.count == 3 {
                let chars = Array(hex)
                let r = Int(String([chars[0], chars[0]]), radix: 16) ?? 0
                let g = Int(String([chars[1], chars[1]]), radix: 16) ?? 0
                let b = Int(String([chars[2], chars[2]]), radix: 16) ?? 0
                return ColorComponents(red: Double(r) / 255.0, green: Double(g) / 255.0, blue: Double(b) / 255.0)
            } else if hex.count == 6 || hex.count == 8 {
                let rStr = String(hex.prefix(2))
                let gStr = String(hex.dropFirst(2).prefix(2))
                let bStr = String(hex.dropFirst(4).prefix(2))
                guard let r = Int(rStr, radix: 16),
                      let g = Int(gStr, radix: 16),
                      let b = Int(bStr, radix: 16) else { return nil }
                return ColorComponents(red: Double(r) / 255.0, green: Double(g) / 255.0, blue: Double(b) / 255.0)
            }
            return nil
        }

        // rgb(r, g, b) or rgba(r, g, b, a)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("rgb(") || lower.hasPrefix("rgba("), lower.hasSuffix(")") {
            let inner = lower.drop(while: { $0 != "(" }).dropFirst().dropLast()
            let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 3,
               let r = Double(parts[0]), let g = Double(parts[1]), let b = Double(parts[2]),
               (0...255).contains(r), (0...255).contains(g), (0...255).contains(b) {
                return ColorComponents(red: r / 255.0, green: g / 255.0, blue: b / 255.0)
            }
        }

        // hsl(h, s%, l%)
        if lower.hasPrefix("hsl(") || lower.hasPrefix("hsla("), lower.hasSuffix(")") {
            let inner = lower.drop(while: { $0 != "(" }).dropFirst().dropLast()
            let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " %")) }
            if parts.count >= 3,
               let hDeg = Double(parts[0]),
               let sPct = Double(parts[1]),
               let lPct = Double(parts[2]) {
                let (r, g, b) = hslToRGB(h: hDeg, s: sPct / 100.0, l: lPct / 100.0)
                return ColorComponents(red: r, green: g, blue: b)
            }
        }

        return nil
    }

    public static func colorFormats(fromHex hex: String) -> [(label: String, value: String)] {
        guard let c = parseColor(hex) else { return [] }
        let r = Int(round(c.red * 255))
        let g = Int(round(c.green * 255))
        let b = Int(round(c.blue * 255))
        let (h, s, l) = rgbToHSL(r: c.red, g: c.green, b: c.blue)
        return [
            ("HEX", c.hex),
            ("RGB", "rgb(\(r), \(g), \(b))"),
            ("HSL", "hsl(\(Int(round(h))), \(Int(round(s * 100)))%, \(Int(round(l * 100)))%)"),
            ("SwiftUI", String(format: "Color(red: %.3f, green: %.3f, blue: %.3f)", c.red, c.green, c.blue))
        ]
    }

    public static func isEmail(_ text: String) -> Bool {
        let pattern = #"^[A-Z0-9a-z._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,64}$"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    public static func isWebURL(_ text: String) -> Bool {
        guard !text.contains("\n"), !text.contains(" ") else { return false }
        let lower = text.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return false }
        guard let url = URL(string: text), let host = url.host, host.contains(".") else { return false }
        return true
    }

    public static func prettyPrintedJSON(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) ||
              (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")),
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let formatted = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let result = String(data: formatted, encoding: .utf8) else {
            return nil
        }
        return result
    }

    private static func rgbToHSL(r: Double, g: Double, b: Double) -> (Double, Double, Double) {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC
        let l = (maxC + minC) / 2.0
        var h: Double = 0
        var s: Double = 0
        if delta > 0.0001 {
            s = delta / (1.0 - abs(2.0 * l - 1.0))
            if maxC == r {
                h = 60.0 * (((g - b) / delta).truncatingRemainder(dividingBy: 6.0))
            } else if maxC == g {
                h = 60.0 * (((b - r) / delta) + 2.0)
            } else {
                h = 60.0 * (((r - g) / delta) + 4.0)
            }
            if h < 0 { h += 360.0 }
        }
        return (h, s, l)
    }

    private static func hslToRGB(h: Double, s: Double, l: Double) -> (Double, Double, Double) {
        let c = (1.0 - abs(2.0 * l - 1.0)) * max(0, min(1, s))
        let hPrime = (h.truncatingRemainder(dividingBy: 360.0) + 360.0).truncatingRemainder(dividingBy: 360.0) / 60.0
        let x = c * (1.0 - abs(hPrime.truncatingRemainder(dividingBy: 2.0) - 1.0))
        let m = l - c / 2.0
        let rgb: (Double, Double, Double)
        switch Int(hPrime) {
        case 0: rgb = (c, x, 0)
        case 1: rgb = (x, c, 0)
        case 2: rgb = (0, c, x)
        case 3: rgb = (0, x, c)
        case 4: rgb = (x, 0, c)
        default: rgb = (c, 0, x)
        }
        return (rgb.0 + m, rgb.1 + m, rgb.2 + m)
    }
}

// MARK: - Store

public final class ClipboardHistoryStore: ObservableObject {
    public static let shared = ClipboardHistoryStore()

    @Published public private(set) var entries: [ClipboardEntry] = []
    @Published public var appFilterRules: [ClipboardAppFilterRule] = []
    @Published public var sequentialPasteIndex: Int = 0
    @Published public var sequentialPasteDeadline: Date?

    public let maxEntries: Int
    public var disabledAppBundleIDs: Set<String> = [
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop"
    ]

    private let storageURL: URL?
    private let defaults: UserDefaults
    private var pollTimer: Timer?
    private var lastObservedChangeCount: Int
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public static var defaultStorageURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = appSupport.appendingPathComponent("CleanShotClone", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("clipboard-history.json")
    }

    public convenience init() {
        self.init(storageURL: Self.defaultStorageURL, defaults: .standard)
    }

    public init(storageURL: URL?, defaults: UserDefaults = .standard, maxEntries: Int = 500) {
        self.storageURL = storageURL
        self.defaults = defaults
        self.maxEntries = maxEntries
        self.lastObservedChangeCount = NSPasteboard.general.changeCount
        self.encoder.outputFormatting = [.prettyPrinted]
        loadFromDisk()
        pruneExpired(days: SettingsStore.shared.clipboardRetentionDays)
    }

    public var allTags: [String] {
        var set = Set<String>()
        for entry in entries {
            for tag in entry.tags { set.insert(tag) }
        }
        for rule in appFilterRules {
            for tag in rule.tags { set.insert(tag) }
        }
        return Array(set).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: - Live NSPasteboard Monitoring

    public func startMonitoring(interval: TimeInterval = 0.45) {
        stopMonitoring()
        lastObservedChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkSystemPasteboard()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    public func stopMonitoring() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    public func checkSystemPasteboard() {
        guard SettingsStore.shared.clipboardHistoryEnabled else { return }
        let pb = NSPasteboard.general
        let currentCount = pb.changeCount
        guard currentCount != lastObservedChangeCount else { return }
        lastObservedChangeCount = currentCount

        // Respect Raycast/macOS password-manager concealment & transient pasteboard markers.
        let types = Set((pb.types ?? []).map { $0.rawValue })
        if types.contains("org.nspasteboard.ConcealedType") || types.contains("org.nspasteboard.TransientType") {
            return
        }

        let frontApp = NSWorkspace.shared.frontmostApplication
        let appName = frontApp?.localizedName ?? "Unknown App"
        let bundleID = frontApp?.bundleIdentifier
        if let bundleID, disabledAppBundleIDs.contains(bundleID) {
            return
        }

        // Priority 1: File URLs
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let firstFile = urls.first {
            if let nsImage = NSImage(contentsOf: firstFile),
               let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let ext = firstFile.pathExtension.lowercased() as String?,
               ["png", "jpg", "jpeg", "tiff", "webp", "gif", "heic"].contains(ext) {
                recordImage(cgImage, title: firstFile.lastPathComponent, sourceAppName: appName, sourceBundleID: bundleID)
            } else {
                recordFileURL(firstFile, sourceAppName: appName, sourceBundleID: bundleID)
            }
            return
        }

        // Priority 2: Image data on pasteboard (screenshots, copied web images, Preview)
        if let pngData = pb.data(forType: .png), let nsImage = NSImage(data: pngData),
           let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            recordImage(cgImage, title: "Image from \(appName)", sourceAppName: appName, sourceBundleID: bundleID)
            return
        }
        if let tiffData = pb.data(forType: .tiff), let nsImage = NSImage(data: tiffData),
           let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            recordImage(cgImage, title: "Image from \(appName)", sourceAppName: appName, sourceBundleID: bundleID)
            return
        }

        // Priority 3: Plain String (including links, emails, colors, JSON)
        if let str = pb.string(forType: .string), !str.isEmpty {
            recordText(str, sourceAppName: appName, sourceBundleID: bundleID)
        }
    }

    // MARK: - Recording Entries

    @discardableResult
    public func recordText(_ text: String, sourceAppName: String = "System", sourceBundleID: String? = nil) -> ClipboardEntry {
        let (categories, colorHex) = ClipboardSmartDetector.detectCategories(for: text)
        let firstLine = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? text
        let title = String(firstLine.prefix(120))
        let autoTags = autoTagsForApp(bundleID: sourceBundleID)

        let entry = ClipboardEntry(
            title: title,
            categories: categories,
            text: text,
            colorHex: colorHex,
            sourceAppName: sourceAppName,
            sourceAppBundleID: sourceBundleID,
            tags: autoTags
        )
        return upsertEntry(entry)
    }

    @discardableResult
    public func recordImage(
        _ cgImage: CGImage,
        title: String? = nil,
        sourceAppName: String = "System",
        sourceBundleID: String? = nil
    ) -> ClipboardEntry {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        let pngData = rep.representation(using: .png, properties: [:]) ?? Data()
        let finalTitle = title ?? "Image (\(cgImage.width)×\(cgImage.height))"
        let autoTags = autoTagsForApp(bundleID: sourceBundleID)

        let entry = ClipboardEntry(
            title: finalTitle,
            categories: [.image],
            imagePNGData: pngData,
            imageWidth: cgImage.width,
            imageHeight: cgImage.height,
            sourceAppName: sourceAppName,
            sourceAppBundleID: sourceBundleID,
            tags: autoTags
        )
        let saved = upsertEntry(entry)

        if SettingsStore.shared.clipboardOCREnabled {
            runBackgroundImageAnalysis(for: saved.id, cgImage: cgImage)
        }
        return saved
    }

    @discardableResult
    public func recordFileURL(_ url: URL, sourceAppName: String = "Finder", sourceBundleID: String? = nil) -> ClipboardEntry {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attrs?[.size] as? NSNumber)?.int64Value
        let autoTags = autoTagsForApp(bundleID: sourceBundleID)

        let entry = ClipboardEntry(
            title: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
            categories: [.file],
            fileURLPath: url.path,
            fileSize: fileSize,
            sourceAppName: sourceAppName,
            sourceAppBundleID: sourceBundleID,
            tags: autoTags
        )
        return upsertEntry(entry)
    }

    private func autoTagsForApp(bundleID: String?) -> [String] {
        guard let bundleID else { return [] }
        return appFilterRules
            .filter { $0.isEnabled && $0.bundleIdentifier.caseInsensitiveCompare(bundleID) == .orderedSame }
            .flatMap(\.tags)
    }

    @discardableResult
    private func upsertEntry(_ incoming: ClipboardEntry) -> ClipboardEntry {
        let sig = incoming.contentSignature
        if let idx = entries.firstIndex(where: { $0.contentSignature == sig }) {
            var existing = entries.remove(at: idx)
            existing.copyCount += 1
            existing.updatedAt = Date()
            existing.sourceAppName = incoming.sourceAppName
            if let bid = incoming.sourceAppBundleID {
                existing.sourceAppBundleID = bid
            }
            entries.insert(existing, at: 0)
            normalizeSortOrder()
            saveToDisk()
            return existing
        }

        entries.insert(incoming, at: 0)
        trimUnpinnedIfNeeded()
        normalizeSortOrder()
        saveToDisk()
        return incoming
    }

    private func trimUnpinnedIfNeeded() {
        while entries.count > maxEntries {
            if let lastUnpinned = entries.lastIndex(where: { !$0.isPinned }) {
                entries.remove(at: lastUnpinned)
            } else {
                break
            }
        }
    }

    private func normalizeSortOrder() {
        let pinned = entries.filter(\.isPinned).sorted { ($0.pinnedOrder ?? 0) < ($1.pinnedOrder ?? 0) }
        let unpinned = entries.filter { !$0.isPinned }.sorted { $0.updatedAt > $1.updatedAt }
        entries = pinned + unpinned
    }

    // MARK: - Vision OCR & QR Decoding

    private func runBackgroundImageAnalysis(for id: UUID, cgImage: CGImage) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .accurate
            textRequest.usesLanguageCorrection = true

            let qrRequest = VNDetectBarcodesRequest()
            qrRequest.symbologies = [.qr, .aztec, .dataMatrix]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([textRequest, qrRequest])

            let recognizedText = (textRequest.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let qrPayloads = (qrRequest.results ?? [])
                .compactMap { $0.payloadStringValue }

            DispatchQueue.main.async {
                guard let self, let idx = self.entries.firstIndex(where: { $0.id == id }) else { return }
                if !recognizedText.isEmpty {
                    self.entries[idx].recognizedOCRText = recognizedText
                }
                if !qrPayloads.isEmpty {
                    self.entries[idx].qrPayloads = qrPayloads
                }
                self.saveToDisk()
            }
        }
    }

    @discardableResult
    public func extractOCROnDemand(id: UUID) -> String? {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return nil }
        if let existing = entries[idx].recognizedOCRText, !existing.isEmpty {
            return existing
        }
        guard let data = entries[idx].imagePNGData,
              let nsImage = NSImage(data: data),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([req])
        let text = (req.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        entries[idx].recognizedOCRText = text
        saveToDisk()
        return text
    }

    @discardableResult
    public func decodeQROnDemand(id: UUID) -> [String] {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return [] }
        if !entries[idx].qrPayloads.isEmpty {
            return entries[idx].qrPayloads
        }
        guard let data = entries[idx].imagePNGData,
              let nsImage = NSImage(data: data),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return []
        }

        let req = VNDetectBarcodesRequest()
        req.symbologies = [.qr, .aztec, .dataMatrix]
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([req])
        let payloads = (req.results ?? []).compactMap { $0.payloadStringValue }
        entries[idx].qrPayloads = payloads
        saveToDisk()
        return payloads
    }

    // MARK: - Actions (Copy, Paste, Pin, Tag, Sequential Paste, Delete)

    public func copyEntryToClipboard(_ entry: ClipboardEntry, asPlainText: Bool = false) {
        let pb = NSPasteboard.general
        pb.clearContents()

        if asPlainText, let text = entry.text ?? entry.recognizedOCRText {
            pb.setString(text, forType: .string)
        } else if let pngData = entry.imagePNGData, !entry.categories.contains(.text) {
            pb.setData(pngData, forType: .png)
        } else if let filePath = entry.fileURLPath {
            pb.writeObjects([URL(fileURLWithPath: filePath) as NSURL])
        } else if let text = entry.text {
            pb.setString(text, forType: .string)
        }

        // Prevent poll loop from double-recording our own copy write.
        lastObservedChangeCount = pb.changeCount

        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx].updatedAt = Date()
            entries[idx].copyCount += 1
            normalizeSortOrder()
            saveToDisk()
        }
    }

    public func pasteEntryToActiveApp(_ entry: ClipboardEntry, asPlainText: Bool = false) {
        copyEntryToClipboard(entry, asPlainText: asPlainText)
        ClipboardWindowController.shared.close()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            Self.synthesizeCommandV()
        }
    }

    public func copyTextToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        lastObservedChangeCount = pb.changeCount
    }

    @discardableResult
    public func pasteNextSequential(addNewline: Bool = false, synthesizePaste: Bool = true) -> ClipboardEntry? {
        guard !entries.isEmpty else { return nil }
        if let deadline = sequentialPasteDeadline, Date() > deadline {
            sequentialPasteIndex = 0
        }
        let ordered = entries
        let idx = sequentialPasteIndex % ordered.count
        let entry = ordered[idx]
        sequentialPasteIndex = (idx + 1) % ordered.count
        sequentialPasteDeadline = Date().addingTimeInterval(60)

        if addNewline, let text = entry.text {
            copyTextToPasteboard(text + "\n")
        } else {
            let pb = NSPasteboard.general
            pb.clearContents()
            if let png = entry.imagePNGData {
                pb.setData(png, forType: .png)
            } else if let path = entry.fileURLPath {
                pb.writeObjects([URL(fileURLWithPath: path) as NSURL])
            } else if let text = entry.text {
                pb.setString(text, forType: .string)
            }
            lastObservedChangeCount = pb.changeCount
        }

        if synthesizePaste {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                Self.synthesizeCommandV()
            }
        }
        return entry
    }

    public func resetSequentialPaste() {
        sequentialPasteIndex = 0
        sequentialPasteDeadline = nil
    }

    public func togglePin(id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        if entries[idx].isPinned {
            entries[idx].pinnedOrder = nil
        } else {
            let nextOrder = (entries.compactMap(\.pinnedOrder).max() ?? -1) + 1
            entries[idx].pinnedOrder = nextOrder
        }
        normalizeSortOrder()
        saveToDisk()
    }

    public enum MoveDirection {
        case up, down
    }

    public func movePinned(id: UUID, direction: MoveDirection) {
        var pinned = entries.filter(\.isPinned).sorted { ($0.pinnedOrder ?? 0) < ($1.pinnedOrder ?? 0) }
        guard let pos = pinned.firstIndex(where: { $0.id == id }) else { return }
        let targetPos = direction == .up ? pos - 1 : pos + 1
        guard targetPos >= 0, targetPos < pinned.count else { return }
        pinned.swapAt(pos, targetPos)
        for (order, item) in pinned.enumerated() {
            if let idx = entries.firstIndex(where: { $0.id == item.id }) {
                entries[idx].pinnedOrder = order
            }
        }
        normalizeSortOrder()
        saveToDisk()
    }

    public func renameEntry(id: UUID, customTitle: String?) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        entries[idx].customTitle = (trimmed?.isEmpty ?? true) ? nil : trimmed
        saveToDisk()
    }

    public func updateEntryText(id: UUID, newText: String) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        let (cats, hex) = ClipboardSmartDetector.detectCategories(for: newText)
        let firstLine = newText.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? newText
        entries[idx].text = newText
        entries[idx].title = String(firstLine.prefix(120))
        entries[idx].categories = cats
        entries[idx].colorHex = hex
        entries[idx].updatedAt = Date()
        normalizeSortOrder()
        saveToDisk()
    }

    public func addTag(id: UUID, tag: String) {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        if !entries[idx].tags.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            entries[idx].tags.append(trimmed)
            saveToDisk()
        }
    }

    public func removeTag(id: UUID, tag: String) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].tags.removeAll { $0 == tag }
        saveToDisk()
    }

    public func deleteEntry(id: UUID) {
        entries.removeAll { $0.id == id }
        saveToDisk()
    }

    public func deleteRecent(minutes: Int, includePinned: Bool = false) {
        let cutoff = Date().addingTimeInterval(-Double(minutes) * 60.0)
        entries.removeAll { entry in
            if !includePinned && entry.isPinned { return false }
            return entry.updatedAt >= cutoff
        }
        saveToDisk()
    }

    public func clearAll(includePinned: Bool = false) {
        if includePinned {
            entries.removeAll()
        } else {
            entries.removeAll { !$0.isPinned }
        }
        resetSequentialPaste()
        saveToDisk()
    }

    public func pruneExpired(days: Int) {
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400.0)
        let before = entries.count
        entries.removeAll { !$0.isPinned && $0.updatedAt < cutoff }
        if entries.count != before {
            saveToDisk()
        }
    }

    public func filteredEntries(
        query: String = "",
        category: ClipboardCategory = .all,
        tag: String? = nil
    ) -> [ClipboardEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries.filter { entry in
            if category != .all && !entry.categories.contains(category) {
                return false
            }
            if let tag, !tag.isEmpty && !entry.tags.contains(tag) {
                return false
            }
            guard !q.isEmpty else { return true }
            return entry.displayTitle.lowercased().contains(q)
                || (entry.text?.lowercased().contains(q) ?? false)
                || (entry.recognizedOCRText?.lowercased().contains(q) ?? false)
                || entry.sourceAppName.lowercased().contains(q)
                || entry.tags.contains(where: { $0.lowercased().contains(q) })
        }
    }

    public func makeCGImage(for entry: ClipboardEntry) -> CGImage? {
        if let data = entry.imagePNGData,
           let nsImage = NSImage(data: data),
           let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return cg
        }
        if let hex = entry.colorHex {
            return CaptureEngine.makeSyntheticImage(width: 720, height: 480, label: hex)
        }
        let label = entry.displayTitle
        return CaptureEngine.makeSyntheticImage(width: 900, height: 520, label: label)
    }

    private static func synthesizeCommandV() {
        let src = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)  // 'v'
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard let storageURL, FileManager.default.fileExists(atPath: storageURL.path) else { return }
        guard let data = try? Data(contentsOf: storageURL),
              let loaded = try? decoder.decode([ClipboardEntry].self, from: data) else {
            return
        }
        self.entries = loaded
        normalizeSortOrder()
    }

    private func saveToDisk() {
        guard let storageURL else { return }
        if let data = try? encoder.encode(entries) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }
}
