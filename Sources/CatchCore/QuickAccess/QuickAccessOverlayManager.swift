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
        let panelSize = CGSize(width: 296 * scale, height: 238 * scale)

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
        panel.minSize = panelSize
        panel.maxSize = panelSize

        let view = QuickAccessCardView(card: card, cardSize: panelSize, manager: self)
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: panelSize)
        panel.contentView = hosting
        panel.setContentSize(panelSize)
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

    public func pauseAutoClose(for id: UUID) {
        autoCloseTimers[id]?.invalidate()
        autoCloseTimers.removeValue(forKey: id)
    }

    public func resumeAutoClose(for card: QuickAccessCardModel) {
        scheduleAutoClose(for: card)
    }

    private func scheduleAutoClose(for card: QuickAccessCardModel) {
        let settings = SettingsStore.shared
        guard settings.autoCloseEnabled else { return }
        autoCloseTimers[card.id]?.invalidate()
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
    let cardSize: CGSize
    let manager: QuickAccessOverlayManager

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var uploadStatus: String?
    @State private var countdownProgress: CGFloat = 1.0

    private var autoCopiedOnCapture: Bool {
        SettingsStore.shared.afterCaptureActions.contains(.copyToClipboard)
    }

    private var autoCloseEnabled: Bool {
        SettingsStore.shared.autoCloseEnabled
    }

    var body: some View {
        let nsImage = NSImage(cgImage: card.result.image, size: NSSize(width: card.result.image.width, height: card.result.image.height))
        VStack(spacing: 8) {
            // Fixed-aspect thumbnail preview with overlay controls
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.45))

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
                .padding(4)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .onTapGesture(count: 2) {
                    annotateAction()
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: max(96, cardSize.height - 96))
            .overlay(alignment: .topLeading) {
                Text(isHovering ? "Drag to share · Double-click to Edit" : (autoCopiedOnCapture ? "Copied to Clipboard" : "Screenshot Ready"))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.6))
                    .padding(7)
            }
            .overlay(alignment: .topTrailing) {
                RaycastGlassContainer(spacing: 6) {
                    HStack(spacing: 5) {
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
                                Button("Discard") { manager.closeCard(id: card.id) }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 22, height: 22)
                                    .background(Circle().fill(Color.black.opacity(0.55)))
                                    .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.6))
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .frame(width: 22, height: 22)
                            .transition(.scale.combined(with: .opacity))
                        }

                        Button {
                            manager.closeCard(id: card.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Color.black.opacity(0.55)))
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.6))
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss")
                    }
                }
                .padding(7)
            }

            // Unified Liquid Glass action dock
            RaycastGlassContainer(spacing: 5) {
                HStack(spacing: 5) {
                    actionBtn(systemImage: "doc.on.doc", label: "Copy", help: "Copy to Clipboard", action: copyAction)
                    actionBtn(systemImage: "square.and.arrow.down", label: "Save", help: "Save to Disk", action: saveAction)
                    actionBtn(systemImage: "pencil.tip.crop.circle", label: "Edit", help: "Open Annotate Studio", action: annotateAction)
                    actionBtn(systemImage: "pin", label: "Pin", help: "Pin Floating Window", action: pinAction)
                    actionBtn(systemImage: "icloud.and.arrow.up", label: "Cloud", help: "Upload & Copy Link", action: uploadAction)
                    actionBtn(systemImage: "trash", label: "Drop", help: "Discard Card", isDestructive: true) {
                        manager.closeCard(id: card.id)
                    }
                }
            }

            // Metadata + live auto-close progress bar
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Text(card.result.format.rawValue.uppercased())
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(RaycastTheme.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(RaycastTheme.accent.opacity(0.16)))

                    Text("\(card.result.image.width) × \(card.result.image.height)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(RaycastTheme.textSecondary)

                    Spacer()
                    if let uploadStatus {
                        Text(uploadStatus)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(RaycastTheme.accent)
                    } else if isHovering && autoCloseEnabled {
                        Text("Paused")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(RaycastTheme.textSecondary)
                    } else {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(card.result.encodedData.count), countStyle: .file))
                            .font(.system(size: 10))
                            .foregroundStyle(RaycastTheme.textTertiary)
                    }
                }

                if autoCloseEnabled {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.08))
                            Capsule()
                                .fill(isHovering ? Color.white.opacity(0.35) : RaycastTheme.accent.opacity(0.85))
                                .frame(width: geo.size.width * countdownProgress)
                        }
                    }
                    .frame(height: 2.5)
                }
            }
        }
        .padding(10)
        .frame(width: cardSize.width, height: cardSize.height)
        .raycastLiquidGlass(cornerRadius: 16, tintAlpha: 0.84)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isHovering
                        ? AnyShapeStyle(LinearGradient(
                            colors: [RaycastTheme.accent.opacity(0.60), Color.white.opacity(0.22)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        : AnyShapeStyle(RaycastTheme.specularGradient),
                    lineWidth: 1
                )
        )
        .scaleEffect(reduceMotion ? 1.0 : (isHovering ? 1.015 : 1.0))
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: isHovering)
        .onAppear {
            startProgressAnimation()
        }
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                manager.pauseAutoClose(for: card.id)
                countdownProgress = 1.0
            } else {
                manager.resumeAutoClose(for: card)
                startProgressAnimation()
            }
        }
    }

    private func startProgressAnimation() {
        guard autoCloseEnabled else { return }
        countdownProgress = 1.0
        let duration = TimeInterval(max(3, SettingsStore.shared.autoCloseIntervalSeconds))
        withAnimation(.linear(duration: duration)) {
            countdownProgress = 0.0
        }
    }

    private func actionBtn(
        systemImage: String,
        label: String,
        help: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        QuickAccessActionButton(
            systemImage: systemImage,
            label: label,
            help: help,
            isDestructive: isDestructive,
            action: action
        )
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
        v.imageAlignment = .alignCenter
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
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

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

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

private struct QuickAccessActionButton: View {
    let systemImage: String
    let label: String
    let help: String
    var isDestructive: Bool = false
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            buttonSurface
                .scaleEffect(reduceMotion ? 1.0 : (isHovered ? 1.05 : 1.0))
                .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: isHovered)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(help)
    }

    @ViewBuilder
    private var buttonSurface: some View {
        let content = VStack(spacing: 2) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .symbolEffect(.bounce, options: .speed(1.3), value: isHovered)
            Text(label)
                .font(.system(size: 8.5, weight: .medium))
        }
        .foregroundStyle(
            isDestructive && isHovered
                ? Color.red
                : (isHovered ? RaycastTheme.textPrimary : RaycastTheme.textSecondary)
        )
        .frame(maxWidth: .infinity, minHeight: 32)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? (isDestructive ? Color.red.opacity(0.18) : RaycastTheme.rowSelection) : Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isHovered
                                ? (isDestructive ? Color.red.opacity(0.45) : Color.white.opacity(0.28))
                                : Color.white.opacity(0.09),
                            lineWidth: 0.75
                        )
                )
        )

        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 8))
        } else {
            content
        }
    }
}
