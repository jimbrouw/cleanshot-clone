import AppKit
import SwiftUI
import AVFoundation
import AVKit

/// Reviews a finalized take without modifying its source file.
public final class TakeReviewWindowController {
    public static let shared = TakeReviewWindowController()
    private var windows: [NSWindow] = []

    public func show(url: URL) {
        DispatchQueue.main.async {
            let model = TakeReviewModel(url: url)
            let window = NSWindow(contentRect: NSRect(x: 180, y: 160, width: 760, height: 520),
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
    @Published var start: Double = 0
    @Published var end: Double = 0
    @Published var busy = false
    @Published var message: String?

    init(url: URL) {
        source = url
        player = AVPlayer(url: url)
        Task {
            do {
                let time = try await AVURLAsset(url: url).load(.duration)
                let seconds = time.seconds
                guard seconds.isFinite, seconds > 0 else { throw ReviewError.invalidDuration }
                await MainActor.run { self.duration = seconds; self.end = seconds }
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
        TakeTrimmer.export(source: source, destination: destination, start: start, end: end) { result in
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success:
                    self.message = "Exported copy: \(destination.lastPathComponent)"
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
              let export = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetPassthrough) else {
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
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VideoPlayer(player: model.player).frame(minHeight: 260)
            HStack {
                Text("Start \(model.start, specifier: "%.1f")s")
                Slider(value: $model.start, in: 0...max(model.duration, 0.001))
            }
            HStack {
                Text("End \(model.end, specifier: "%.1f")s")
                Slider(value: $model.end, in: 0...max(model.duration, 0.001))
            }
            Text("Trim points may be adjusted to video keyframes. Check the exported copy.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Preview from Start") { model.player.seek(to: CMTime(seconds: model.start, preferredTimescale: 600)); model.player.play() }
                Button("Export Copy") { model.exportCopy() }.disabled(model.busy || model.duration <= 0)
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.source]) }
                if model.busy { ProgressView().controlSize(.small) }
            }
            if let message = model.message { Text(message).font(.caption).textSelection(.enabled) }
        }
        .padding()
    }
}
