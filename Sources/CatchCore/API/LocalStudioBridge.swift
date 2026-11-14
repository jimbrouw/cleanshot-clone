import AppKit
import AVFoundation
import Foundation
import Darwin
import UniformTypeIdentifiers

/// The listener is off by default and only accepts connections from a private local socket.
final class LocalStudioBridge: ObservableObject {
    static let shared = LocalStudioBridge()
    @Published private(set) var enabled = false
    @Published private(set) var selectedTake: URL?
    @Published private(set) var captureKey: String?
    @Published var includeNotesInNextTake = false
    @Published var error: String?
    var editNotes = ""
    private var takeNotes: (script: String, notes: String)?
    private var selectedStamp: MediaStamp?
    private var selectedHandoff: TakeHandoff?
    private var selectionRequest = UUID()
    private var listener: Int32 = -1
    private var generation = 0
    private let queue = DispatchQueue(label: "com.catchapp.local-bridge", qos: .userInitiated)
    private let connectionSlots = DispatchSemaphore(value: 4)
    private var directory: String { "/tmp/catch-studio-\(getuid())" }
    var socketPath: String { directory + "/bridge.sock" }

    func enable() {
        guard !enabled else { return }
        do {
            if mkdir(directory, 0o700) != 0 && errno != EEXIST { throw BridgeError.system("Create socket directory") }
            var info = stat()
            guard lstat(directory, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == getuid(), (info.st_mode & 0o077) == 0 else { throw BridgeError.message("Bridge directory is not private or is not owned by this user.") }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw BridgeError.system("Create socket") }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let path = socketPath
            guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); throw BridgeError.message("Socket path is too long.") }
            withUnsafeMutableBytes(of: &address.sun_path) { bytes in
                path.utf8CString.withUnsafeBytes { bytes.copyBytes(from: $0) }
            }
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            if lstat(path, &info) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid() else { close(fd); throw BridgeError.message("Unsafe existing bridge socket.") }
                let probe = socket(AF_UNIX, SOCK_STREAM, 0)
                guard probe >= 0 else { close(fd); throw BridgeError.system("Probe socket") }
                _ = fcntl(probe, F_SETFL, O_NONBLOCK)
                let active = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
                let probeError = errno
                close(probe)
                guard !active, probeError == ECONNREFUSED || probeError == ENOENT else {
                    close(fd); throw BridgeError.message("Another Catch bridge may be running.")
                }
                unlink(path)
            }
            let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard result == 0 else { close(fd); throw BridgeError.system("Bind socket") }
            guard chmod(path, 0o600) == 0, listen(fd, 8) == 0 else { close(fd); unlink(path); throw BridgeError.system("Listen on socket") }
            listener = fd
            generation += 1
            let currentGeneration = generation
            enabled = true
            error = nil
            queue.async { [weak self] in self?.acceptLoop(fd: fd, generation: currentGeneration) }
        } catch { self.error = error.localizedDescription }
    }

    func disable() {
        guard enabled else { return }
        enabled = false
        clearSelection()
        endCaptureSession()
        generation += 1
        // The accept loop owns closing the descriptor so it cannot accept on a reused fd.
        if listener >= 0 { shutdown(listener, SHUT_RDWR); listener = -1 }
        unlink(socketPath)
    }

    func beginCaptureSession() {
        guard enabled else { return }
        captureKey = UUID().uuidString + UUID().uuidString
    }

    func copyCaptureKey() {
        guard let captureKey else { return }
        let item = NSPasteboardItem()
        item.setString(captureKey, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    func endCaptureSession() {
        captureKey = nil
        editNotes = ""
        includeNotesInNextTake = false
    }

    func clearSelection() {
        selectionRequest = UUID()
        selectedTake = nil
        selectedStamp = nil
        selectedHandoff = nil
    }

    func selectTake() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            do { try await selectTake(url); error = nil }
            catch is CancellationError {}
            catch { self.error = error.localizedDescription }
        }
    }

    // Called only after the user chooses a file in the open panel.
    @MainActor
    func selectTake(_ url: URL) async throws {
        guard enabled else { throw BridgeError.message("Bridge is disabled.") }
        clearSelection()
        let request = selectionRequest
        let url = url.standardizedFileURL
        let stamp = try mediaStamp(for: url)
        let handoff = try readHandoff(for: url)
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard enabled, selectionRequest == request else { throw CancellationError() }
        guard playable, !tracks.isEmpty, try mediaStamp(for: url) == stamp else {
            throw BridgeError.message("The selected take is not a stable, playable video.")
        }
        selectedStamp = stamp
        selectedHandoff = handoff
        selectedTake = url
    }

    func snapshotForTake() {
        takeNotes = includeNotesInNextTake ? (TeleprompterController.shared.scriptText, editNotes) : nil
        includeNotesInNextTake = false
        editNotes = ""
    }
    func saveHandoff(for url: URL) throws {
        guard let takeNotes else { return }
        self.takeNotes = nil
        let stamp = try mediaStamp(for: url)
        let handoff = TakeHandoff(version: 2, mp4: url.lastPathComponent, script: takeNotes.script,
                                  edit_notes: takeNotes.notes, media: stamp)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let destination = handoffURL(for: url)
        try encoder.encode(handoff).write(to: destination, options: .atomic)
    }
    private func handoffURL(for url: URL) -> URL { url.deletingPathExtension().appendingPathExtension("handoff.json") }
    private struct MediaStamp: Codable, Equatable {
        let bytes: Int
        let modified: Date
        let inode: UInt64
        let device: UInt64
    }
    private struct TakeHandoff: Codable, Equatable {
        let version: Int
        let mp4: String
        let script: String
        let edit_notes: String
        let media: MediaStamp
    }
    private func mediaStamp(for url: URL) throws -> MediaStamp {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard url.isFileURL, url.pathExtension.lowercased() == "mp4",
              attributes[.type] as? FileAttributeType == .typeRegular,
              let bytes = attributes[.size] as? Int, bytes > 0,
              let modified = attributes[.modificationDate] as? Date,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let device = attributes[.systemNumber] as? NSNumber else {
            throw BridgeError.message("Select a finished Catch MP4.")
        }
        return MediaStamp(bytes: bytes, modified: modified, inode: inode.uint64Value, device: device.uint64Value)
    }
    private func readHandoff(for url: URL) throws -> TakeHandoff {
        let path = handoffURL(for: url)
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? Int, size <= 262_144,
              let handoff = try? JSONDecoder().decode(TakeHandoff.self, from: Data(contentsOf: path)),
              handoff.version == 2, handoff.mp4 == url.lastPathComponent,
              handoff.media == (try mediaStamp(for: url)) else {
            throw BridgeError.message("Select the original finished Catch take with its matching handoff.")
        }
        return handoff
    }

    private func acceptLoop(fd: Int32, generation: Int) {
        defer { close(fd) }
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            var peer: uid_t = 0
            var group: gid_t = 0
            guard getpeereid(client, &peer, &group) == 0, peer == getuid(),
                  connectionSlots.wait(timeout: .now()) == .success else {
                close(client)
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                defer { close(client); connectionSlots.signal() }
                serve(client: client, generation: generation)
            }
        }
    }
    private func serve(client: Int32, generation: Int) {
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        var complete = false
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while data.count < 1_048_576 {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { break }
            var descriptor = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, Int32(ceil(remaining * 1000))) > 0 else { break }
            let count = read(client, &chunk, min(chunk.count, 1_048_576 - data.count))
            guard count > 0 else { break }
            let bytes = chunk.prefix(count)
            if let newline = bytes.firstIndex(of: 10) {
                data.append(contentsOf: bytes[..<newline])
                complete = true
                break
            }
            data.append(contentsOf: bytes)
        }
        guard complete else { writeResponse(["error": "Incomplete or oversized request."], to: client); return }
        guard let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { writeResponse(["error": "Invalid request."], to: client); return }
        let semaphore = DispatchSemaphore(value: 0)
        var response: [String: Any] = ["error": "Bridge request timed out."]
        let operationDeadline = ProcessInfo.processInfo.systemUptime + 60
        DispatchQueue.main.async {
            guard ProcessInfo.processInfo.systemUptime < operationDeadline,
                  self.enabled, self.generation == generation else {
                response = ["error": "Bridge session expired or was disabled."]; semaphore.signal(); return
            }
            let action = request["action"] as? String
            let key = request["capture_key"] as? String
            self.execute(request) { result in
                response = self.enabled && self.generation == generation &&
                    (action == "selected_take" || result["error"] != nil || (key != nil && self.captureKey == key))
                    ? result : ["error": "Bridge access was revoked. Check Catch for the action's status."]
                semaphore.signal()
            }
        }
        if semaphore.wait(timeout: .now() + 60) == .timedOut { writeResponse(["error": "Bridge request timed out."], to: client); return }
        writeResponse(response, to: client)
    }
    private func writeResponse(_ object: [String: Any], to fd: Int32) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(10)
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                let n = Darwin.send(fd, base.advanced(by: sent), bytes.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
    }
    private func execute(_ request: [String: Any], completion: @escaping ([String: Any]) -> Void) {
        let studio = ScreenRecordingStudio.shared
        let action = request["action"] as? String
        if action != "selected_take" {
            guard let captureKey, request["capture_key"] as? String == captureKey else {
                completion(["error": "Start a capture session in Catch and supply its session key."])
                return
            }
        }
        switch action {
        case "load_script":
            guard let script = request["script"] as? String else { completion(["error": "script must be text"]); return }
            let notes = request["edit_notes"] as? String ?? ""
            guard script.utf8.count + notes.utf8.count <= 32_768 else {
                completion(["error": "Script and notes exceed 32 KB."]); return
            }
            guard studio.state == .idle else { completion(["error": "Load a script before starting a take."]); return }
            TeleprompterController.shared.pause()
            TeleprompterController.shared.scriptText = script
            editNotes = notes
            completion(["ok": true])
        case "status":
            let state: String
            switch studio.state { case .idle: state = "idle"; case .preparing: state = "preparing"; case .recording: state = "recording"; case .paused: state = "paused"; case .finishing: state = "finishing" }
            var result: [String: Any] = ["state": state, "bridge_enabled": true, "elapsed_seconds": studio.elapsedSeconds]
            if let error = studio.recordingError { result["recording_error"] = error }
            completion(result)
        case "start":
            guard studio.state == .idle else { completion(["error": "Studio is not idle."]); return }
            studio.presentStudio(showPresenterOverlays: false)
            let session = captureKey
            DispatchQueue.main.async {
                guard session != nil, self.captureKey == session, studio.state == .idle else {
                    completion(["error": "Capture session ended or Studio is busy."]); return
                }
                studio.startRecording()
                self.waitForStart(studio, attempts: 150, completion: completion)
            }
        case "pause":
            guard case .recording = studio.state else { completion(["error": "Studio is not recording."]); return }
            studio.pauseRecording(); completion(["ok": true, "state": "paused"])
        case "resume":
            guard case .paused = studio.state else { completion(["error": "Studio is not paused."]); return }
            studio.resumeRecording(); completion(["ok": true, "state": "recording"])
        case "stop":
            guard studio.state.isActive || studio.state == .preparing else { completion(["error": "No active take to stop."]); return }
            studio.stopRecording(presentQuickAccess: false) { url, _ in
                if let url {
                    var result: [String: Any] = ["ok": true, "mp4_path": url.path]
                    if let error = studio.recordingError { result["warning"] = error }
                    completion(result)
                } else { completion(["error": studio.recordingError ?? "Recording did not finalize."]) }
            }
        case "screenshot":
            let prompter = TeleprompterController.shared
            guard !prompter.isVisible || !prompter.hideFromCapture else {
                completion(["error": "Close the hidden teleprompter before requesting an agent screenshot."])
                return
            }
            guard CGPreflightScreenCaptureAccess() else { completion(["error": "Screen Recording permission is required."]); return }
            let screen = CaptureEngine.shared.resolveScreen(displayIndex: nil)
            guard let cg = CaptureEngine.shared.captureDisplayCGImageIfAvailable(screen: screen) else { completion(["error": "Screen capture failed."]); return }
            let rep = NSBitmapImageRep(cgImage: cg)
            guard let data = rep.representation(using: .png, properties: [:]) else { completion(["error": "Could not encode screenshot."]); return }
            let item = HistoryStore.shared.recordCapture(image: cg, imageData: data, title: "Bridge Screenshot \(UUID().uuidString.prefix(6))", mediaType: .screenshot, fileExtension: "png")
            if FileManager.default.fileExists(atPath: item.filePath) { completion(["ok": true, "path": item.filePath]) } else { completion(["error": "Could not save screenshot."]) }
        case "selected_take":
            guard let url = selectedTake, let selectedStamp, let handoff = selectedHandoff else {
                completion(["error": "Select a finished take in Catch first."]); return
            }
            do {
                guard try mediaStamp(for: url) == selectedStamp, try readHandoff(for: url) == handoff else {
                    throw BridgeError.message("The media or edit notes changed. Select the take again.")
                }
                completion(["mp4_path": url.path, "handoff_path": handoffURL(for: url).path,
                            "script": handoff.script, "edit_notes": handoff.edit_notes])
            } catch { completion(["error": error.localizedDescription]) }
        default: completion(["error": "Unknown bridge action."])
        }
    }
    private func waitForStart(_ studio: ScreenRecordingStudio, attempts: Int, completion: @escaping ([String: Any]) -> Void) {
        if case .recording = studio.state { completion(["ok": true, "state": "recording"]); return }
        if studio.state == .idle { completion(["error": studio.recordingError ?? "Recording did not start."]); return }
        guard attempts > 0 else { completion(["error": "Recording is still preparing."]); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.waitForStart(studio, attempts: attempts - 1, completion: completion) }
    }
    enum BridgeError: LocalizedError {
        case message(String), system(String)
        var errorDescription: String? {
            switch self { case .message(let value): return value; case .system(let op): return "\(op): \(String(cString: strerror(errno)))" }
        }
    }
}

import SwiftUI
struct StudioBridgeSettingsView: View {
    @ObservedObject private var bridge = LocalStudioBridge.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Allow local MCP access (off on launch)", isOn: Binding(get: { bridge.enabled }, set: { $0 ? bridge.enable() : bridge.disable() }))
            Text("Editing clients can read the take you select. Capture requires a separate session key.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Select finished take for editing…") { bridge.selectTake() }.disabled(!bridge.enabled)
                if let url = bridge.selectedTake {
                    Text(url.lastPathComponent).font(.caption)
                    Button("Clear Selection") { bridge.clearSelection() }
                }
            }
            Toggle("Save script and edit notes with next take", isOn: $bridge.includeNotesInNextTake)
            if bridge.captureKey != nil {
                Button("End Agent Capture Session") { bridge.endCaptureSession() }
                Button("Copy Capture Session Key") { bridge.copyCaptureKey() }
            } else {
                Button("Start Agent Capture Session") { bridge.beginCaptureSession() }.disabled(!bridge.enabled)
            }
            if let error = bridge.error { Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
        }
    }
}
