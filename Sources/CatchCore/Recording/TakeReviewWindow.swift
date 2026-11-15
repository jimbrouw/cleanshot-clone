import AppKit
import SwiftUI
import AVFoundation
import AVKit
import UniformTypeIdentifiers

/// Reviews a finalized take without modifying its source file.
public final class TakeReviewWindowController {
    public static let shared = TakeReviewWindowController()
    private var windows: [NSWindow] = []

    public func show(url: URL) {
        DispatchQueue.main.async {
            let model = TakeReviewModel(url: url)
            let window = NSWindow(contentRect: NSRect(x: 180, y: 160, width: 800, height: 650),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Review Take — \(url.lastPathComponent)"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: TakeReviewView(model: model))
            self.windows.removeAll { !$0.isVisible }
            self.windows.append(window)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private final class TakeReviewModel: ObservableObject {
    let source: URL
    let player: AVPlayer
    @Published var duration: Double = 0
    @Published var playable = false
    @Published var start: Double = 0
    @Published var end: Double = 0
    @Published var busy = false
    @Published var message: String?
    @Published var uploadBusy = false
    @Published var uploadProgress: Double = 0
    @Published var anyone = false
    @Published var driveLink: URL?
    @Published var captions: [CaptionCue] = []
    @Published var captionStatus = "Preparing captions…"
    @Published var captionsEnabled = true
    @Published var playhead: Double = 0
    @Published var editedCopy: URL?
    @Published var shareEdited = false
    private var timeObserver: Any?

    var activeCaption: String {
        captions.first { playhead >= $0.start && playhead < $0.end }?.text ?? ""
    }

    func transcribe() {
        guard captionStatus != "Transcribing on this Mac…" else { return }
        captionStatus = "Transcribing on this Mac…"
        TakeCaptions.recognize(url: source) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let cues):
                    self.captions = cues
                    self.captionStatus = cues.isEmpty ? "No speech was detected." : "Captions ready. Review the text and timing."
                    self.saveCaptions()
                case .failure(let error):
                    let nsError = error as NSError
                    if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110 {
                        self.captionStatus = "No speech was detected. Retry if the recording contains speech."
                    } else { self.captionStatus = "Transcription unavailable: \(error.localizedDescription)" }
                }
            }
        }
    }

    func saveCaptions() {
        do { try TakeCaptions.save(captions, for: source) }
        catch { captionStatus = "Could not save caption edits: \(error.localizedDescription)" }
    }

    func exportCaptions() {
        guard !captions.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + ".srt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.standardizedFileURL != source.standardizedFileURL else { captionStatus = "Choose a separate SRT file."; return }
        do { try TakeCaptions.srt(captions).write(to: url, atomically: true, encoding: .utf8); captionStatus = "Exported captions for the full recording: \(url.lastPathComponent)" }
        catch { captionStatus = "Caption export failed: \(error.localizedDescription)" }
    }

    func upload() {
        guard !uploadBusy else { return }
        uploadBusy = true; uploadProgress = 0; message = nil; driveLink = nil
        Task { @MainActor in
            do {
                let uploadURL = shareEdited ? (editedCopy ?? source) : source
                let link = try await GoogleDrive.shared.upload(url: uploadURL, anyone: anyone) { self.uploadProgress = $0 }
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setString(link.absoluteString, forType: .string) else { driveLink = link; message = "Uploaded to Drive, but the link could not be copied. Open it in Drive."; uploadBusy = false; return }
                driveLink = link
                message = "Link copied. Drive may still be processing the video."
            } catch let error as DriveSharingError {
                driveLink = error.link; message = error.localizedDescription
            } catch { message = "Upload failed: \(error.localizedDescription). Retry to continue with the same Drive file." }
            uploadBusy = false
        }
    }

    deinit { if let timeObserver { player.removeTimeObserver(timeObserver) } }

    init(url: URL) {
        source = url
        player = AVPlayer(url: url)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in self?.playhead = time.seconds }
        if let saved = TakeCaptions.load(for: url) {
            captions = saved
            captionStatus = saved.isEmpty ? "No speech was detected." : "Saved captions loaded."
        } else { transcribe() }
        Task {
            do {
                let asset = AVURLAsset(url: url)
                guard try await asset.load(.isPlayable) else { throw ReviewError.invalidDuration }
                let time = try await asset.load(.duration)
                let seconds = time.seconds
                guard seconds.isFinite, seconds > 0 else { throw ReviewError.invalidDuration }
                await MainActor.run { self.duration = seconds; self.end = seconds; self.playable = true }
            } catch {
                await MainActor.run { self.message = "Could not open take: \(error.localizedDescription)" }
            }
        }
    }

    func exportCopy() {
        guard !busy, duration > 0, start >= 0, end <= duration, end > start else {
            message = "Choose an end time after the start time."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + "-trimmed.mp4"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard destination.standardizedFileURL != source.standardizedFileURL else {
            message = "Choose a new filename; the original take must be kept."
            return
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            message = "Choose a filename that does not already exist."
            return
        }
        busy = true
        let trimStart = start, trimEnd = end, captionSnapshot = captions
        TakeTrimmer.export(source: source, destination: destination, start: trimStart, end: trimEnd) { result in
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success:
                    self.editedCopy = destination
                    do {
                        if !captionSnapshot.isEmpty {
                            try TakeCaptions.save(TakeCaptions.trimmed(captionSnapshot, start: trimStart, end: trimEnd), for: destination)
                        }
                        self.message = "Saved edited copy: \(destination.lastPathComponent). Open it in Review to check and export its captions."
                    } catch { self.message = "Video saved, but captions could not be saved: \(error.localizedDescription)" }
                case .failure(let error):
                    self.message = "Export failed: \(error.localizedDescription). The original is unchanged."
                }
            }
        }
    }

    enum ReviewError: LocalizedError {
        case invalidDuration
        var errorDescription: String? { "The video has no usable duration." }
    }
}

