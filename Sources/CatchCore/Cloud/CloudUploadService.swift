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
    public var expiresAt: Date?
    public var createdAt: Date
    public var filePath: String
    public var comments: [CloudComment]

    public init(
        id: String,
        title: String,
        tags: [String] = [],
        shareURL: String,
        expiresAt: Date? = nil,
        createdAt: Date = Date(),
        filePath: String,
        comments: [CloudComment] = []
    ) {
        self.id = id
        self.title = title
        self.tags = tags
        self.shareURL = shareURL
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
    private let storageIsPrivate: Bool
    private var sessionShares: Set<String> = []

    public init(storageDirectory: URL? = nil) {
        let defaultDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Catch", isDirectory: true)
            .appendingPathComponent("Cloud", isDirectory: true)
        self.storageDir = storageDirectory ?? defaultDir
        self.indexURL = self.storageDir.appendingPathComponent("uploads.json")
        do {
            try FileManager.default.createDirectory(at: self.storageDir, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.storageDir.path)
            storageIsPrivate = true
        } catch {
            storageIsPrivate = false
        }
        if storageIsPrivate { loadIndex() }
    }

    deinit {
        listener?.cancel()
    }

    @MainActor
    public func ensureServerStarted() -> UInt16 {
        guard storageIsPrivate else { return 0 }
        if serverPort != 0 { return serverPort }
        let sem = DispatchSemaphore(value: 0)

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        if let listener = try? NWListener(using: parameters) {
            listener.stateUpdateHandler = { state in
                if case .ready = state {
                    sem.signal()
                } else if case .failed = state {
                    sem.signal()
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                self?.handleConnection(conn)
            }
            listener.start(queue: queue)
            guard sem.wait(timeout: .now() + 2.0) == .success,
                  let boundPort = listener.port?.rawValue, boundPort != 0 else {
                listener.cancel()
                return 0
            }
            listener.stateUpdateHandler = nil
            self.listener = listener
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
        // Older callers could supply a password that the viewer never enforced.
        // Refuse such requests rather than creating an unprotected link.
        guard password?.isEmpty ?? true else { return nil }
        let port = ensureServerStarted()
        guard port != 0 else { return nil }
        let settings = SettingsStore.shared
        var finalTitle = title
        let finalTags = tags

        if forcePrompt || settings.askForNameAndAdvancedOptionsOnUpload {
            // In interactive mode, honor provided defaults cleanly
            finalTitle = title.isEmpty ? "Catch Upload" : title
        }

        let (payloadData, extensionName): (Data, String) = {
            if settings.screenshotUploadQuality == .optimizedForSharing,
               let jpg = ImagePostProcessor.encode(image: image, format: .jpeg, quality: 0.85) {
                if jpg.count < data.count { return (jpg, "jpg") }
            }
            if data.starts(with: [0xFF, 0xD8, 0xFF]) { return (data, "jpg") }
            if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return (data, "png") }
            if let png = CatchDocument.pngData(from: image) { return (png, "png") }
            return (Data(), "png")
        }()

        guard !payloadData.isEmpty else { return nil }
        let id = UUID().uuidString.lowercased()
        let fileURL = storageDir.appendingPathComponent("\(id).\(extensionName)")
        do {
            try payloadData.write(to: fileURL, options: .atomic)
        } catch {
            return nil
        }
        let shareURL = "http://127.0.0.1:\(port)/s/\(id)"

        let item = CloudSharedItem(
            id: id,
            title: finalTitle,
            tags: finalTags,
            shareURL: shareURL,
            expiresAt: expiresInSeconds.map { Date().addingTimeInterval($0) },
            filePath: fileURL.path
        )

        recentUploads.insert(item, at: 0)
        sessionShares.insert(id)
        saveIndex()

        let clipboardItem = NSPasteboardItem()
        clipboardItem.setString(shareURL, forType: .string)
        clipboardItem.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([clipboardItem])
        return item
    }

    @discardableResult
    @MainActor
    public func addComment(toShareID id: String, author: String, text: String, x: Double, y: Double) -> CloudComment? {
        guard item(forShareID: id) != nil, author.utf8.count <= 128, text.utf8.count <= 4_096,
              x.isFinite, y.isFinite,
              let idx = recentUploads.firstIndex(where: { $0.id == id }) else { return nil }
        let comment = CloudComment(author: author, text: text, x: x, y: y)
        recentUploads[idx].comments.append(comment)
        saveIndex()
        return comment
    }

    @MainActor
    public func item(forShareID id: String) -> CloudSharedItem? {
        guard let item = recentUploads.first(where: { $0.id == id }) else { return nil }
        if let exp = item.expiresAt, exp < Date() {
            return nil
        }
        return item
    }

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { [weak conn] in conn?.cancel() }
        receiveHeader(conn, buffer: Data())
    }

    private func receiveHeader(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, finished, error in
            guard let self, error == nil else { conn.cancel(); return }
            let received = buffer + (data ?? Data())
            guard received.count <= 8_192 else { conn.cancel(); return }
            guard let end = received.range(of: Data("\r\n\r\n".utf8)) else {
                if finished { conn.cancel() } else { self.receiveHeader(conn, buffer: received) }
                return
            }
            guard let headers = String(data: received[..<end.lowerBound], encoding: .utf8) else {
                conn.cancel()
                return
            }
            Task { @MainActor in self.respond(conn, headers: headers) }
        }
    }

    @MainActor
    private func respond(_ conn: NWConnection, headers: String) {
        let lines = headers.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        let hosts = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }
        guard hosts.count == 1,
              hosts[0].dropFirst(5).trimmingCharacters(in: .whitespaces) == "127.0.0.1:\(serverPort)" else {
            sendHTTPResponse(conn, status: "403 Forbidden", contentType: "text/plain", body: Data())
            return
        }
        guard parts.count == 3, parts[0] == "GET" else {
            sendHTTPResponse(conn, status: "405 Method Not Allowed", contentType: "text/plain", body: Data())
            return
        }

        let path = parts[1].split(separator: "/", omittingEmptySubsequences: false)
        guard path.count == 3, path[0].isEmpty, ["s", "img"].contains(path[1]),
              let id = UUID(uuidString: String(path[2]))?.uuidString.lowercased(),
              sessionShares.contains(id), let item = item(forShareID: id) else {
            sendHTTPResponse(conn, status: "404 Not Found", contentType: "text/plain", body: Data())
            return
        }
        if path[1] == "s" {
            sendHTTPResponse(conn, status: "200 OK", contentType: "text/html; charset=utf-8",
                             body: Data(renderViewerHTML(for: item).utf8))
        } else {
            let fileURL = URL(fileURLWithPath: item.filePath)
            guard fileURL.deletingLastPathComponent() == storageDir,
                  ["png", "jpg"].contains(fileURL.pathExtension),
                  let bytes = try? Data(contentsOf: fileURL) else {
                sendHTTPResponse(conn, status: "404 Not Found", contentType: "text/plain", body: Data())
                return
            }
            let type = fileURL.pathExtension == "jpg" ? "image/jpeg" : "image/png"
            sendHTTPResponse(conn, status: "200 OK", contentType: type, body: bytes)
        }
    }

    private func renderViewerHTML(for item: CloudSharedItem) -> String {
        let title = item.title.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!doctype html>
        <html>
        <head><meta charset="utf-8"><title>\(title)</title></head>
        <body style="font-family:-apple-system,sans-serif;background:#0f172a;color:#f8fafc;padding:32px;text-align:center;">
          <h2>\(title)</h2>
          <div style="display:inline-block;position:relative;">
            <img src="/img/\(item.id)" style="max-width:90vw;border-radius:12px;box-shadow:0 20px 50px rgba(0,0,0,0.45);" />
          </div>
          <p>Comments: \(item.comments.count)</p>
        </body>
        </html>
        """
    }

    private func sendHTTPResponse(_ conn: NWConnection, status: String, contentType: String, body: Data) {
        let headers = [
            "Cache-Control: no-store",
            "Content-Security-Policy: default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'",
            "Referrer-Policy: no-referrer",
            "X-Content-Type-Options: nosniff",
            "Cross-Origin-Resource-Policy: same-origin"
        ].joined(separator: "\r\n")
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\(headers)\r\n\r\n"
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
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    private func loadIndex() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: indexURL),
           let loaded = try? decoder.decode([CloudSharedItem].self, from: data) {
            recentUploads = loaded
            // Encoding with the current schema drops the legacy plaintext password field.
            if data.range(of: Data("\"passwordHash\"".utf8)) != nil { saveIndex() }
        }
    }
}
