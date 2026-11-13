import Foundation
import AppKit
import Network

public struct CloudComment: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let author: String
    public let text: String
    public let x: Double
    public let y: Double
    public let createdAt: Date

    public init(id: UUID = UUID(), author: String, text: String, x: Double, y: Double, createdAt: Date = Date()) {
        self.id = id
        self.author = author
        self.text = text
        self.x = x
        self.y = y
        self.createdAt = createdAt
    }
}

public struct CloudSharedItem: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var tags: [String]
    public var shareURL: String
    public var passwordHash: String?
    public var expiresAt: Date?
    public var createdAt: Date
    public var filePath: String
    public var comments: [CloudComment]

    public init(
        id: String,
        title: String,
        tags: [String] = [],
        shareURL: String,
        passwordHash: String? = nil,
        expiresAt: Date? = nil,
        createdAt: Date = Date(),
        filePath: String,
        comments: [CloudComment] = []
    ) {
        self.id = id
        self.title = title
        self.tags = tags
        self.shareURL = shareURL
        self.passwordHash = passwordHash
        self.expiresAt = expiresAt
        self.createdAt = createdAt
        self.filePath = filePath
        self.comments = comments
    }
}

public final class CloudUploadService: ObservableObject {
    public static let shared = CloudUploadService()

    @Published public private(set) var recentUploads: [CloudSharedItem] = []
    @Published public private(set) var serverPort: UInt16 = 0

    private let storageDir: URL
    private let indexURL: URL
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.catchapp.cloudserver")

    public init(storageDirectory: URL? = nil) {
        let defaultDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Catch", isDirectory: true)
            .appendingPathComponent("Cloud", isDirectory: true)
        self.storageDir = storageDirectory ?? defaultDir
        try? FileManager.default.createDirectory(at: self.storageDir, withIntermediateDirectories: true)
        self.indexURL = self.storageDir.appendingPathComponent("uploads.json")
        loadIndex()
    }

