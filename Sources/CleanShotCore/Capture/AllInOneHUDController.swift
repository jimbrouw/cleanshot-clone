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
            let width: CGFloat = 680
            let height: CGFloat = 92
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
            hudButton("Area", systemImage: "viewfinder") {
                onDismiss()
                CaptureEngine.shared.captureArea()
            }
            hudButton("Fullscreen", systemImage: "macwindow.on.rectangle") {
                onDismiss()
                CaptureEngine.shared.captureFullscreen()
            }
            hudButton("Window", systemImage: "macwindow") {
                onDismiss()
                CaptureEngine.shared.captureWindow()
            }
            hudButton("Scrolling", systemImage: "arrow.up.and.down.text.horizontal") {
                onDismiss()
                ScrollingCaptureController.shared.beginScrollingCapture()
            }
            hudButton("Timer", systemImage: "timer") {
                onDismiss()
                CaptureEngine.shared.captureWithSelfTimer()
            }
            hudButton("OCR", systemImage: "text.viewfinder") {
                onDismiss()
                OCRService.shared.captureTextFromScreen()
            }

            Divider().frame(height: 40)

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
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 1)
        )
    }

    private func hudButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .medium))
                Text(title)
                    .font(.caption)
            }
            .frame(width: 64, height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
