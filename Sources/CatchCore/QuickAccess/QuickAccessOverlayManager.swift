import Foundation
import AppKit
import SwiftUI
import QuickLookUI

public final class QuickAccessOverlayManager: ObservableObject {
    public static let shared = QuickAccessOverlayManager()

    @Published public private(set) var activeCards: [QuickAccessCardModel] = []
    @Published public private(set) var temporarilyHidden: Bool = false

    private var panels: [UUID: NSPanel] = [:]
    private var autoCloseTimers: [UUID: Timer] = [:]

    public struct QuickAccessCardModel: Identifiable {
        public let id: UUID
        public let result: CaptureResult
        public let historyItem: CaptureHistoryItem
    }

    public func present(result: CaptureResult, historyItem: CaptureHistoryItem) {
        DispatchQueue.main.async {
            let card = QuickAccessCardModel(id: result.id, result: result, historyItem: historyItem)
            self.activeCards.append(card)
            self.createPanel(for: card)
            self.relayoutPanels()
            self.scheduleAutoClose(for: card)
        }
    }

    public func presentFromFile(url: URL) {
        guard let nsImage = NSImage(contentsOf: url),
              let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = try? Data(contentsOf: url) else {
            return
        }
        let title = url.deletingPathExtension().lastPathComponent
        let format = ScreenshotFormat(rawValue: url.pathExtension.lowercased()) ?? .png
        let result = CaptureResult(
            image: cg,
            encodedData: data,
            fileName: title,
            format: format,
            sourceRect: CGRect(x: 0, y: 0, width: cg.width, height: cg.height),
            displayScale: 1.0
        )
        let historyItem = HistoryStore.shared.recordCapture(
            image: cg,
            imageData: data,
            title: title,
            mediaType: .screenshot,
            fileExtension: format.fileExtension
        )
        present(result: result, historyItem: historyItem)
    }

    public func restore(historyItem: CaptureHistoryItem) {
        let url = URL(fileURLWithPath: historyItem.filePath)
        guard let nsImage = NSImage(contentsOf: url),
              let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = try? Data(contentsOf: url) else {
            return
        }
        let format = ScreenshotFormat(rawValue: url.pathExtension.lowercased()) ?? .png
        let result = CaptureResult(
            id: historyItem.id,
            image: cg,
            encodedData: data,
            fileName: historyItem.title,
            format: format,
            capturedAt: historyItem.createdAt,
            sourceRect: CGRect(x: 0, y: 0, width: cg.width, height: cg.height),
            displayScale: 1.0
        )
        let card = QuickAccessCardModel(id: historyItem.id, result: result, historyItem: historyItem)
        DispatchQueue.main.async {
            if !self.activeCards.contains(where: { $0.id == card.id }) {
                self.activeCards.append(card)
                self.createPanel(for: card)
                self.relayoutPanels()
            }
        }
    }

    public func toggleTemporarilyHide() {
        DispatchQueue.main.async {
            self.temporarilyHidden.toggle()
            for panel in self.panels.values {
                if self.temporarilyHidden {
                    panel.orderOut(nil)
                } else {
                    panel.orderFrontRegardless()
                }
            }
        }
    }

    public func closeCard(id: UUID, markClosedInHistory: Bool = true) {
        DispatchQueue.main.async {
            self.autoCloseTimers[id]?.invalidate()
            self.autoCloseTimers.removeValue(forKey: id)
            self.panels[id]?.orderOut(nil)
            self.panels.removeValue(forKey: id)
            self.activeCards.removeAll { $0.id == id }
            if markClosedInHistory {
                HistoryStore.shared.markClosed(id: id)
            }
            self.relayoutPanels()
        }
    }

    public func restoreRecentlyClosed() {
        if let item = HistoryStore.shared.restoreMostRecentlyClosed() {
            restore(historyItem: item)
        }
    }

    private func createPanel(for card: QuickAccessCardModel) {
        let settings = SettingsStore.shared
        let scale = max(0.75, min(1.5, settings.overlaySize))
        let panelSize = CGSize(width: 260 * scale, height: 196 * scale)

        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let view = QuickAccessCardView(card: card, manager: self)
        panel.contentView = NSHostingView(rootView: view)
        panels[card.id] = panel
        if !temporarilyHidden {
            panel.orderFrontRegardless()
        }
    }

    private func relayoutPanels() {
        let settings = SettingsStore.shared
        let screen = settings.moveToActiveScreen
            ? CaptureEngine.shared.resolveScreen(displayIndex: nil)
            : (NSScreen.main ?? NSScreen.screens[0])
        let visible = screen.visibleFrame
        let margin: CGFloat = 18
        let gap: CGFloat = 12
        var currentY = visible.minY + margin

        for card in activeCards {
            guard let panel = panels[card.id] else { continue }
            let size = panel.frame.size
            let x: CGFloat = settings.overlayPosition == .left
                ? visible.minX + margin
                : visible.maxX - size.width - margin
            panel.setFrameOrigin(CGPoint(x: x, y: currentY))
            currentY += size.height + gap
        }
    }

    private func scheduleAutoClose(for card: QuickAccessCardModel) {
        let settings = SettingsStore.shared
        guard settings.autoCloseEnabled else { return }
        let interval = TimeInterval(max(3, settings.autoCloseIntervalSeconds))
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            if settings.autoCloseAction == .saveAndClose {
                _ = CaptureEngine.shared.saveCapture(result: card.result, askDestination: false)
            }
            self.closeCard(id: card.id)
        }
        autoCloseTimers[card.id] = timer
    }
}

private struct QuickAccessCardView: View {
    let card: QuickAccessOverlayManager.QuickAccessCardModel
    let manager: QuickAccessOverlayManager

    @State private var isHovering = false
    @State private var uploadStatus: String?

