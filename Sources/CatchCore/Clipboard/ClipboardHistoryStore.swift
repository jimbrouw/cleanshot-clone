import Foundation
import AppKit
import CoreGraphics
import CryptoKit
import SQLite3
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
    public var pinnedPosition: Double?
    public var tags: [String]
    public var isRemoteClipboard: Bool
    public var sourceBundleURI: String?

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
        pinnedPosition: Double? = nil,
        tags: [String] = [],
        isRemoteClipboard: Bool = false,
        sourceBundleURI: String? = nil
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
        self.pinnedPosition = pinnedPosition ?? pinnedOrder.map { Double($0 + 1) * 1000.0 }
        self.tags = tags
        self.isRemoteClipboard = isRemoteClipboard
        self.sourceBundleURI = sourceBundleURI ?? sourceAppBundleID
    }

    public var isPinned: Bool { pinnedPosition != nil || pinnedOrder != nil }

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

// MARK: - Pasteboard Privacy Inspection & Completion Signal

/// Privacy/transient rejection reasons anchored to `NSPasteboard+Additions.swift` (`0x100b8bb60`)
/// and `ClipboardPlaceInClipboardHandler.swift` (`0x100b70310`).
public enum PasteboardRejectionReason: Equatable, Sendable {
    case historyDisabled
    case unchangedCount
    case concealedType          // org.nspasteboard.ConcealedType @ 0x100b70400
    case transientType          // org.nspasteboard.TransientType @ 0x100b6efc0
    case autoGeneratedType      // org.nspasteboard.AutoGeneratedType @ 0x100b703d0
    case restoredType           // com.raycast.RestoredType @ 0x100b6f350
    case excludedSourceApp(String) // org.nspasteboard.source @ 0x100b70130 or frontmost bundle ID
    case emptyPayload
}

public enum PasteboardInspectionDecision: Equatable, Sendable {
    case allow(sourceBundleID: String?, isRemote: Bool)
    case reject(PasteboardRejectionReason)
}

/// Asynchronous paste completion signal mirroring `RaycastDesktopApp.PasteboardItemProvider.PasteCompletionSignal` (`0x100bb17a6`).
public struct PasteCompletionSignal: Equatable, Sendable {
    public let entryID: UUID
    public let targetBundleID: String?
    public let synthesizedPaste: Bool
    public let restoredPreviousPasteboard: Bool
    public let completedAt: Date

