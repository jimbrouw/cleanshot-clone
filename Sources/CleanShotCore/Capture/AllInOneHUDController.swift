import Foundation
import AppKit
import SwiftUI

public final class AllInOneHUDController {
    public static let shared = AllInOneHUDController()

    private var hudPanel: NSPanel?

    public func show(initialRect: CGRect? = nil, displayIndex: Int? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let existing = self.hudPanel {
                existing.orderOut(nil)
                self.hudPanel = nil
            }

            let screen = CaptureEngine.shared.resolveScreen(displayIndex: displayIndex)
            let width: CGFloat = 760
            let height: CGFloat = 96
            let frame = CGRect(
                x: screen.frame.midX - width / 2,
                y: screen.frame.minY + 110,
                width: width,
                height: height
            )

            let panel = NSPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .floating
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true

            let hosting = NSHostingView(rootView: AllInOneHUDView(
                initialRect: initialRect ?? CaptureEngine.shared.lastCapturedRect,
                onDismiss: { [weak self] in
                    self?.dismiss()
                }
            ))
            panel.contentView = hosting
            panel.makeKeyAndOrderFront(nil)
            self.hudPanel = panel
        }
    }

    public func dismiss() {
        hudPanel?.orderOut(nil)
        hudPanel = nil
    }
}

private struct AllInOneHUDView: View {
    @State private var widthInput: String
    @State private var heightInput: String
    @State private var lockAspectRatio: Bool = false
    let onDismiss: () -> Void

    init(initialRect: CGRect?, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        _widthInput = State(initialValue: initialRect.map { "\(Int($0.width))" } ?? "608")
        _heightInput = State(initialValue: initialRect.map { "\(Int($0.height))" } ?? "455")
    }

    var body: some View {
        HStack(spacing: 10) {
            hudButton("Area", systemImage: "viewfinder", shortcut: "⌥4") {
                onDismiss()
                CaptureEngine.shared.captureArea()
            }
            hudButton("Fullscreen", systemImage: "macwindow.on.rectangle", shortcut: "⌥3") {
                onDismiss()
                CaptureEngine.shared.captureFullscreen()
            }
            hudButton("Window", systemImage: "macwindow", shortcut: "⌥W") {
                onDismiss()
                CaptureEngine.shared.captureWindow()
            }
            hudButton("Scrolling", systemImage: "arrow.up.and.down.text.horizontal", shortcut: "⌥S") {
                onDismiss()
                ScrollingCaptureController.shared.beginScrollingCapture()
            }
            hudButton("OCR", systemImage: "text.viewfinder", shortcut: "⌥2") {
                onDismiss()
                OCRService.shared.captureTextFromScreen()
            }
            hudButton("Clipboard", systemImage: "doc.on.clipboard", shortcut: "⌥V") {
                onDismiss()
                ClipboardWindowController.shared.show()
            }

            Divider().overlay(RaycastTheme.borderSubtle).frame(height: 44)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    TextField("W", text: $widthInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 54)
                    Text("×")
                        .foregroundStyle(.secondary)
                    TextField("H", text: $heightInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 54)
                }
                HStack(spacing: 6) {
                    Toggle("Lock", isOn: $lockAspectRatio)
                        .toggleStyle(.checkbox)
                        .font(.caption2)
                    Button("Capture") {
                        let w = Double(widthInput) ?? 608
                        let h = Double(heightInput) ?? 455
                        let screen = CaptureEngine.shared.resolveScreen(displayIndex: nil)
                        let rect = CGRect(
                            x: screen.frame.midX - w / 2,
                            y: screen.frame.midY - h / 2,
                            width: w,
                            height: h
                        )
                        onDismiss()
                        CaptureEngine.shared.captureArea(rect: rect)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }
            }

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: RaycastTheme.windowCornerRadius, style: .continuous)
                .fill(RaycastTheme.windowBackground.opacity(0.95))
        )
        .overlay(
            RoundedRectangle(cornerRadius: RaycastTheme.windowCornerRadius, style: .continuous)
                .stroke(RaycastTheme.borderHighlight, lineWidth: 1)
        )
        .preferredColorScheme(.dark)
    }

    private func hudButton(_ title: String, systemImage: String, shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(RaycastTheme.textPrimary)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(RaycastTheme.textPrimary)
                Text(shortcut)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(RaycastTheme.textTertiary)
            }
            .frame(width: 66, height: 64)
            .background(
                RoundedRectangle(cornerRadius: RaycastTheme.rowCornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