    public func ensureServerStarted() -> UInt16 {
        if serverPort != 0 { return serverPort }
        let sem = DispatchSemaphore(value: 0)
        var boundPort: UInt16 = 0

        if let listener = try? NWListener(using: .tcp, on: .any) {
            listener.stateUpdateHandler = { state in
                if case .ready = state, let port = listener.port?.rawValue {
                    boundPort = port
                    sem.signal()
                } else if case .failed = state {
                    sem.signal()
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                self?.handleConnection(conn)
            }
            listener.start(queue: queue)
            self.listener = listener
            _ = sem.wait(timeout: .now() + 2.0)
            self.serverPort = boundPort
        }
        return serverPort
    }

    @MainActor
    public func upload(
        image: CGImage,
        data: Data,
        title: String,
        tags: [String] = [],
        password: String? = nil,
        expiresInSeconds: TimeInterval? = nil,
        forcePrompt: Bool = false
    ) async -> CloudSharedItem? {
        let port = ensureServerStarted()
        let settings = SettingsStore.shared
        var finalTitle = title
        let finalTags = tags
        let finalPassword = password

        if forcePrompt || settings.askForNameAndAdvancedOptionsOnUpload {
            // In interactive mode, honor provided defaults cleanly
            finalTitle = title.isEmpty ? "Catch Upload" : title
        }

        let payloadData: Data = {
            if settings.screenshotUploadQuality == .optimizedForSharing,
               let jpg = ImagePostProcessor.encode(image: image, format: .jpeg, quality: 0.85) {
                return jpg.count < data.count ? jpg : data
            }
            return data
        }()

        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let fileURL = storageDir.appendingPathComponent("\(id).png")
        try? payloadData.write(to: fileURL)

        let effectivePort = port > 0 ? port : 49152
        let shareURL = "http://127.0.0.1:\(effectivePort)/s/\(id)"

        if settings.copyLinkWhenUploadStarts {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(shareURL, forType: .string)
        }

        let item = CloudSharedItem(
            id: id,
            title: finalTitle,
            tags: finalTags,
            shareURL: shareURL,
            passwordHash: finalPassword?.isEmpty == false ? finalPassword : nil,
            expiresAt: expiresInSeconds.map { Date().addingTimeInterval($0) },
            filePath: fileURL.path
        )

        recentUploads.insert(item, at: 0)
        saveIndex()

        if !settings.copyLinkWhenUploadStarts {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(shareURL, forType: .string)
        }
        return item
    }

    @discardableResult
    public func addComment(toShareID id: String, author: String, text: String, x: Double, y: Double) -> CloudComment? {
        guard let idx = recentUploads.firstIndex(where: { $0.id == id }) else { return nil }
        let comment = CloudComment(author: author, text: text, x: x, y: y)
        recentUploads[idx].comments.append(comment)
        saveIndex()
        return comment
    }

    public func item(forShareID id: String) -> CloudSharedItem? {
        guard let item = recentUploads.first(where: { $0.id == id }) else { return nil }
        if let exp = item.expiresAt, exp < Date() {
            return nil
        }
        return item
    }

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self, let data, let raw = String(data: data, encoding: .utf8) else {
                conn.cancel()
                return
            }
            let firstLine = raw.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.split(separator: " ")
            let method = parts.first.map(String.init) ?? "GET"
            let path = parts.dropFirst().first.map(String.init) ?? "/"

            if method == "GET" && path.hasPrefix("/s/") {
                let id = String(path.dropFirst(3))
                if let item = self.item(forShareID: id) {
                    let html = self.renderViewerHTML(for: item)
                    self.sendHTTPResponse(conn, status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(html.utf8))
                } else {
                    self.sendHTTPResponse(conn, status: "404 Not Found", contentType: "text/plain", body: Data("Not Found".utf8))
                }
            } else if method == "GET" && path.hasPrefix("/img/") {
                let id = String(path.dropFirst(5))
                if let item = self.item(forShareID: id), let imgData = try? Data(contentsOf: URL(fileURLWithPath: item.filePath)) {
                    self.sendHTTPResponse(conn, status: "200 OK", contentType: "image/png", body: imgData)
                } else {
                    self.sendHTTPResponse(conn, status: "404 Not Found", contentType: "text/plain", body: Data("Not Found".utf8))
                }
            } else if method == "GET" && path.hasPrefix("/api/comments/") {
                let id = String(path.dropFirst(14))
                let comments = self.item(forShareID: id)?.comments ?? []
                let json = (try? JSONEncoder().encode(comments)) ?? Data("[]".utf8)
                self.sendHTTPResponse(conn, status: "200 OK", contentType: "application/json", body: json)
            } else if method == "POST" && path.hasPrefix("/api/comments/") {
                let id = String(path.dropFirst(14))
                if let bodyStr = raw.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n").data(using: .utf8),
                   let payload = try? JSONDecoder().decode(CommentPayload.self, from: bodyStr),
                   let created = self.addComment(toShareID: id, author: payload.author, text: payload.text, x: payload.x, y: payload.y),
                   let json = try? JSONEncoder().encode(created) {
                    self.sendHTTPResponse(conn, status: "201 Created", contentType: "application/json", body: json)
                } else {
                    self.sendHTTPResponse(conn, status: "400 Bad Request", contentType: "text/plain", body: Data("Invalid payload".utf8))
                }
            } else {
                self.sendHTTPResponse(conn, status: "200 OK", contentType: "text/plain", body: Data("Catch Cloud".utf8))
            }
        }
    }

    private struct CommentPayload: Codable {
        let author: String
        let text: String
        let x: Double
        let y: Double
    }

    private func renderViewerHTML(for item: CloudSharedItem) -> String {
        """
        <!doctype html>
        <html>
        <head><meta charset="utf-8"><title>\(item.title)</title></head>
        <body style="font-family:-apple-system,sans-serif;background:#0f172a;color:#f8fafc;padding:32px;text-align:center;">
          <h2>\(item.title)</h2>
          <div style="display:inline-block;position:relative;">
            <img src="/img/\(item.id)" style="max-width:90vw;border-radius:12px;box-shadow:0 20px 50px rgba(0,0,0,0.45);" />
          </div>
          <p>Comments: \(item.comments.count)</p>
        </body>
        </html>
        """
    }

    private func sendHTTPResponse(_ conn: NWConnection, status: String, contentType: String, body: Data) {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var full = Data(header.utf8)
        full.append(body)
        conn.send(content: full, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func saveIndex() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(recentUploads) {
            try? data.write(to: indexURL)
        }
    }

    private func loadIndex() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: indexURL),
           let loaded = try? decoder.decode([CloudSharedItem].self, from: data) {
            recentUploads = loaded
        }
    }
}
