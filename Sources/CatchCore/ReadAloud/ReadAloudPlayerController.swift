import SwiftUI
import AppKit

/// Floating smoked-glass mini-player for Catch Read Aloud (Screenshot -> Speech).
@MainActor
public final class ReadAloudPlayerController {
    public static let shared = ReadAloudPlayerController()
    private var panel: NSPanel?

    private init() {}

    public func show() {
        if let existing = panel {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 250),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.titleVisibility = .hidden
        newPanel.titlebarAppearsTransparent = true
        newPanel.isMovableByWindowBackground = true
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.level = .floating
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.isReleasedWhenClosed = false

        let hosting = NSHostingView(rootView: ReadAloudPlayerView(onClose: { [weak self] in
            self?.close()
        }))
        newPanel.contentView = hosting

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let x = visible.midX - 220
            let y = visible.maxY - 300
            newPanel.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            newPanel.center()
        }

        self.panel = newPanel
        newPanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func close() {
        ReadAloudService.shared.stop()
        panel?.orderOut(nil)
    }
}

private struct ReadAloudPlayerView: View {
    @ObservedObject private var service = ReadAloudService.shared
    let onClose: () -> Void

    private let speedOptions: [Double] = [1.0, 1.15, 1.35, 1.6, 2.0]

    var body: some View {
        ZStack {
            VisualEffectGlassView(material: .hudWindow, blendingMode: .behindWindow)
            RaycastTheme.windowBackground.opacity(0.76)

            VStack(alignment: .leading, spacing: 12) {
                headerRow
                transcriptBox
                controlsRow
                footerRow
            }
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: RaycastTheme.windowCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RaycastTheme.windowCornerRadius, style: .continuous)
                .stroke(RaycastTheme.borderHighlight, lineWidth: 1)
        )
        .frame(width: 440, height: 250)
        .preferredColorScheme(.dark)
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(RaycastTheme.accent)
            Text("Catch Read Aloud")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(RaycastTheme.textPrimary)

            Spacer()

            Button("New Area") {
                service.captureAndReadAloud()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RaycastTheme.elevatedSurface)
            .foregroundStyle(RaycastTheme.textPrimary)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(RaycastTheme.textSecondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
        }
    }

    private var transcriptBox: some View {
        ScrollView {
            if let message = service.statusMessage, service.currentText.isEmpty {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(RaycastTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if service.currentText.isEmpty {
                Text("Select any region on screen (⌥⇧⌘R) to extract text and hear it read aloud.")
                    .font(.system(size: 12))
                    .foregroundStyle(RaycastTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(highlightedAttributedText)
                    .font(.system(size: 12.5))
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RaycastTheme.panelSurface.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(RaycastTheme.borderSubtle, lineWidth: 1)
        )
    }

    private var highlightedAttributedText: AttributedString {
        var attr = AttributedString(service.currentText)
        attr.foregroundColor = Color.white.opacity(0.84)

        if let nsRange = service.spokenRange,
           let stringRange = Range(nsRange, in: service.currentText),
           let lower = AttributedString.Index(stringRange.lowerBound, within: attr),
           let upper = AttributedString.Index(stringRange.upperBound, within: attr) {
            attr[lower..<upper].foregroundColor = .white
            attr[lower..<upper].backgroundColor = RaycastTheme.accent.opacity(0.45)
        }
        return attr
    }

    private var controlsRow: some View {
        HStack(spacing: 8) {
            Button(action: { service.togglePlayPause() }) {
                HStack(spacing: 5) {
                    Image(systemName: (service.isSpeaking && !service.isPaused) ? "pause.fill" : "play.fill")
                    Text((service.isSpeaking && !service.isPaused) ? "Pause" : (service.isPaused ? "Resume" : "Play"))
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RaycastTheme.accent)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(service.currentText.isEmpty)

            Button(action: { service.stop() }) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 11))
                    .padding(7)
                    .background(RaycastTheme.elevatedSurface)
                    .foregroundStyle(RaycastTheme.textPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .disabled(!service.isSpeaking && !service.isPaused)

            Spacer()

            HStack(spacing: 4) {
                ForEach(speedOptions, id: \.self) { speed in
                    let isSelected = abs(service.playbackMultiplier - speed) < 0.01
                    Button("\(String(format: "%g", speed))x") {
                        service.setPlaybackMultiplier(speed)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(isSelected ? Color.white.opacity(0.18) : RaycastTheme.elevatedSurface.opacity(0.7))
                    .foregroundStyle(isSelected ? .white : RaycastTheme.textSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private var footerRow: some View {
        HStack(spacing: 8) {
            Picker("Voice", selection: Binding(
                get: { service.selectedVoiceIdentifier },
                set: { service.selectVoice(identifier: $0) }
            )) {
                ForEach(service.availableVoices) { voice in
                    Text("\(voice.name) (\(voice.qualityLabel))")
                        .tag(voice.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 220)

            if !service.hasHighQualityVoiceInstalled {
                Text("Tip: Download Enhanced/Siri voices in System Settings")
                    .font(.system(size: 10))
                    .foregroundStyle(RaycastTheme.textTertiary)
                    .lineLimit(1)
            } else if let msg = service.statusMessage {
                Text(msg)
                    .font(.system(size: 10))
                    .foregroundStyle(RaycastTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("Copy Text") {
                service.copyCurrentText()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(RaycastTheme.textSecondary)
            .disabled(service.currentText.isEmpty)
        }
    }
}

private struct VisualEffectGlassView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
