import Foundation
import SQLite3
import CoreGraphics

public enum CaptureMediaType: String, Codable, CaseIterable, Sendable {
    case screenshot
    case video
    case gif
}

public enum HistoryFilterTab: String, CaseIterable, Sendable {
    case all = "All"
    case screenshots = "Screenshots"
    case videos = "Videos"
    case gifs = "GIFs"
}

public struct CaptureHistoryItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public var title: String
    public var mediaType: CaptureMediaType
    public var filePath: String
    public var projectPath: String?
    public var width: Int
    public var height: Int
    public var byteSize: Int
    public var isClosed: Bool
    public var closedAt: Date?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        title: String,
        mediaType: CaptureMediaType,
        filePath: String,
        projectPath: String? = nil,
        width: Int,
        height: Int,
        byteSize: Int,
        isClosed: Bool = false,
        closedAt: Date? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.mediaType = mediaType
        self.filePath = filePath
        self.projectPath = projectPath
        self.width = width
        self.height = height
        self.byteSize = byteSize
        self.isClosed = isClosed
        self.closedAt = closedAt
    }
}

public final class HistoryStore: ObservableObject {
    public static let shared = HistoryStore()

    @Published public private(set) var items: [CaptureHistoryItem] = []

    public let rootDirectory: URL
    private let dbURL: URL
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.cleanshotclone.historystore")

    public init(rootDirectory: URL? = nil) {
        let defaultRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CleanShotClone", isDirectory: true)
            .appendingPathComponent("History", isDirectory: true)
        self.rootDirectory = rootDirectory ?? defaultRoot
        try? FileManager.default.createDirectory(at: self.rootDirectory, withIntermediateDirectories: true)
        self.dbURL = self.rootDirectory.appendingPathComponent("history.sqlite")
        openDatabase()
        createTableIfNeeded()
        reload()
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    private func openDatabase() {
        sqlite3_open(dbURL.path, &db)
    }

    private func createTableIfNeeded() {
        let sql = """
        CREATE TABLE IF NOT EXISTS history_items (
            id TEXT PRIMARY KEY,
            created_at REAL NOT NULL,
            title TEXT NOT NULL,
            media_type TEXT NOT NULL,
            file_path TEXT NOT NULL,
            project_path TEXT,
            width INTEGER NOT NULL,
            height INTEGER NOT NULL,
            byte_size INTEGER NOT NULL,
            is_closed INTEGER NOT NULL DEFAULT 0,
            closed_at REAL
        );
        """
        queue.sync {
            var errMsg: UnsafeMutablePointer<CChar>?
            sqlite3_exec(db, sql, nil, nil, &errMsg)
            if let errMsg { sqlite3_free(errMsg) }
        }
    }

    @discardableResult
    public func recordCapture(
        image: CGImage,
        imageData: Data,
        title: String,
        mediaType: CaptureMediaType = .screenshot,
        fileExtension: String = "png",
        documentState: AnnotationDocumentState? = nil,
        createdAt: Date = Date()
    ) -> CaptureHistoryItem {
        let id = UUID()
        let itemDir = rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: itemDir, withIntermediateDirectories: true)

        let fileURL = itemDir.appendingPathComponent("capture.\(fileExtension)")
        try? imageData.write(to: fileURL)

        var projectPath: String? = nil
        if let documentState {
            let projURL = itemDir.appendingPathComponent("Project.cleanshot")
            let doc = CleanShotDocument(baseImage: image, state: documentState)
            try? doc.save(to: projURL)
            projectPath = projURL.path
        }

        let item = CaptureHistoryItem(
            id: id,
            createdAt: createdAt,
            title: title,
            mediaType: mediaType,
            filePath: fileURL.path,
            projectPath: projectPath,
            width: image.width,
            height: image.height,
            byteSize: imageData.count,
            isClosed: false,
            closedAt: nil
        )
        insertOrUpdate(item)
        reload()
        return item
    }

