import AppKit
import Foundation
import CryptoKit
import Security
import Darwin

private struct DriveError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

private enum DriveVault {
    static let service = "com.catch.studio.google-drive"
    static func read(_ key: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key, kSecReturnData as String: true]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess ? item as? Data : nil
    }
    static func write(_ data: Data, key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query; add[kSecValueData as String] = data
            let result = SecItemAdd(add as CFDictionary, nil)
            guard result == errSecSuccess else { throw DriveError("Keychain error \(result).") }
        } else if status != errSecSuccess { throw DriveError("Keychain error \(status).") }
    }
    static func delete(_ key: String) { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key] as CFDictionary) }
}

private struct DriveCredentials: Codable {
    var clientID: String
    var clientSecret: String
    var refreshToken: String
    var email: String
}
private struct DriveAttempt: Codable {
    var fileID: String
    var session: String?
    var completed: Bool = false
}
private struct GoogleClientFile: Decodable {
    struct Client: Decodable { let client_id: String; let client_secret: String }
    let installed: Client
}

@MainActor final class GoogleDrive: ObservableObject {
    static let shared = GoogleDrive()
    @Published private(set) var account: String?
    @Published var message: String?
    @Published private(set) var connecting = false
    @Published private(set) var transferring = false
    private var credentials: DriveCredentials?
    private init() {
        if let data = DriveVault.read("credentials"), let value = try? JSONDecoder().decode(DriveCredentials.self, from: data) {
            credentials = value; account = value.email
        }
    }
    func connect() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.message = "Choose the Desktop OAuth client JSON downloaded from Google Cloud."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let client = try JSONDecoder().decode(GoogleClientFile.self, from: Data(contentsOf: url)).installed
            connecting = true; message = "Complete Google sign-in in your browser."
            Task {
                do {
                    let result = try await DriveAPI.authorize(clientID: client.client_id, secret: client.client_secret)
                    try DriveVault.write(JSONEncoder().encode(result), key: "credentials")
                    credentials = result; account = result.email; message = "Connected to Google Drive."
                } catch { message = "Could not connect: \(error.localizedDescription)" }
                connecting = false
            }
        } catch { message = "Choose a valid Google Desktop OAuth client JSON: \(error.localizedDescription)" }
    }
    func disconnect() {
        DriveVault.delete("credentials"); credentials = nil; account = nil
        message = "Disconnected. Existing Drive files and links remain; manage their access in Google Drive."
    }
    func upload(url: URL, anyone: Bool, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        guard let credentials else { throw DriveError("Connect Google Drive in Recording settings first.") }
        guard !transferring else { throw DriveError("Another Drive upload is already in progress.") }
        transferring = true
        defer { transferring = false }
        return try await DriveAPI.upload(url: url, credentials: credentials, anyone: anyone, progress: progress)
    }
}