    public init(
        entryID: UUID,
        targetBundleID: String?,
        synthesizedPaste: Bool,
        restoredPreviousPasteboard: Bool,
        completedAt: Date = Date()
    ) {
        self.entryID = entryID
        self.targetBundleID = targetBundleID
        self.synthesizedPaste = synthesizedPaste
        self.restoredPreviousPasteboard = restoredPreviousPasteboard
        self.completedAt = completedAt
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
    public let dbURL: URL?
    public let blobsDirectory: URL?

    public var disabledAppBundleIDs: Set<String> = [
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.1password.1password-safari-extension",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.dashlane.Dashlane"
    ]

    private let storageURL: URL?
    private let defaults: UserDefaults
    private var pollTimer: Timer?
    private var lastObservedChangeCount: Int
    private var db: OpaquePointer?
    private let dbQueue = DispatchQueue(label: "com.catchapp.clipboard.sqlite")
    private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public static var defaultStorageURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = appSupport.appendingPathComponent("Catch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("clipboard.sqlite")
    }

    public convenience init() {
        self.init(storageURL: Self.defaultStorageURL, defaults: .standard)
    }

    public init(storageURL: URL?, defaults: UserDefaults = .standard, maxEntries: Int = 500) {
        self.storageURL = storageURL
        self.defaults = defaults
        self.maxEntries = maxEntries
        self.lastObservedChangeCount = NSPasteboard.general.changeCount

        if let storageURL {
            let ext = storageURL.pathExtension.lowercased()
            let sqliteURL = (ext == "sqlite" || ext == "db")
                ? storageURL
                : storageURL.deletingPathExtension().appendingPathExtension("sqlite")
            try? FileManager.default.createDirectory(at: sqliteURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let blobsDir = sqliteURL.deletingLastPathComponent().appendingPathComponent("clipboard-blobs", isDirectory: true)
            try? FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)
            self.dbURL = sqliteURL
            self.blobsDirectory = blobsDir
        } else {
            self.dbURL = nil
            self.blobsDirectory = nil
        }

        openDatabase()
        createSchemaIfNeeded()
        migrateLegacyJSONIfNeeded()
        loadEntriesFromSQLite()
        pruneExpired(days: SettingsStore.shared.clipboardRetentionDays)
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
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

    // MARK: - SQLite3 + Trigram FTS5 Schema (data.darwin-arm64.node @ 0x1a69b25..0x1a6c3b9)

    private func openDatabase() {
        let path = dbURL?.path ?? ":memory:"
        sqlite3_open(path, &db)
    }

    private func execSQL(_ sql: String) {
        guard let db else { return }
        var errMsg: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, sql, nil, nil, &errMsg)
        if let errMsg { sqlite3_free(errMsg) }
    }

    private func createSchemaIfNeeded() {
        dbQueue.sync {
            execSQL("PRAGMA journal_mode = WAL;")
            execSQL("PRAGMA synchronous = NORMAL;")
            execSQL("PRAGMA foreign_keys = ON;")

            execSQL("""
            CREATE TABLE IF NOT EXISTS workspaces (
                id INTEGER PRIMARY KEY,
                title TEXT NOT NULL
            );
            INSERT OR IGNORE INTO workspaces (id, title) VALUES (1, 'Default');

            CREATE TABLE IF NOT EXISTS entries (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                custom_title TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                workspace_id INTEGER NOT NULL DEFAULT 1,
                source_name TEXT NOT NULL,
                source_host INTEGER NOT NULL DEFAULT 0,
                source_url TEXT NOT NULL DEFAULT '',
                copy_count INTEGER NOT NULL DEFAULT 1,
                pinned REAL,
                color_hex TEXT,
                ocr_text TEXT,
                qr_payloads_json TEXT,
                image_width INTEGER,
                image_height INTEGER,
                file_url_path TEXT,
                file_size INTEGER,
                content_signature TEXT NOT NULL UNIQUE,
                FOREIGN KEY(workspace_id) REFERENCES workspaces(id)
            );

            CREATE TABLE IF NOT EXISTS items (
                id INTEGER NOT NULL,
                entry_id TEXT NOT NULL,
                FOREIGN KEY(entry_id) REFERENCES entries(id),
                PRIMARY KEY (id, entry_id)
            );

            CREATE TABLE IF NOT EXISTS representations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                item_id INTEGER NOT NULL,
                entry_id TEXT NOT NULL,
                mime_type TEXT NOT NULL,
                content_type INTEGER NOT NULL,
                content TEXT NOT NULL,
                content_search TEXT,
                blob_sha256 TEXT,
                FOREIGN KEY(item_id, entry_id) REFERENCES items(id, entry_id)
            );

            CREATE TABLE IF NOT EXISTS router_entry_category (
                entry_id TEXT NOT NULL,
                category TEXT NOT NULL,
                FOREIGN KEY(entry_id) REFERENCES entries(id),
                PRIMARY KEY (entry_id, category)
            );

            CREATE TABLE IF NOT EXISTS router_entry_tag (
                entry_id TEXT NOT NULL,
                tag TEXT NOT NULL,
                FOREIGN KEY(entry_id) REFERENCES entries(id),
                PRIMARY KEY (entry_id, tag)
            );

            CREATE TABLE IF NOT EXISTS filters (
                source_url TEXT PRIMARY KEY,
                enabled INTEGER NOT NULL DEFAULT 1
            );

            CREATE TABLE IF NOT EXISTS router_filter_tag (
                source_url TEXT NOT NULL,
                tag TEXT NOT NULL,
                FOREIGN KEY(source_url) REFERENCES filters(source_url),
                PRIMARY KEY (source_url, tag)
            );

            -- Composite covering index (data.darwin-arm64.node @ 0x1a6a510)
            CREATE INDEX IF NOT EXISTS representations_idx_entry_id_item_id
                ON representations(entry_id, item_id);

            -- Partial covering index for substring filtering (data.darwin-arm64.node @ 0x1a6bc90)
            CREATE INDEX IF NOT EXISTS representations_idx_content_search
                ON representations(entry_id, content_search)
                WHERE content_search IS NOT NULL;

            CREATE INDEX IF NOT EXISTS entries_idx_order
                ON entries(pinned ASC, updated_at DESC);

            -- Ordered cascade deletion triggers: representations -> items -> entries (0x1a6a580)
            CREATE TRIGGER IF NOT EXISTS delete_item_representations
                BEFORE DELETE ON items
                FOR EACH ROW
            BEGIN
                DELETE FROM representations WHERE representations.item_id = OLD.id AND representations.entry_id = OLD.entry_id;
            END;

            CREATE TRIGGER IF NOT EXISTS delete_entry_items
                BEFORE DELETE ON entries
                FOR EACH ROW
            BEGIN
                DELETE FROM items WHERE items.entry_id = OLD.id;
            END;

            CREATE TRIGGER IF NOT EXISTS delete_entry_categories
                BEFORE DELETE ON entries
                FOR EACH ROW
            BEGIN
                DELETE FROM router_entry_category WHERE router_entry_category.entry_id = OLD.id;
            END;

            CREATE TRIGGER IF NOT EXISTS delete_entry_tags
                BEFORE DELETE ON entries
                FOR EACH ROW
            BEGIN
                DELETE FROM router_entry_tag WHERE router_entry_tag.entry_id = OLD.id;
            END;
            """)

            // Trigram FTS5 virtual table for instant substring matching (0x1a6bd16)
            execSQL("""
            CREATE VIRTUAL TABLE IF NOT EXISTS representations_tri_FTS USING fts5(
                entry_id UNINDEXED,
                content,
                entry_title,
                tokenize='trigram'
            );

            CREATE TRIGGER IF NOT EXISTS representations_tri_FTS_ai
                AFTER INSERT ON representations
                FOR EACH ROW
            BEGIN
                INSERT INTO representations_tri_FTS(rowid, entry_id, content, entry_title)
                VALUES (
                    NEW.id,
                    NEW.entry_id,
                    COALESCE(NEW.content_search, NEW.content),
                    COALESCE((SELECT COALESCE(NULLIF(custom_title, ''), title) FROM entries WHERE id = NEW.entry_id LIMIT 1), '')
                );
            END;

            CREATE TRIGGER IF NOT EXISTS representations_tri_FTS_ad
                BEFORE DELETE ON representations
                FOR EACH ROW
            BEGIN
                DELETE FROM representations_tri_FTS WHERE rowid = OLD.id;
            END;

            CREATE TRIGGER IF NOT EXISTS representations_tri_FTS_au
                AFTER UPDATE ON representations
                FOR EACH ROW
            BEGIN
                DELETE FROM representations_tri_FTS WHERE rowid = OLD.id;
                INSERT INTO representations_tri_FTS(rowid, entry_id, content, entry_title)
                VALUES (
                    NEW.id,
                    NEW.entry_id,
                    COALESCE(NEW.content_search, NEW.content),
                    COALESCE((SELECT COALESCE(NULLIF(custom_title, ''), title) FROM entries WHERE id = NEW.entry_id LIMIT 1), '')
                );
            END;
            """)
        }
    }

    private func migrateLegacyJSONIfNeeded() {
        guard let storageURL,
              storageURL.pathExtension.lowercased() == "json",
              FileManager.default.fileExists(atPath: storageURL.path) else {
            return
        }
        var rowCount: Int32 = 0
        dbQueue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM entries;", -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW {
                    rowCount = sqlite3_column_int(stmt, 0)
                }
            }
            sqlite3_finalize(stmt)
        }
        guard rowCount == 0,
              let data = try? Data(contentsOf: storageURL),
              let legacy = try? JSONDecoder().decode([ClipboardEntry].self, from: data) else {
            return
        }
        for item in legacy {
            persistEntryToSQLite(item)
        }
    }

    // MARK: - Live NSPasteboard Inspection & Monitoring (`0x10075a628..0x10075a8a8`)

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

    /// Inspects all UTIs and source markers across the pasteboard and each `NSPasteboardItem`,
    /// enforcing the recovered `nspasteboard.org` contract from `Raycast` (`0x100b6efc0..0x100b70400`).
    public func inspectPasteboardItem(
        _ pasteboard: NSPasteboard = .general,
        frontmostBundleID: String? = nil,
        frontmostAppName: String? = nil
    ) -> PasteboardInspectionDecision {
        var collectedTypes = Set((pasteboard.types ?? []).map(\.rawValue))
        var pasteboardSource: String? = pasteboard.string(forType: NSPasteboard.PasteboardType(RaycastBinaryEvidence.sourceTypeUTI))

        for item in pasteboard.pasteboardItems ?? [] {
            for type in item.types {
                collectedTypes.insert(type.rawValue)
            }
            if pasteboardSource == nil,
               let src = item.string(forType: NSPasteboard.PasteboardType(RaycastBinaryEvidence.sourceTypeUTI)),
               !src.isEmpty {
                pasteboardSource = src
            }
        }

        if collectedTypes.contains(RaycastBinaryEvidence.concealedTypeUTI) {
            return .reject(.concealedType)
        }
        if collectedTypes.contains(RaycastBinaryEvidence.transientTypeUTI) {
            return .reject(.transientType)
        }
        if collectedTypes.contains(RaycastBinaryEvidence.autoGeneratedTypeUTI) {
            return .reject(.autoGeneratedType)
        }
        if collectedTypes.contains(RaycastBinaryEvidence.restoredTypeUTI) {
            return .reject(.restoredType)
        }

        let effectiveBundleID = pasteboardSource ?? frontmostBundleID
        if let effectiveBundleID,
           disabledAppBundleIDs.contains(where: { $0.caseInsensitiveCompare(effectiveBundleID) == .orderedSame }) {
            return .reject(.excludedSourceApp(effectiveBundleID))
        }

        if collectedTypes.isEmpty {
            return .reject(.emptyPayload)
        }

        let isRemote = collectedTypes.contains(RaycastBinaryEvidence.remoteClipboardUTI)
        return .allow(sourceBundleID: effectiveBundleID, isRemote: isRemote)
    }

    public func checkSystemPasteboard() {
        guard SettingsStore.shared.clipboardHistoryEnabled else { return }
        let pb = NSPasteboard.general
        let currentCount = pb.changeCount
        guard currentCount != lastObservedChangeCount else { return }
        lastObservedChangeCount = currentCount

        let frontApp = NSWorkspace.shared.frontmostApplication
        let appName = frontApp?.localizedName ?? "Unknown App"
        let frontBundleID = frontApp?.bundleIdentifier

        let decision = inspectPasteboardItem(pb, frontmostBundleID: frontBundleID, frontmostAppName: appName)
        guard case let .allow(resolvedBundleID, isRemote) = decision else {
            return
        }

        // Priority 1: File URLs
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let firstFile = urls.first {
            if let nsImage = NSImage(contentsOf: firstFile),
               let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
               ["png", "jpg", "jpeg", "tiff", "webp", "gif", "heic"].contains(firstFile.pathExtension.lowercased()) {
                recordImage(
                    cgImage,
                    title: firstFile.lastPathComponent,
                    sourceAppName: appName,
                    sourceBundleID: resolvedBundleID,
                    isRemote: isRemote
                )
            } else {
                recordFileURL(
                    firstFile,
                    sourceAppName: appName,
                    sourceBundleID: resolvedBundleID,
                    isRemote: isRemote
                )
            }
            return
        }

        // Priority 2: Image data on pasteboard
        if let pngData = pb.data(forType: .png), let nsImage = NSImage(data: pngData),
           let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            recordImage(
                cgImage,
                title: "Image from \(appName)",
                sourceAppName: appName,
                sourceBundleID: resolvedBundleID,
                isRemote: isRemote
            )
            return
        }
        if let tiffData = pb.data(forType: .tiff), let nsImage = NSImage(data: tiffData),
           let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            recordImage(
                cgImage,
                title: "Image from \(appName)",
                sourceAppName: appName,
                sourceBundleID: resolvedBundleID,
                isRemote: isRemote
            )
            return
        }

        // Priority 3: Plain String (including links, emails, colors, JSON)
        if let str = pb.string(forType: .string), !str.isEmpty {
            recordText(
                str,
                sourceAppName: appName,
                sourceBundleID: resolvedBundleID,
                isRemote: isRemote
            )
        }
    }

    // MARK: - Recording Entries

    @discardableResult
    public func recordText(
        _ text: String,
        sourceAppName: String = "System",
        sourceBundleID: String? = nil,
        isRemote: Bool = false
    ) -> ClipboardEntry {
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
            tags: autoTags,
            isRemoteClipboard: isRemote,
            sourceBundleURI: sourceBundleID
        )
        return upsertEntry(entry)
    }

    @discardableResult
    public func recordImage(
        _ cgImage: CGImage,
        title: String? = nil,
        sourceAppName: String = "System",
        sourceBundleID: String? = nil,
        isRemote: Bool = false
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
            tags: autoTags,
            isRemoteClipboard: isRemote,
            sourceBundleURI: sourceBundleID
        )
        let saved = upsertEntry(entry)

        if SettingsStore.shared.clipboardOCREnabled {
            runBackgroundImageAnalysis(for: saved.id, cgImage: cgImage)
        }
        return saved
    }

    @discardableResult
    public func recordFileURL(
        _ url: URL,
        sourceAppName: String = "Finder",
        sourceBundleID: String? = nil,
        isRemote: Bool = false
    ) -> ClipboardEntry {
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
            tags: autoTags,
            isRemoteClipboard: isRemote,
            sourceBundleURI: sourceBundleID
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
            existing.isRemoteClipboard = incoming.isRemoteClipboard
            if let bid = incoming.sourceAppBundleID {
                existing.sourceAppBundleID = bid
                existing.sourceBundleURI = bid
            }
            entries.insert(existing, at: 0)
            normalizeSortOrder()
            persistEntryToSQLite(existing)
            return existing
        }

        entries.insert(incoming, at: 0)
        persistEntryToSQLite(incoming)
        trimUnpinnedIfNeeded()
        normalizeSortOrder()
        return incoming
    }

    private func trimUnpinnedIfNeeded() {
        while entries.count > maxEntries {
            if let lastUnpinned = entries.lastIndex(where: { !$0.isPinned }) {
                let removed = entries.remove(at: lastUnpinned)
                deleteEntryFromSQLite(id: removed.id)
            } else {
                break
            }
        }
    }

    private func normalizeSortOrder() {
        var pinned = entries.filter(\.isPinned).sorted {
            let lhsPos = $0.pinnedPosition ?? Double(($0.pinnedOrder ?? 0) + 1) * 1000.0
            let rhsPos = $1.pinnedPosition ?? Double(($1.pinnedOrder ?? 0) + 1) * 1000.0
            if lhsPos != rhsPos { return lhsPos < rhsPos }
            return $0.updatedAt > $1.updatedAt
        }
        for idx in pinned.indices {
            pinned[idx].pinnedOrder = idx
            if pinned[idx].pinnedPosition == nil {
                pinned[idx].pinnedPosition = Double(idx + 1) * 1000.0
            }
        }
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
                self.persistEntryToSQLite(self.entries[idx])
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
        persistEntryToSQLite(entries[idx])
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
        persistEntryToSQLite(entries[idx])
        return payloads
    }

    // MARK: - Actions (Copy, Paste with Completion Signal, Pin, Tag, Sequential Paste)

    public func copyEntryToClipboard(_ entry: ClipboardEntry, asPlainText: Bool = false) {
        writeEntryToPasteboard(entry, to: .general, asPlainText: asPlainText, markTransient: false)

        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx].updatedAt = Date()
            entries[idx].copyCount += 1
            let updated = entries[idx]
            normalizeSortOrder()
            persistEntryToSQLite(updated)
        }
    }

    public func pasteEntryToActiveApp(_ entry: ClipboardEntry, asPlainText: Bool = false) {
        paste(entry, asPlainText: asPlainText, restorePreviousPasteboard: false, completion: nil)
    }

    /// Mirrors `paste(_:source:excludeMainWindow:override:concealed:closingMain:)` (`0x100b704c0`) + `PasteCompletionSignal` (`0x100bb17a6`).
    public func paste(
        _ entry: ClipboardEntry,
        asPlainText: Bool = false,
        restorePreviousPasteboard: Bool = false,
        synthesizePaste: Bool = true,
        completion: ((PasteCompletionSignal) -> Void)? = nil
    ) {
        let snapshot = restorePreviousPasteboard ? snapshotPasteboard(.general) : nil
        let targetApp = ClipboardWindowController.shared.previousFrontmostApp

        writeEntryToPasteboard(entry, to: .general, asPlainText: asPlainText, markTransient: synthesizePaste)

        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx].updatedAt = Date()
            entries[idx].copyCount += 1
            let updated = entries[idx]
            normalizeSortOrder()
            persistEntryToSQLite(updated)
        }

        ClipboardWindowController.shared.close()
        targetApp?.activate(options: [])

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            if synthesizePaste {
                Self.synthesizeCommandV()
            }
            if let snapshot, let self {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                    self.restorePasteboard(snapshot, to: .general)
                    completion?(PasteCompletionSignal(
                        entryID: entry.id,
                        targetBundleID: targetApp?.bundleIdentifier,
                        synthesizedPaste: synthesizePaste,
                        restoredPreviousPasteboard: true
                    ))
                }
            } else {
                completion?(PasteCompletionSignal(
                    entryID: entry.id,
                    targetBundleID: targetApp?.bundleIdentifier,
                    synthesizedPaste: synthesizePaste,
                    restoredPreviousPasteboard: false
                ))
            }
        }
    }

    public func writeEntryToPasteboard(
        _ entry: ClipboardEntry,
        to pb: NSPasteboard,
        asPlainText: Bool = false,
        markTransient: Bool = false
    ) {
        pb.clearContents()
        let item = NSPasteboardItem()
        let selfBundle = Bundle.main.bundleIdentifier ?? "com.catchapp.macos"
        item.setString(selfBundle, forType: NSPasteboard.PasteboardType(RaycastBinaryEvidence.sourceTypeUTI))
        if markTransient {
            item.setData(Data(), forType: NSPasteboard.PasteboardType(RaycastBinaryEvidence.transientTypeUTI))
        }

        if asPlainText, let text = entry.text ?? entry.recognizedOCRText {
            item.setString(text, forType: .string)
            pb.writeObjects([item])
        } else if let pngData = entry.imagePNGData, !entry.categories.contains(.text) {
            item.setData(pngData, forType: .png)
            pb.writeObjects([item])
        } else if let filePath = entry.fileURLPath {
            pb.writeObjects([URL(fileURLWithPath: filePath) as NSURL, item])
        } else if let text = entry.text {
            item.setString(text, forType: .string)
            pb.writeObjects([item])
        } else {
            pb.writeObjects([item])
        }

        if pb === NSPasteboard.general {
            lastObservedChangeCount = pb.changeCount
        }
    }

    private func snapshotPasteboard(_ pb: NSPasteboard) -> [[(NSPasteboard.PasteboardType, Data)]] {
        (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in
                guard let d = item.data(forType: t) else { return nil }
                return (t, d)
            }
        }
    }

    /// Restores previous pasteboard contents tagged with `com.raycast.RestoredType` (`0x100b6f350`)
    /// so `inspectPasteboardItem` ignores the restoration transition (`0x100b70350`).
    private func restorePasteboard(_ snapshot: [[(NSPasteboard.PasteboardType, Data)]], to pb: NSPasteboard) {
        pb.clearContents()
        var restoredObjects: [NSPasteboardWriting] = []
        for entryTypes in snapshot {
            let item = NSPasteboardItem()
            for (t, d) in entryTypes {
                item.setData(d, forType: t)
            }
            item.setData(Data(), forType: NSPasteboard.PasteboardType(RaycastBinaryEvidence.restoredTypeUTI))
            restoredObjects.append(item)
        }
        if !restoredObjects.isEmpty {
            pb.writeObjects(restoredObjects)
        }
        if pb === NSPasteboard.general {
            lastObservedChangeCount = pb.changeCount
        }
    }

    public func copyTextToPasteboard(_ text: String, markTransient: Bool = false) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString(Bundle.main.bundleIdentifier ?? "com.catchapp.macos", forType: NSPasteboard.PasteboardType(RaycastBinaryEvidence.sourceTypeUTI))
        if markTransient {
            item.setData(Data(), forType: NSPasteboard.PasteboardType(RaycastBinaryEvidence.transientTypeUTI))
        }
        pb.writeObjects([item])
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
            copyTextToPasteboard(text + "\n", markTransient: synthesizePaste)
        } else {
            writeEntryToPasteboard(entry, to: .general, asPlainText: false, markTransient: synthesizePaste)
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

    /// Fractional pin indexing (`1000.0`, `2000.0`, `3000.0`) recovered from `data.darwin-arm64.node @ 0x1a6bc10`.
    public func togglePin(id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        if entries[idx].isPinned {
            entries[idx].pinnedOrder = nil
            entries[idx].pinnedPosition = nil
        } else {
            let maxPos = entries.compactMap(\.pinnedPosition).max() ?? 0.0
            let nextOrder = (entries.compactMap(\.pinnedOrder).max() ?? -1) + 1
            entries[idx].pinnedPosition = maxPos + 1000.0
            entries[idx].pinnedOrder = nextOrder
        }
        let updated = entries[idx]
        normalizeSortOrder()
        persistEntryToSQLite(updated)
    }

    public enum MoveDirection {
        case up, down
    }

    public func movePinned(id: UUID, direction: MoveDirection) {
        var pinned = entries.filter(\.isPinned).sorted {
            ($0.pinnedPosition ?? Double(($0.pinnedOrder ?? 0) + 1) * 1000.0) <
            ($1.pinnedPosition ?? Double(($1.pinnedOrder ?? 0) + 1) * 1000.0)
        }
        guard let pos = pinned.firstIndex(where: { $0.id == id }) else { return }
        let targetPos = direction == .up ? pos - 1 : pos + 1
        guard targetPos >= 0, targetPos < pinned.count else { return }
        pinned.swapAt(pos, targetPos)

        // Compute fractional midpoint for the moved row when sandwiched, or normalize if spacing collapses.
        let movedNewIndex = targetPos
        let prevPos = movedNewIndex > 0 ? (pinned[movedNewIndex - 1].pinnedPosition ?? Double(movedNewIndex) * 1000.0) : 0.0
        let nextPos = movedNewIndex + 1 < pinned.count ? (pinned[movedNewIndex + 1].pinnedPosition ?? Double(movedNewIndex + 2) * 1000.0) : (prevPos + 2000.0)
        let fractionalPos = (prevPos + nextPos) / 2.0

        if abs(nextPos - prevPos) > 0.001 {
            if let idx = entries.firstIndex(where: { $0.id == id }) {
                entries[idx].pinnedPosition = fractionalPos
                persistEntryToSQLite(entries[idx])
            }
        } else {
            for (order, item) in pinned.enumerated() {
                if let idx = entries.firstIndex(where: { $0.id == item.id }) {
                    entries[idx].pinnedOrder = order
                    entries[idx].pinnedPosition = Double(order + 1) * 1000.0
                    persistEntryToSQLite(entries[idx])
                }
            }
        }
        normalizeSortOrder()
    }

    public func renameEntry(id: UUID, customTitle: String?) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        entries[idx].customTitle = (trimmed?.isEmpty ?? true) ? nil : trimmed
        persistEntryToSQLite(entries[idx])
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
        let updated = entries[idx]
        normalizeSortOrder()
        persistEntryToSQLite(updated)
    }

    public func addTag(id: UUID, tag: String) {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        if !entries[idx].tags.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            entries[idx].tags.append(trimmed)
            entries[idx].updatedAt = Date()
            persistEntryToSQLite(entries[idx])
        }
    }

    public func removeTag(id: UUID, tag: String) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].tags.removeAll { $0 == tag }
        entries[idx].updatedAt = Date()
        persistEntryToSQLite(entries[idx])
    }

    public func deleteEntry(id: UUID) {
        entries.removeAll { $0.id == id }
        deleteEntryFromSQLite(id: id)
    }

    public func deleteRecent(minutes: Int, includePinned: Bool = false) {
        let cutoff = Date().addingTimeInterval(-Double(minutes) * 60.0)
        let removed = entries.filter { entry in
            (includePinned || !entry.isPinned) && entry.updatedAt >= cutoff
        }
        entries.removeAll { entry in
            (includePinned || !entry.isPinned) && entry.updatedAt >= cutoff
        }
        for item in removed {
            deleteEntryFromSQLite(id: item.id)
        }
    }

    public func clearAll(includePinned: Bool = false) {
        let removed = includePinned ? entries : entries.filter { !$0.isPinned }
        if includePinned {
            entries.removeAll()
        } else {
            entries.removeAll { !$0.isPinned }
        }
        resetSequentialPaste()
        for item in removed {
            deleteEntryFromSQLite(id: item.id)
        }
    }

    public func pruneExpired(days: Int) {
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400.0)
        let expired = entries.filter { !$0.isPinned && $0.updatedAt < cutoff }
        guard !expired.isEmpty else { return }
        entries.removeAll { !$0.isPinned && $0.updatedAt < cutoff }
        for item in expired {
            deleteEntryFromSQLite(id: item.id)
        }
    }

    /// Queries SQLite `representations_tri_FTS` (trigram FTS5 for 3+ chars) or `representations_idx_content_search`
    /// (for 1-2 char substring filters), combined with category & tag join filters.
    public func searchFTS(
        query: String,
        category: ClipboardCategory = .all,
        tag: String? = nil,
        limit: Int = 500
    ) -> [ClipboardEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            return filteredEntries(query: "", category: category, tag: tag)
        }

        var matchedIDs: [UUID] = []
        dbQueue.sync {
            guard let db else { return }
            let useFTS5 = q.count >= 3
            let sql: String
            if useFTS5 {
                sql = """
                SELECT DISTINCT f.entry_id
                FROM representations_tri_FTS f
                JOIN entries e ON e.id = f.entry_id
                WHERE representations_tri_FTS MATCH ?
                ORDER BY (e.pinned IS NULL), e.pinned ASC, e.updated_at DESC
                LIMIT ?;
                """
            } else {
                sql = """
                SELECT DISTINCT r.entry_id
                FROM representations r
                JOIN entries e ON e.id = r.entry_id
                WHERE r.content_search IS NOT NULL AND r.content_search LIKE ?
                ORDER BY (e.pinned IS NULL), e.pinned ASC, e.updated_at DESC
                LIMIT ?;
                """
            }

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            let param: String
            if useFTS5 {
                let escaped = q.replacingOccurrences(of: "\"", with: "\"\"")
                param = "\"\(escaped)\""
            } else {
                param = "%\(q.lowercased())%"
            }
            sqlite3_bind_text(stmt, 1, param, -1, transientDestructor)
            sqlite3_bind_int(stmt, 2, Int32(limit))

            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cStr = sqlite3_column_text(stmt, 0),
                   let uuid = UUID(uuidString: String(cString: cStr)) {
                    matchedIDs.append(uuid)
                }
            }
        }

        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        return matchedIDs.compactMap { byID[$0] }.filter { entry in
            let catOK = (category == .all || entry.categories.contains(category))
            let tagOK = (tag == nil || tag!.isEmpty || entry.tags.contains(tag!))
            return catOK && tagOK
        }
    }

    public func filteredEntries(
        query: String = "",
        category: ClipboardCategory = .all,
        tag: String? = nil
    ) -> [ClipboardEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty, db != nil {
            let ftsHits = searchFTS(query: q, category: category, tag: tag)
            if !ftsHits.isEmpty {
                return ftsHits
            }
        }

        let lowerQ = q.lowercased()
        return entries.filter { entry in
            if category != .all && !entry.categories.contains(category) {
                return false
            }
            if let tag, !tag.isEmpty && !entry.tags.contains(tag) {
                return false
            }
            guard !lowerQ.isEmpty else { return true }
            return entry.displayTitle.lowercased().contains(lowerQ)
                || (entry.text?.lowercased().contains(lowerQ) ?? false)
                || (entry.recognizedOCRText?.lowercased().contains(lowerQ) ?? false)
                || entry.sourceAppName.lowercased().contains(lowerQ)
                || entry.tags.contains(where: { $0.lowercased().contains(lowerQ) })
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
        return CaptureEngine.makeSyntheticImage(width: 900, height: 520, label: entry.displayTitle)
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

    // MARK: - Content-Addressed Blobs & SQLite Persistence

    private func writeImageBlobIfNeeded(_ data: Data?) -> String? {
        guard let data, !data.isEmpty else { return nil }
        let digest = SHA256.hash(data: data)
        let sha = digest.map { String(format: "%02x", $0) }.joined()
        if let blobsDirectory {
            let blobURL = blobsDirectory.appendingPathComponent("\(sha).png")
            if !FileManager.default.fileExists(atPath: blobURL.path) {
                try? data.write(to: blobURL, options: .atomic)
            }
        }
        return sha
    }

    private func readImageBlob(sha256: String?) -> Data? {
        guard let sha256, !sha256.isEmpty, let blobsDirectory else { return nil }
        let blobURL = blobsDirectory.appendingPathComponent("\(sha256).png")
        return try? Data(contentsOf: blobURL)
    }

    public func persistEntryToSQLite(_ entry: ClipboardEntry) {
        let blobSHA = writeImageBlobIfNeeded(entry.imagePNGData)
        dbQueue.sync {
            guard let db else { return }
            execSQL("BEGIN IMMEDIATE TRANSACTION;")

            let idStr = entry.id.uuidString
            let qrJSON = (try? JSONEncoder().encode(entry.qrPayloads)).flatMap { String(data: $0, encoding: .utf8) }

            let upsertEntrySQL = """
            INSERT INTO entries (
                id, title, custom_title, created_at, updated_at, workspace_id,
                source_name, source_host, source_url, copy_count, pinned,
                color_hex, ocr_text, qr_payloads_json, image_width, image_height,
                file_url_path, file_size, content_signature
            ) VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                custom_title = excluded.custom_title,
                updated_at = excluded.updated_at,
                source_name = excluded.source_name,
                source_host = excluded.source_host,
                source_url = excluded.source_url,
                copy_count = excluded.copy_count,
                pinned = excluded.pinned,
                color_hex = excluded.color_hex,
                ocr_text = excluded.ocr_text,
                qr_payloads_json = excluded.qr_payloads_json;
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, upsertEntrySQL, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, idStr, -1, transientDestructor)
                sqlite3_bind_text(stmt, 2, entry.title, -1, transientDestructor)
                if let ct = entry.customTitle {
                    sqlite3_bind_text(stmt, 3, ct, -1, transientDestructor)
                } else {
                    sqlite3_bind_null(stmt, 3)
                }
                sqlite3_bind_double(stmt, 4, entry.createdAt.timeIntervalSince1970)
                sqlite3_bind_double(stmt, 5, entry.updatedAt.timeIntervalSince1970)
                sqlite3_bind_text(stmt, 6, entry.sourceAppName, -1, transientDestructor)
                sqlite3_bind_int(stmt, 7, entry.isRemoteClipboard ? 1 : 0)
                sqlite3_bind_text(stmt, 8, entry.sourceAppBundleID ?? "", -1, transientDestructor)
                sqlite3_bind_int(stmt, 9, Int32(entry.copyCount))
                if let pPos = entry.pinnedPosition {
                    sqlite3_bind_double(stmt, 10, pPos)
                } else {
                    sqlite3_bind_null(stmt, 10)
                }
                if let hex = entry.colorHex { sqlite3_bind_text(stmt, 11, hex, -1, transientDestructor) } else { sqlite3_bind_null(stmt, 11) }
                if let ocr = entry.recognizedOCRText { sqlite3_bind_text(stmt, 12, ocr, -1, transientDestructor) } else { sqlite3_bind_null(stmt, 12) }
                if let qrJSON { sqlite3_bind_text(stmt, 13, qrJSON, -1, transientDestructor) } else { sqlite3_bind_null(stmt, 13) }
                if let w = entry.imageWidth { sqlite3_bind_int(stmt, 14, Int32(w)) } else { sqlite3_bind_null(stmt, 14) }
                if let h = entry.imageHeight { sqlite3_bind_int(stmt, 15, Int32(h)) } else { sqlite3_bind_null(stmt, 15) }
                if let fp = entry.fileURLPath { sqlite3_bind_text(stmt, 16, fp, -1, transientDestructor) } else { sqlite3_bind_null(stmt, 16) }
                if let fs = entry.fileSize { sqlite3_bind_int64(stmt, 17, fs) } else { sqlite3_bind_null(stmt, 17) }
                sqlite3_bind_text(stmt, 18, entry.contentSignature, -1, transientDestructor)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)

            // Refresh child representations cleanly in ordered trigger order (items -> representations)
            var delItemsStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM items WHERE entry_id = ?;", -1, &delItemsStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(delItemsStmt, 1, idStr, -1, transientDestructor)
                sqlite3_step(delItemsStmt)
            }
            sqlite3_finalize(delItemsStmt)

            var insItemStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO items (id, entry_id) VALUES (1, ?);", -1, &insItemStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(insItemStmt, 1, idStr, -1, transientDestructor)
                sqlite3_step(insItemStmt)
            }
            sqlite3_finalize(insItemStmt)

            let searchableParts = [entry.displayTitle, entry.text, entry.recognizedOCRText, entry.fileURLPath, entry.sourceAppName]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let foldedSearch = searchableParts.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let mimeType: String
            let repContent: String
            if let text = entry.text {
                mimeType = "public.plain-text"
                repContent = text
            } else if let blobSHA {
                mimeType = "public.png"
                repContent = "blob:\(blobSHA)"
            } else if let path = entry.fileURLPath {
                mimeType = "public.file-url"
                repContent = path
            } else {
                mimeType = "public.plain-text"
                repContent = entry.title
            }

            let insRepSQL = """
            INSERT INTO representations (item_id, entry_id, mime_type, content_type, content, content_search, blob_sha256)
            VALUES (1, ?, ?, ?, ?, ?, ?);
            """
            var repStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, insRepSQL, -1, &repStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(repStmt, 1, idStr, -1, transientDestructor)
                sqlite3_bind_text(repStmt, 2, mimeType, -1, transientDestructor)
                sqlite3_bind_int(repStmt, 3, Int32(entry.primaryCategory == .image ? 1 : 0))
                sqlite3_bind_text(repStmt, 4, repContent, -1, transientDestructor)
                if !foldedSearch.isEmpty {
                    sqlite3_bind_text(repStmt, 5, foldedSearch, -1, transientDestructor)
                } else {
                    sqlite3_bind_null(repStmt, 5)
                }
                if let blobSHA {
                    sqlite3_bind_text(repStmt, 6, blobSHA, -1, transientDestructor)
                } else {
                    sqlite3_bind_null(repStmt, 6)
                }
                sqlite3_step(repStmt)
            }
            sqlite3_finalize(repStmt)

            // Sync categories & tags routers
            var delCatStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM router_entry_category WHERE entry_id = ?;", -1, &delCatStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(delCatStmt, 1, idStr, -1, transientDestructor)
                sqlite3_step(delCatStmt)
            }
            sqlite3_finalize(delCatStmt)

            for cat in Set(entry.categories) {
                var catStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO router_entry_category (entry_id, category) VALUES (?, ?);", -1, &catStmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(catStmt, 1, idStr, -1, transientDestructor)
                    sqlite3_bind_text(catStmt, 2, cat.rawValue, -1, transientDestructor)
                    sqlite3_step(catStmt)
                }
                sqlite3_finalize(catStmt)
            }

            var delTagStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM router_entry_tag WHERE entry_id = ?;", -1, &delTagStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(delTagStmt, 1, idStr, -1, transientDestructor)
                sqlite3_step(delTagStmt)
            }
            sqlite3_finalize(delTagStmt)

            for tag in entry.tags {
                var tagStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO router_entry_tag (entry_id, tag) VALUES (?, ?);", -1, &tagStmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(tagStmt, 1, idStr, -1, transientDestructor)
                    sqlite3_bind_text(tagStmt, 2, tag, -1, transientDestructor)
                    sqlite3_step(tagStmt)
                }
                sqlite3_finalize(tagStmt)
            }

            execSQL("COMMIT;")
        }
    }

    private func deleteEntryFromSQLite(id: UUID) {
        dbQueue.sync {
            guard let db else { return }
            let sql = "DELETE FROM entries WHERE id = ?;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, id.uuidString, -1, transientDestructor)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    private func loadEntriesFromSQLite() {
        var loaded: [ClipboardEntry] = []
        dbQueue.sync {
            guard let db else { return }

            // Preload category & tag maps
            var categoriesMap: [String: [ClipboardCategory]] = [:]
            var catStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT entry_id, category FROM router_entry_category;", -1, &catStmt, nil) == SQLITE_OK {
                while sqlite3_step(catStmt) == SQLITE_ROW {
                    if let eid = sqlite3_column_text(catStmt, 0),
                       let rawCat = sqlite3_column_text(catStmt, 1),
                       let cat = ClipboardCategory(rawValue: String(cString: rawCat)) {
                        categoriesMap[String(cString: eid), default: []].append(cat)
                    }
                }
            }
            sqlite3_finalize(catStmt)

            var tagsMap: [String: [String]] = [:]
            var tagStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT entry_id, tag FROM router_entry_tag;", -1, &tagStmt, nil) == SQLITE_OK {
                while sqlite3_step(tagStmt) == SQLITE_ROW {
                    if let eid = sqlite3_column_text(tagStmt, 0),
                       let tag = sqlite3_column_text(tagStmt, 1) {
                        tagsMap[String(cString: eid), default: []].append(String(cString: tag))
                    }
                }
            }
            sqlite3_finalize(tagStmt)

            var repTextMap: [String: (mime: String, content: String, sha: String?)] = [:]
            var repStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT entry_id, mime_type, content, blob_sha256 FROM representations;", -1, &repStmt, nil) == SQLITE_OK {
                while sqlite3_step(repStmt) == SQLITE_ROW {
                    if let eid = sqlite3_column_text(repStmt, 0),
                       let mime = sqlite3_column_text(repStmt, 1),
                       let content = sqlite3_column_text(repStmt, 2) {
                        let sha = sqlite3_column_text(repStmt, 3).map { String(cString: $0) }
                        repTextMap[String(cString: eid)] = (String(cString: mime), String(cString: content), sha)
                    }
                }
            }
            sqlite3_finalize(repStmt)

            let sql = """
            SELECT id, title, custom_title, created_at, updated_at, source_name,
                   source_host, source_url, copy_count, pinned, color_hex, ocr_text,
                   qr_payloads_json, image_width, image_height, file_url_path, file_size
            FROM entries
            ORDER BY (pinned IS NULL), pinned ASC, updated_at DESC;
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let idCStr = sqlite3_column_text(stmt, 0),
                          let id = UUID(uuidString: String(cString: idCStr)),
                          let titleCStr = sqlite3_column_text(stmt, 1) else { continue }
                    let idStr = String(cString: idCStr)
                    let title = String(cString: titleCStr)
                    let customTitle = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
                    let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
                    let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
                    let sourceName = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? "System"
                    let isRemote = sqlite3_column_int(stmt, 6) != 0
                    let sourceURL = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
                    let bundleID = (sourceURL?.isEmpty ?? true) ? nil : sourceURL
                    let copyCount = Int(sqlite3_column_int(stmt, 8))
                    let pinnedPos: Double? = sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 9)
                    let colorHex = sqlite3_column_text(stmt, 10).map { String(cString: $0) }
                    let ocrText = sqlite3_column_text(stmt, 11).map { String(cString: $0) }
                    let qrPayloads: [String] = sqlite3_column_text(stmt, 12)
                        .flatMap { String(cString: $0).data(using: .utf8) }
                        .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
                    let imageWidth: Int? = sqlite3_column_type(stmt, 13) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 13))
                    let imageHeight: Int? = sqlite3_column_type(stmt, 14) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 14))
                    let fileURLPath = sqlite3_column_text(stmt, 15).map { String(cString: $0) }
                    let fileSize: Int64? = sqlite3_column_type(stmt, 16) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 16)

                    let rep = repTextMap[idStr]
                    let textPayload: String? = (rep?.mime == "public.plain-text") ? rep?.content : nil
                    let imageData: Data? = (rep?.sha != nil) ? readImageBlob(sha256: rep?.sha) : nil
                    let cats = categoriesMap[idStr] ?? [.text]

                    loaded.append(ClipboardEntry(
                        id: id,
                        title: title,
                        customTitle: customTitle,
                        categories: cats,
                        text: textPayload,
                        imagePNGData: imageData,
                        imageWidth: imageWidth,
                        imageHeight: imageHeight,
                        fileURLPath: fileURLPath,
                        fileSize: fileSize,
                        colorHex: colorHex,
                        recognizedOCRText: ocrText,
                        qrPayloads: qrPayloads,
                        sourceAppName: sourceName,
                        sourceAppBundleID: bundleID,
                        createdAt: createdAt,
                        updatedAt: updatedAt,
                        copyCount: copyCount,
                        pinnedOrder: nil,
                        pinnedPosition: pinnedPos,
                        tags: tagsMap[idStr] ?? [],
                        isRemoteClipboard: isRemote,
                        sourceBundleURI: bundleID
                    ))
                }
            }
            sqlite3_finalize(stmt)
        }
        self.entries = loaded
        normalizeSortOrder()
    }
}