    public func insertOrUpdate(_ item: CaptureHistoryItem) {
        let sql = """
        INSERT OR REPLACE INTO history_items
        (id, created_at, title, media_type, file_path, project_path, width, height, byte_size, is_closed, closed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, item.id.uuidString, -1, transient)
            sqlite3_bind_double(stmt, 2, item.createdAt.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, item.title, -1, transient)
            sqlite3_bind_text(stmt, 4, item.mediaType.rawValue, -1, transient)
            sqlite3_bind_text(stmt, 5, item.filePath, -1, transient)
            if let projectPath = item.projectPath {
                sqlite3_bind_text(stmt, 6, projectPath, -1, transient)
            } else {
                sqlite3_bind_null(stmt, 6)
            }
            sqlite3_bind_int(stmt, 7, Int32(item.width))
            sqlite3_bind_int(stmt, 8, Int32(item.height))
            sqlite3_bind_int(stmt, 9, Int32(item.byteSize))
            sqlite3_bind_int(stmt, 10, item.isClosed ? 1 : 0)
            if let closedAt = item.closedAt {
                sqlite3_bind_double(stmt, 11, closedAt.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 11)
            }
            sqlite3_step(stmt)
        }
    }

    public func markClosed(id: UUID, at date: Date = Date()) {
        queue.sync {
            let sql = "UPDATE history_items SET is_closed = 1, closed_at = ? WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, id.uuidString, -1, transient)
            sqlite3_step(stmt)
        }
        reload()
    }

    @discardableResult
    public func restoreMostRecentlyClosed() -> CaptureHistoryItem? {
        var found: CaptureHistoryItem?
        queue.sync {
            let sql = """
            SELECT id, created_at, title, media_type, file_path, project_path, width, height, byte_size, is_closed, closed_at
            FROM history_items
            WHERE is_closed = 1
            ORDER BY closed_at DESC, created_at DESC
            LIMIT 1;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW {
                found = readRow(stmt)
            }
        }
        if var item = found {
            item.isClosed = false
            item.closedAt = nil
            insertOrUpdate(item)
            reload()
            return item
        }
        return nil
    }

    public func filteredItems(tab: HistoryFilterTab, query: String = "") -> [CaptureHistoryItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return items.filter { item in
            let tabMatches: Bool = {
                switch tab {
                case .all: return true
                case .screenshots: return item.mediaType == .screenshot
                case .videos: return item.mediaType == .video
                case .gifs: return item.mediaType == .gif
                }
            }()
            let queryMatches = trimmed.isEmpty || item.title.lowercased().contains(trimmed)
            return tabMatches && queryMatches
        }
    }

    public func deleteItem(id: UUID) {
        queue.sync {
            let sql = "DELETE FROM history_items WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, id.uuidString, -1, transient)
            sqlite3_step(stmt)
        }
        let itemDir = rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: itemDir)
        reload()
    }

    @discardableResult
    public func pruneExpiredItems(retention: HistoryRetentionDuration, now: Date = Date()) -> Int {
        let cutoff = now.addingTimeInterval(-retention.timeInterval).timeIntervalSince1970
        var expiredIds: [UUID] = []
        queue.sync {
            let selectSQL = "SELECT id FROM history_items WHERE created_at < ?;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, selectSQL, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_double(stmt, 1, cutoff)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let cStr = sqlite3_column_text(stmt, 0),
                       let uuid = UUID(uuidString: String(cString: cStr)) {
                        expiredIds.append(uuid)
                    }
                }
            }
            sqlite3_finalize(stmt)

            let deleteSQL = "DELETE FROM history_items WHERE created_at < ?;"
            var delStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, deleteSQL, -1, &delStmt, nil) == SQLITE_OK {
                sqlite3_bind_double(delStmt, 1, cutoff)
                sqlite3_step(delStmt)
            }
            sqlite3_finalize(delStmt)
        }
        for id in expiredIds {
            let itemDir = rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
            try? FileManager.default.removeItem(at: itemDir)
        }
        reload()
        return expiredIds.count
    }

    public func reload() {
        var loaded: [CaptureHistoryItem] = []
        queue.sync {
            let sql = """
            SELECT id, created_at, title, media_type, file_path, project_path, width, height, byte_size, is_closed, closed_at
            FROM history_items
            ORDER BY created_at DESC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let item = readRow(stmt) {
                    loaded.append(item)
                }
            }
        }
        if Thread.isMainThread {
            self.items = loaded
        } else {
            DispatchQueue.main.async {
                self.items = loaded
            }
        }
    }

    private func readRow(_ stmt: OpaquePointer?) -> CaptureHistoryItem? {
        guard let stmt,
              let idCStr = sqlite3_column_text(stmt, 0),
              let id = UUID(uuidString: String(cString: idCStr)),
              let titleCStr = sqlite3_column_text(stmt, 2),
              let typeCStr = sqlite3_column_text(stmt, 3),
              let pathCStr = sqlite3_column_text(stmt, 4) else {
            return nil
        }

        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
        let title = String(cString: titleCStr)
        let mediaType = CaptureMediaType(rawValue: String(cString: typeCStr)) ?? .screenshot
        let filePath = String(cString: pathCStr)
        let projectPath: String? = sqlite3_column_type(stmt, 5) == SQLITE_NULL
            ? nil
            : String(cString: sqlite3_column_text(stmt, 5))
        let width = Int(sqlite3_column_int(stmt, 6))
        let height = Int(sqlite3_column_int(stmt, 7))
        let byteSize = Int(sqlite3_column_int(stmt, 8))
        let isClosed = sqlite3_column_int(stmt, 9) != 0
        let closedAt: Date? = sqlite3_column_type(stmt, 10) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10))

        return CaptureHistoryItem(
            id: id,
            createdAt: createdAt,
            title: title,
            mediaType: mediaType,
            filePath: filePath,
            projectPath: projectPath,
            width: width,
            height: height,
            byteSize: byteSize,
            isClosed: isClosed,
            closedAt: closedAt
        )
    }
}
