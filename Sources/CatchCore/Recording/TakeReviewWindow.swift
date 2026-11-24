import AppKit
import SwiftUI
import AVFoundation
import AVKit
import Speech
import UniformTypeIdentifiers

/// Reviews a finalized take without modifying its source file.
public final class TakeReviewWindowController {
    public static let shared = TakeReviewWindowController()
    private var windows: [NSWindow] = []

    public func show(url: URL) {
        let discovered = Self.discoverBundle(for: url)
        show(bundle: discovered)
    }

    public func show(bundle: RecordedTakeBundle) {
        DispatchQueue.main.async {
            let model = TakeReviewModel(bundle: bundle)
            let window = NSWindow(contentRect: NSRect(x: 180, y: 140, width: 840, height: 700),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Review Take — \(bundle.primaryVideoURL.lastPathComponent)"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: TakeReviewView(model: model))
            self.windows.removeAll { !$0.isVisible }
            self.windows.append(window)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    static func discoverBundle(for url: URL) -> RecordedTakeBundle {
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let base: String?
        if stem.hasSuffix("-screen") {
            base = String(stem.dropLast("-screen".count))
        } else if stem.hasSuffix("-camera") {
            base = String(stem.dropLast("-camera".count))
        } else {
            base = nil
        }

        guard let base else {
            return RecordedTakeBundle(primaryVideoURL: url)
        }
        let screenCandidate = folder.appendingPathComponent("\(base)-screen.mp4")
        let cameraCandidate = folder.appendingPathComponent("\(base)-camera.mp4")
        let micCandidate = folder.appendingPathComponent("\(base)-mic.wav")
        let sysCandidate = folder.appendingPathComponent("\(base)-system-audio.wav")

        let screenURL = fm.fileExists(atPath: screenCandidate.path) ? screenCandidate : nil
        let cameraURL = fm.fileExists(atPath: cameraCandidate.path) ? cameraCandidate : nil
        let micURL = fm.fileExists(atPath: micCandidate.path) ? micCandidate : nil
        let sysURL = fm.fileExists(atPath: sysCandidate.path) ? sysCandidate : nil
        let isTakeFolder = folder.lastPathComponent == base

        return RecordedTakeBundle(
            primaryVideoURL: url,
            screenVideoURL: screenURL,
            cameraVideoURL: cameraURL,
            cameraResolution: nil,
            microphoneStemURL: micURL,
            systemAudioStemURL: sysURL,
            takeDirectoryURL: isTakeFolder ? folder : nil
        )
    }
}

private enum ReviewVideoTrack: String, CaseIterable {
    case screen = "Screen"
    case camera = "Camera (Full-Res)"
}

private final class TakeReviewModel: ObservableObject {
    let bundle: RecordedTakeBundle
    @Published var selectedTrack: ReviewVideoTrack
    @Published private(set) var source: URL
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
    @Published var captionStatus = "Generate captions when you need them."
    @Published var captionsEnabled = true
    @Published var transcribing = false
    @Published var playhead: Double = 0
    @Published var editedCopy: URL?
    @Published var shareEdited = false
    private var timeObserver: Any?
    private var transcriptionRequestID = UUID()

    var hasBothVideoTracks: Bool {
        bundle.screenVideoURL != nil && bundle.cameraVideoURL != nil
    }

    var assetSummaryBadges: [String] {
        var badges: [String] = []
        if bundle.screenVideoURL != nil { badges.append("Screen MP4") }
        if bundle.cameraVideoURL != nil {
            if let res = bundle.cameraResolution {
                badges.append("Camera \(res) HEVC")
            } else {
                badges.append("Camera HEVC")
            }
        }
        if bundle.microphoneStemURL != nil { badges.append("Mic WAV") }
        if bundle.systemAudioStemURL != nil { badges.append("System WAV") }
        return badges
    }

    var activeCaption: String {
        captions.first { playhead >= $0.start && playhead < $0.end }?.text ?? ""
    }

    func switchTrack(to track: ReviewVideoTrack) {
        guard track != selectedTrack else { return }
        let targetURL: URL?
        switch track {
        case .screen: targetURL = bundle.screenVideoURL
        case .camera: targetURL = bundle.cameraVideoURL
        }
        guard let targetURL else { return }
        player.pause()
        transcriptionRequestID = UUID()
        transcribing = false
        selectedTrack = track
        source = targetURL
        editedCopy = nil
        shareEdited = false
        player.replaceCurrentItem(with: AVPlayerItem(url: targetURL))
        loadSourceMetadata(for: targetURL)
    }

    func transcribe() {
        guard !transcribing else { return }
        let targetURL = source
        let requestID = UUID()
        transcriptionRequestID = requestID
        transcribing = true
        captionStatus = "Transcribing on this Mac…"
        TakeCaptions.recognize(url: targetURL) { [weak self] result in
            DispatchQueue.main.async {
                guard let self,
                      self.source == targetURL,
                      self.transcriptionRequestID == requestID else { return }
                self.transcribing = false
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

    init(bundle: RecordedTakeBundle) {
        self.bundle = bundle
        let initialTrack: ReviewVideoTrack = (bundle.screenVideoURL == nil && bundle.cameraVideoURL != nil) ? .camera : .screen
        self.selectedTrack = initialTrack
        let initialURL = (initialTrack == .camera ? bundle.cameraVideoURL : bundle.screenVideoURL) ?? bundle.primaryVideoURL
        self.source = initialURL
        self.player = AVPlayer(url: initialURL)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in self?.playhead = time.seconds }
        loadSourceMetadata(for: initialURL)
    }

    private func loadSourceMetadata(for url: URL) {
        playable = false
        duration = 0
        start = 0
        end = 0
        captions = []
        captionStatus = "Generate captions when you need them."
        let savedCaptions = TakeCaptions.load(for: url)
        if let savedCaptions {
            captions = savedCaptions
            captionStatus = savedCaptions.isEmpty ? "No speech was detected." : "Saved captions loaded."
        }
        Task {
            do {
                let asset = AVURLAsset(url: url)
                guard try await asset.load(.isPlayable) else { throw ReviewError.invalidDuration }
                let time = try await asset.load(.duration)
                let seconds = time.seconds
                guard seconds.isFinite, seconds > 0 else { throw ReviewError.invalidDuration }
                await MainActor.run {
                    guard self.source == url else { return }
                    self.duration = seconds
                    self.end = seconds
                    self.playable = true
                    if savedCaptions == nil && SFSpeechRecognizer.authorizationStatus() == .authorized {
                        self.transcribe()
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.source == url else { return }
                    self.message = "Could not open take: \(error.localizedDescription)"
                }
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

private struct TakePlaybackView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

private struct TakeReviewView: View {
    @ObservedObject var model: TakeReviewModel
    @ObservedObject private var drive = GoogleDrive.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(model.playable ? "Saved on this Mac" : "Checking local recording…").font(.headline)
                Spacer()
                if model.hasBothVideoTracks {
                    Picker("Track", selection: Binding(
                        get: { model.selectedTrack },
                        set: { model.switchTrack(to: $0) }
                    )) {
                        Text("Screen").tag(ReviewVideoTrack.screen)
                        Text("Camera (Full-Res)").tag(ReviewVideoTrack.camera)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }
            }
            if model.bundle.hasMultipleAssets || model.bundle.cameraVideoURL != nil {
                HStack(spacing: 6) {
                    ForEach(model.assetSummaryBadges, id: \.self) { badge in
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.secondary.opacity(0.16)))
                    }
                    Spacer()
                    if let folder = model.bundle.takeDirectoryURL {
                        Button("Show Take Folder in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting(model.bundle.allAssetURLs)
                            _ = folder
                        }
                        .controlSize(.small)
                    }
                }
            }
            ZStack(alignment: .bottom) {
                TakePlaybackView(player: model.player).frame(minHeight: 220)
                if model.captionsEnabled && !model.activeCaption.isEmpty {
                    Text(model.activeCaption).padding(8).background(.black.opacity(0.8)).foregroundStyle(.white).cornerRadius(6).padding(.bottom, 38).allowsHitTesting(false)
                }
            }
            HStack {
                Toggle("CC", isOn: $model.captionsEnabled).toggleStyle(.button)
                Text(model.captionStatus).font(.caption).textSelection(.enabled)
                Spacer()
                Button("Export Captions") { model.exportCaptions() }.disabled(model.captions.isEmpty || model.transcribing)
                Button(model.captions.isEmpty ? "Generate Captions" : "Regenerate Captions") { model.transcribe() }
                    .disabled(model.transcribing || model.duration <= 0)
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