private enum DriveAPI {
    private static let api = "https://www.googleapis.com/drive/v3"
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw DriveError("Could not generate secure random data.") }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func form(_ pairs: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        return pairs.map { "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&").data(using: .utf8)!
    }
    private static func request(_ request: URLRequest, accepted: Set<Int> = [200]) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DriveError("No response from Google Drive.") }
        guard accepted.contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { $0["error"] as? [String: Any] }.flatMap { $0["message"] as? String }
            throw DriveError("Google returned HTTP \(http.statusCode)\(detail.map { ": " + $0 } ?? "").")
        }
        return (data, http)
    }
    private static func json(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DriveError("Google returned an invalid response.") }; return object
    }
    private static func token(_ fields: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!); req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"); req.httpBody = form(fields)
        return try json(await request(req).0)
    }
    static func authorize(clientID: String, secret: String) async throws -> DriveCredentials {
        let verifier = try random(), state = try random()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let listener = try LoopbackListener()
        let redirect = "http://127.0.0.1:\(listener.port)/"
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = ["client_id": clientID, "redirect_uri": redirect, "response_type": "code", "scope": "https://www.googleapis.com/auth/drive.file", "code_challenge": challenge, "code_challenge_method": "S256", "state": state, "access_type": "offline", "prompt": "consent"].map { URLQueryItem(name: $0.key, value: $0.value) }
        let authorizationURL = components.url!
        _ = await MainActor.run { NSWorkspace.shared.open(authorizationURL) }
        let query = try await listener.receive()
        guard query["state"] == state else { throw DriveError("Google sign-in state did not match. Try again.") }
        guard let code = query["code"] else { throw DriveError("Google sign-in was cancelled or denied.") }
        let response = try await token(["code": code, "client_id": clientID, "client_secret": secret, "redirect_uri": redirect, "grant_type": "authorization_code", "code_verifier": verifier])
        guard let refresh = response["refresh_token"] as? String, let access = response["access_token"] as? String else { throw DriveError("Google did not return a refresh credential. Reconnect and grant consent.") }
        let data = try await call("\(api)/about?fields=user(emailAddress,displayName)", access: access).0
        guard let user = try json(data)["user"] as? [String: Any], let email = user["emailAddress"] as? String else { throw DriveError("Could not read the connected Drive account.") }
        return DriveCredentials(clientID: clientID, clientSecret: secret, refreshToken: refresh, email: email)
    }
    private static func call(_ url: String, access: String, method: String = "GET", body: Data? = nil, headers: [String: String] = [:], accepted: Set<Int> = [200]) async throws -> (Data, HTTPURLResponse) {
        guard let parsed = URL(string: url), parsed.scheme == "https", ["www.googleapis.com", "upload.googleapis.com"].contains(parsed.host ?? "") else { throw DriveError("Invalid Drive endpoint.") }
        var req = URLRequest(url: parsed); req.httpMethod = method; req.httpBody = body; req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        for (key, value) in headers { req.setValue(value, forHTTPHeaderField: key) }
        return try await request(req, accepted: accepted)
    }
    static func upload(url: URL, credentials: DriveCredentials, anyone: Bool, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        guard url.isFileURL, url.pathExtension.lowercased() == "mp4" else { throw DriveError("Choose a finalized MP4 recording.") }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes[.size] as? NSNumber)?.int64Value, size > 0, let modified = attributes[.modificationDate] as? Date else { throw DriveError("The recording is empty or unavailable.") }
        let identity = "\(credentials.clientID)|\(credentials.email)|\(url.standardizedFileURL.path)|\(size)|\(modified.timeIntervalSince1970)"
        let key = "attempt-" + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let tokenResponse = try await token(["client_id": credentials.clientID, "client_secret": credentials.clientSecret, "refresh_token": credentials.refreshToken, "grant_type": "refresh_token"])
        guard let access = tokenResponse["access_token"] as? String else { throw DriveError("Google did not return an access token. Reconnect your account.") }
        var attempt: DriveAttempt
        if let data = DriveVault.read(key), let saved = try? JSONDecoder().decode(DriveAttempt.self, from: data) { attempt = saved }
        else {
            let response = try json(await call("\(api)/files/generateIds?count=1&space=drive", access: access).0)
            guard let id = (response["ids"] as? [String])?.first else { throw DriveError("Drive did not allocate a file ID.") }
            attempt = DriveAttempt(fileID: id); try DriveVault.write(JSONEncoder().encode(attempt), key: key)
        }
        func save() throws { try DriveVault.write(JSONEncoder().encode(attempt), key: key) }
        let fileURL = "\(api)/files/\(attempt.fileID)?fields=id,name,webViewLink"
        // A completed file may exist even if the final upload response was lost.
        if !attempt.completed, (try? await call(fileURL, access: access)) != nil { attempt.completed = true; try save() }
        if !attempt.completed {
            if attempt.session == nil {
                let metadata = try JSONSerialization.data(withJSONObject: ["id": attempt.fileID, "name": url.lastPathComponent, "mimeType": "video/mp4"])
                let (_, response) = try await call("https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable", access: access, method: "POST", body: metadata, headers: ["Content-Type": "application/json; charset=UTF-8", "X-Upload-Content-Type": "video/mp4", "X-Upload-Content-Length": "\(size)"])
                guard let location = response.value(forHTTPHeaderField: "Location") else { throw DriveError("Drive did not return an upload session.") }
                attempt.session = location; try save()
            }
            guard let session = attempt.session else { throw DriveError("No upload session.") }
            let (_, status) = try await call(session, access: access, method: "PUT", body: Data(), headers: ["Content-Length": "0", "Content-Range": "bytes */\(size)"], accepted: [200, 201, 308, 404, 410])
            if status.statusCode == 404 || status.statusCode == 410 {
                // Keep the allocated ID; the next retry starts a fresh session with the same ID.
                attempt.session = nil; try save(); throw DriveError("The upload session expired. Retry to resume using the same Drive file ID.")
            }
            if status.statusCode == 200 || status.statusCode == 201 { attempt.completed = true; try save() }
            var offset: Int64 = 0
            if let range = status.value(forHTTPHeaderField: "Range"), let last = range.split(separator: "-").last, let value = Int64(last) { offset = value + 1 }
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            while !attempt.completed && offset < size {
                try Task.checkCancellation(); try handle.seek(toOffset: UInt64(offset))
                let chunk = try handle.read(upToCount: Int(min(Int64(8 * 1024 * 1024), size - offset))) ?? Data()
                guard !chunk.isEmpty else { throw DriveError("The recording changed or could not be read. Retry after checking the file.") }
                let end = offset + Int64(chunk.count) - 1
                let (_, response) = try await call(session, access: access, method: "PUT", body: chunk, headers: ["Content-Type": "video/mp4", "Content-Length": "\(chunk.count)", "Content-Range": "bytes \(offset)-\(end)/\(size)"], accepted: [200, 201, 308])
                if response.statusCode == 308 {
                    guard let range = response.value(forHTTPHeaderField: "Range"), let last = range.split(separator: "-").last, let value = Int64(last), value >= offset, value <= end else { throw DriveError("Drive returned an invalid upload offset. Retry to check the session.") }
                    offset = value + 1
                } else { offset = size; attempt.completed = true; try save() }
                await progress(Double(offset) / Double(size))
            }
        }
        let metadata = try json(await call(fileURL, access: access).0)
        guard let link = metadata["webViewLink"] as? String, let result = URL(string: link), result.scheme == "https" else { throw DriveError("The file uploaded, but Drive did not provide a viewer link. Retry.") }
        do {
            let permissionsURL = "\(api)/files/\(attempt.fileID)/permissions?fields=permissions(id,type,role,allowFileDiscovery)"
            let list = try json(await call(permissionsURL, access: access).0)
            guard let permissions = list["permissions"] as? [[String: Any]] else { throw DriveError("Could not verify Drive permissions.") }
            let existing = permissions.filter { $0["type"] as? String == "anyone" }
            if anyone, let current = existing.first,
               (current["role"] as? String != "reader" || current["allowFileDiscovery"] as? Bool != false) {
                throw DriveError("The existing public permission differs from the requested reader link. Adjust it in Drive.")
            }
            if anyone && existing.isEmpty {
                let body = try JSONSerialization.data(withJSONObject: ["type": "anyone", "role": "reader", "allowFileDiscovery": false])
                _ = try await call("\(api)/files/\(attempt.fileID)/permissions", access: access, method: "POST", body: body, headers: ["Content-Type": "application/json"], accepted: [200])
            } else if !anyone {
                for permission in existing {
                    guard let id = permission["id"] as? String else { throw DriveError("Could not verify existing link access.") }
                    _ = try await call("\(api)/files/\(attempt.fileID)/permissions/\(id)", access: access, method: "DELETE", accepted: [200, 204])
                }
            }
            let checked = try json(await call(permissionsURL, access: access).0)
            guard let verified = checked["permissions"] as? [[String: Any]] else { throw DriveError("Could not verify Drive permissions.") }
            let publicPermissions = verified.filter { $0["type"] as? String == "anyone" }
            if anyone {
                guard publicPermissions.contains(where: { $0["role"] as? String == "reader" && $0["allowFileDiscovery"] as? Bool == false }) else { throw DriveError("Drive did not confirm the requested link access.") }
            } else if !publicPermissions.isEmpty { throw DriveError("Drive did not confirm Restricted access.") }
        } catch { throw DriveSharingError(link: result, underlying: error.localizedDescription) }
        return result
    }
}

