import Foundation
import AppKit
import SwiftUI

public final class PinnedScreenshotController: ObservableObject {
    public static let shared = PinnedScreenshotController()

    @Published public private(set) var pinnedPanels: [PinnedPanelEntry] = []

    public struct PinnedPanelEntry: Identifiable {
        public let id: UUID
        public let title: String
        public let window: PinnedWindow
        public var isLocked: Bool
    }

    public func pin(image: CGImage, title: String = "Pinned Screenshot") {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let id = UUID()
            let screen = NSScreen.main ?? NSScreen.screens[0]
            let maxW = screen.visibleFrame.width * 0.55
            let maxH = screen.visibleFrame.height * 0.55
            let rawSize = CGSize(width: CGFloat(image.width) / screen.backingScaleFactor, height: CGFloat(image.height) / screen.backingScaleFactor)
            let scale = min(1.0, min(maxW / max(1, rawSize.width), maxH / max(1, rawSize.height)))
            let size = CGSize(width: max(80, rawSize.width * scale), height: max(60, rawSize.height * scale))
            let origin = CGPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2)

            let win = PinnedWindow(
                contentRect: CGRect(origin: origin, size: size),
                image: image,
                title: title,
                onClose: { [weak self] in
                    self?.close(id: id)
                },
                onLockChanged: { [weak self] locked in
                    self?.setLock(id: id, locked: locked)
                }
            )
            win.orderFrontRegardless()
            self.pinnedPanels.append(PinnedPanelEntry(id: id, title: title, window: win, isLocked: false))
        }
    }

    public func pinFromFile(url: URL) {
        guard let nsImage = NSImage(contentsOf: url),
              let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }
        pin(image: cg, title: url.lastPathComponent)
    }

    public func setLock(id: UUID, locked: Bool) {
        if let idx = pinnedPanels.firstIndex(where: { $0.id == id }) {
            pinnedPanels[idx].isLocked = locked
            pinnedPanels[idx].window.ignoresMouseEvents = locked
        }
    }

    public func unlockAll() {
        for idx in pinnedPanels.indices {
            pinnedPanels[idx].isLocked = false
            pinnedPanels[idx].window.ignoresMouseEvents = false
        }
    }

    public func close(id: UUID) {
        if let idx = pinnedPanels.firstIndex(where: { $0.id == id }) {
            pinnedPanels[idx].window.orderOut(nil)
            pinnedPanels.remove(at: idx)
        }
    }
}

public final class PinnedWindow: NSPanel {
    private let aspectRatioValue: CGFloat
    private let onClose: () -> Void
    private let onLockChanged: (Bool) -> Void

    init(
        contentRect: CGRect,
        image: CGImage,
        title: String,
        onClose: @escaping () -> Void,
        onLockChanged: @escaping (Bool) -> Void
    ) {
        self.aspectRatioValue = contentRect.width / max(1, contentRect.height)
        self.onClose = onClose
        self.onLockChanged = onLockChanged

        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.title = title
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isMovableByWindowBackground = true
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = SettingsStore.shared.pinnedShadow
        self.aspectRatio = contentRect.size

        let view = PinnedContentView(
            image: image,
            windowRef: self,
            onClose: onClose,
            onLockToggle: { [weak self] locked in
                self?.ignoresMouseEvents = locked
                self?.onLockChanged(locked)
            }
        )
        self.contentView = NSHostingView(rootView: view)
    }

    public override var canBecomeKey: Bool { true }

    public override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        var origin = frame.origin
        switch event.keyCode {
        case 123: origin.x -= step // Left
        case 124: origin.x += step // Right
        case 125: origin.y -= step // Down
        case 126: origin.y += step // Up
        case 53: onClose(); return // Escape
        default: super.keyDown(with: event); return
        }
        setFrameOrigin(origin)
    }
}

private struct PinnedContentView: View {
    let image: CGImage
    weak var windowRef: PinnedWindow?
    let onClose: () -> Void
    let onLockToggle: (Bool) -> Void

    @State private var opacityValue: Double = 1.0
    @State private var isHovering = false
    @State private var isLocked = false

    var body: some View {
        let settings = SettingsStore.shared
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        ZStack(alignment: .topLeading) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .opacity(opacityValue)
                .clipShape(RoundedRectangle(cornerRadius: settings.pinnedRoundedCorners ? 10 : 0, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: settings.pinnedRoundedCorners ? 10 : 0, style: .continuous)
                        .stroke(Color.primary.opacity(settings.pinnedBorder ? 0.3 : 0.0), lineWidth: 1)
                )

            if isHovering && !isLocked {
                HStack(spacing: 8) {
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)

                    Slider(value: $opacityValue, in: 0.15...1.0)
                        .frame(width: 80)

                    Button {
                        isLocked = true
                        onLockToggle(true)
                    } label: {
                        Image(systemName: "lock.open")
                    }
                    .buttonStyle(.plain)
                    .help("Lock Mode (click-through; unlock via menu bar)")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.ultraThickMaterial, in: Capsule())
                .padding(8)
            }
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