    var body: some View {
        let nsImage = NSImage(cgImage: card.result.image, size: NSSize(width: card.result.image.width, height: card.result.image.height))
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                DraggableThumbnailView(
                    image: nsImage,
                    fileURL: URL(fileURLWithPath: card.historyItem.filePath),
                    onDragCompleted: {
                        let keep = NSEvent.modifierFlags.contains(.option)
                        if SettingsStore.shared.closeAfterDragging && !keep {
                            manager.closeCard(id: card.id)
                        }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: 122)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 4) {
                    if isHovering {
                        Menu {
                            Button("Copy") { copyAction() }
                            Button("Save") { saveAction() }
                            Button("Annotate") { annotateAction() }
                            Button("Pin to the Screen") { pinAction() }
                            Button("Upload to Cloud") { uploadAction() }
                            Divider()
                            Button("Quick Look") { quickLookAction() }
                            Button("Show in Finder") { showInFinderAction() }
                            Button("Open With...") { openWithAction() }
                            Button("Open in Mail...") { openInMailAction() }
                            Divider()
                            Button("Temporarily Hide") { manager.toggleTemporarilyHide() }
                            Button("Close") { manager.closeCard(id: card.id) }
                        } label: {
                            Image(systemName: "ellipsis.circle.fill")
                                .foregroundStyle(.white, .black.opacity(0.65))
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 24, height: 24)
                    }

                    Button {
                        manager.closeCard(id: card.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white, .black.opacity(0.65))
                    }
                    .buttonStyle(.plain)
                }
                .padding(6)
            }

            HStack(spacing: 6) {
                actionBtn(systemImage: "doc.on.doc", help: "Copy", action: copyAction)
                actionBtn(systemImage: "square.and.arrow.down", help: "Save", action: saveAction)
                actionBtn(systemImage: "pencil.tip.crop.circle", help: "Annotate", action: annotateAction)
                actionBtn(systemImage: "pin", help: "Pin to Screen", action: pinAction)
                actionBtn(systemImage: "icloud.and.arrow.up", help: "Upload to Cloud", action: uploadAction)
            }

            HStack {
                Text("\(card.result.image.width) × \(card.result.image.height)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if let uploadStatus {
                    Text(uploadStatus)
                        .font(.caption2)
                        .foregroundStyle(.blue)
                } else {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(card.result.encodedData.count), countStyle: .file))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
        )
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private func actionBtn(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(maxWidth: .infinity, minHeight: 24)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(help)
    }

    private func copyAction() {
        CaptureEngine.shared.copyToClipboard(result: card.result)
        manager.closeCard(id: card.id)
    }

    private func saveAction() {
        let ask = NSEvent.modifierFlags.contains(.option) || SettingsStore.shared.saveButtonBehavior == .askDestination
        _ = CaptureEngine.shared.saveCapture(result: card.result, askDestination: ask)
        manager.closeCard(id: card.id)
    }

    private func annotateAction() {
        AnnotateWindowController.open(image: card.result.image, title: card.result.fileName, historyItem: card.historyItem)
        manager.closeCard(id: card.id, markClosedInHistory: false)
    }

    private func pinAction() {
        PinnedScreenshotController.shared.pin(image: card.result.image, title: card.result.fileName)
        manager.closeCard(id: card.id)
    }

    private func uploadAction() {
        uploadStatus = "Uploading..."
        Task { @MainActor in
            let uploaded = await CloudUploadService.shared.upload(
                image: card.result.image,
                data: card.result.encodedData,
                title: card.result.fileName,
                forcePrompt: NSEvent.modifierFlags.contains(.option)
            )
            uploadStatus = uploaded != nil ? "Link Copied" : "Failed"
            if uploaded != nil && SettingsStore.shared.closeAfterUploading {
                manager.closeCard(id: card.id)
            }
        }
    }

    private func quickLookAction() {
        NSWorkspace.shared.open(URL(fileURLWithPath: card.historyItem.filePath))
    }

    private func showInFinderAction() {
        let saved = CaptureEngine.shared.saveCapture(result: card.result, askDestination: false)
        let target = saved ?? URL(fileURLWithPath: card.historyItem.filePath)
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    private func openWithAction() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let appURL = panel.url {
            NSWorkspace.shared.open([URL(fileURLWithPath: card.historyItem.filePath)], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func openInMailAction() {
        let service = NSSharingService(named: .composeEmail)
        service?.perform(withItems: [URL(fileURLWithPath: card.historyItem.filePath)])
    }
}

private struct DraggableThumbnailView: NSViewRepresentable {
    let image: NSImage
    let fileURL: URL
    let onDragCompleted: () -> Void

    func makeNSView(context: Context) -> DraggableNSImageView {
        let v = DraggableNSImageView()
        v.image = image
        v.imageScaling = .scaleProportionallyUpOrDown
        v.fileURL = fileURL
        v.onDragCompleted = onDragCompleted
        return v
    }

    func updateNSView(_ nsView: DraggableNSImageView, context: Context) {
        nsView.image = image
        nsView.fileURL = fileURL
        nsView.onDragCompleted = onDragCompleted
    }
}

public final class DraggableNSImageView: NSImageView, NSDraggingSource {
    public var fileURL: URL?
    public var onDragCompleted: (() -> Void)?

    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    public func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation != [] {
            onDragCompleted?()
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let image else { return }
        var items: [NSDraggingItem] = []
        if let fileURL {
            let dragItem = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
            dragItem.setDraggingFrame(bounds, contents: image)
            items.append(dragItem)
        } else {
            let dragItem = NSDraggingItem(pasteboardWriter: image)
            dragItem.setDraggingFrame(bounds, contents: image)
            items.append(dragItem)
        }
        beginDraggingSession(with: items, event: event, source: self)
    }
}