struct DriveSharingError: LocalizedError {
    let link: URL
    let underlying: String
    var errorDescription: String? { "Uploaded to Drive. Link sharing was blocked. \(underlying)" }
}

private final class LoopbackListener {
    let fd: Int32
    let port: UInt16
    init() throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw DriveError("Could not open sign-in callback.") }
        var addr = sockaddr_in(); addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = 0; addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(socketFD, 1) == 0 else { close(socketFD); throw DriveError("Could not start sign-in callback.") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) } }
        fd = socketFD
        port = UInt16(bigEndian: addr.sin_port)
    }
    deinit { close(fd) }
    func receive() async throws -> [String: String] {
        try await Task.detached { [self] in
            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pollFD, 1, 180_000) > 0 else { throw DriveError("Google sign-in timed out.") }
            let client = accept(fd, nil, nil); guard client >= 0 else { throw DriveError("Could not receive sign-in callback.") }; defer { close(client) }
            var timeout = timeval(tv_sec: 5, tv_usec: 0); setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var buffer = [UInt8](repeating: 0, count: 8192); let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0, let request = String(bytes: buffer.prefix(count), encoding: .utf8), let line = request.components(separatedBy: "\r\n").first else { throw DriveError("Invalid sign-in callback.") }
            let parts = line.split(separator: " "); guard parts.count >= 2, parts[0] == "GET", let components = URLComponents(string: "http://127.0.0.1\(parts[1])") else { throw DriveError("Invalid sign-in callback.") }
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nReturn to Catch to finish connecting Google Drive."
            _ = response.withCString { send(client, $0, strlen($0), 0) }
            var result: [String: String] = [:]; for item in components.queryItems ?? [] { if result[item.name] != nil { throw DriveError("Invalid sign-in callback.") }; result[item.name] = item.value }
            return result
        }.value
    }
}