enum TakeTrimmer {
    static func export(source: URL, destination: URL, start: Double, end: Double, completion: @escaping (Result<Void, Error>) -> Void) {
        guard source.standardizedFileURL != destination.standardizedFileURL,
              !FileManager.default.fileExists(atPath: destination.path),
              start.isFinite, end.isFinite, start >= 0, end > start,
              let export = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetHighestQuality) else {
            completion(.failure(TrimError.invalidRequest)); return
        }
        export.outputURL = destination
        export.outputFileType = .mp4
        export.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       end: CMTime(seconds: end, preferredTimescale: 600))
        export.exportAsynchronously {
            if export.status == .completed { completion(.success(())) }
            else {
                try? FileManager.default.removeItem(at: destination)
                completion(.failure(export.error ?? TrimError.failed))
            }
        }
    }
    enum TrimError: LocalizedError {
        case invalidRequest, failed
        var errorDescription: String? {
            switch self { case .invalidRequest: return "Choose a valid range and a new output file."; case .failed: return "The export did not complete." }
        }
    }
}

private struct TakeReviewView: View {
    @ObservedObject var model: TakeReviewModel
    @ObservedObject private var drive = GoogleDrive.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.playable ? "Saved on this Mac" : "Checking local recording…").font(.headline)
            ZStack(alignment: .bottom) {
                VideoPlayer(player: model.player).frame(minHeight: 220)
                if model.captionsEnabled && !model.activeCaption.isEmpty {
                    Text(model.activeCaption).padding(8).background(.black.opacity(0.8)).foregroundStyle(.white).cornerRadius(6).padding(.bottom, 38).allowsHitTesting(false)
                }
            }
            HStack {
                Toggle("CC", isOn: $model.captionsEnabled).toggleStyle(.button)
                Text(model.captionStatus).font(.caption).textSelection(.enabled)
                Spacer()
                Button("Export Captions") { model.exportCaptions() }.disabled(model.captions.isEmpty)
                Button("Retry") { model.transcribe() }.disabled(!model.captions.isEmpty)
            }
            if !model.captions.isEmpty {
                DisclosureGroup("Correct captions") {
                    ScrollView {
                        VStack {
                            ForEach($model.captions) { $cue in
                                HStack {
                                    Text("\(cue.start, specifier: "%.1f")s").font(.caption.monospacedDigit()).frame(width: 55)
                                    TextField("Caption", text: $cue.text).onChange(of: cue.text) { _, _ in model.saveCaptions() }
                                    Button("Play") { model.player.seek(to: CMTime(seconds: cue.start, preferredTimescale: 600)); model.player.play() }
                                }
                            }
                        }
                    }.frame(maxHeight: 130)
                }
            }
            HStack {
                Text("Start \(model.start, specifier: "%.1f")s")
                Slider(value: $model.start, in: 0...max(model.duration, 0.001))
            }
            HStack {
                Text("End \(model.end, specifier: "%.1f")s")
                Slider(value: $model.end, in: 0...max(model.duration, 0.001))
            }
            Text("Check the edited copy and its captions before sharing.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Edit: Preview from Start") { model.player.seek(to: CMTime(seconds: model.start, preferredTimescale: 600)); model.player.play() }
                Button("Save Edited Copy") { model.exportCopy() }.disabled(model.busy || model.duration <= 0)
                Button("Save File: Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.source]) }
                if let copy = model.editedCopy { Button("Review Edited Copy") { TakeReviewWindowController.shared.show(url: copy) } }
                if model.busy { ProgressView().controlSize(.small) }
            }
            Divider()
            Text("Share").font(.headline)
            if model.editedCopy != nil {
                Picker("Upload", selection: $model.shareEdited) {
                    Text("Full recording").tag(false)
                    Text("Edited copy").tag(true)
                }.pickerStyle(.segmented).disabled(model.uploadBusy)
            } else { Text("Upload: Full recording").font(.caption) }
            Text("Account: \(drive.account ?? "Not connected")  •  File: \((model.shareEdited ? model.editedCopy : nil)?.lastPathComponent ?? model.source.lastPathComponent)").font(.caption).textSelection(.enabled)
            HStack {
                Picker("Access", selection: $model.anyone) {
                    Text("Restricted").tag(false)
                    Text("Anyone with the link").tag(true)
                }.frame(width: 270).disabled(model.uploadBusy)
                Button("Upload and Copy Link") { model.upload() }.disabled(model.uploadBusy || drive.transferring || drive.account == nil || model.duration <= 0)
                if model.uploadBusy { ProgressView(value: model.uploadProgress).frame(width: 100) }
                if let link = model.driveLink { Button("Open in Drive") { NSWorkspace.shared.open(link) } }
            }
            if drive.account == nil { Button("Connect Google Drive in Settings") { SettingsWindowController.shared.show(tab: .recording) } }
            if let message = model.message { Text(message).font(.caption).textSelection(.enabled) }
            Text("In Drive, open the video → File information → Manage caption tracks → Add new caption tracks. Select the SRT for the video you uploaded.").font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }
}
