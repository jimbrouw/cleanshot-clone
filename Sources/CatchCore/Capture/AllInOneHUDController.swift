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
            let width: CGFloat = 860
            let height: CGFloat = 132
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
            panel.invalidateShadow()
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
    @ObservedObject private var settings = SettingsStore.shared
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
        VStack(spacing: 10) {
            // Top Status & Quick Toggles Strip
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(RaycastTheme.accent)
                        .frame(width: 6, height: 6)
                    Text("ALL-IN-ONE CAPTURE")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(RaycastTheme.textSecondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.06)))

                HStack(spacing: 4) {
                    presetPill("16:9", w: "1280", h: "720")
                    presetPill("4:3", w: "1024", h: "768")
                    presetPill("1:1", w: "800", h: "800")
                }

                Spacer()

                quickTogglePill(
                    title: "Cursor",
                    systemImage: "cursorarrow",
                    isOn: $settings.showCursorOnScreenshots
                )
                quickTogglePill(
                    title: "Freeze",
                    systemImage: "snowflake",
                    isOn: $settings.freezeScreenWhenCapturing
                )

                Button {
                    onDismiss()
                } label: {
                    HStack(spacing: 4) {
                        RaycastKeycapBadge("esc")
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(RaycastTheme.textSecondary)
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss HUD (Esc)")
            }

            // Main Action Tiles + Custom Dimensions
            RaycastGlassContainer(spacing: 10) {
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
                    hudButton("Video", systemImage: "video.badge.waveform", shortcut: "⌥L") {
                        onDismiss()
                        ScreenRecordingStudio.shared.presentStudio()
                    }
                    hudButton("OCR", systemImage: "text.viewfinder", shortcut: "⌥2") {
                        onDismiss()
                        OCRService.shared.captureTextFromScreen()
                    }
                    hudButton("Clipboard", systemImage: "doc.on.clipboard", shortcut: "⌥V") {
                        onDismiss()
                        ClipboardWindowController.shared.show()
                    }

                    Divider().overlay(RaycastTheme.borderSubtle).frame(height: 50)

                    VStack(alignment: .leading, spacing: 6) {
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
                            .raycastGlassButton(prominent: true)
                            .tint(RaycastTheme.accent)
                            .controlSize(.mini)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .raycastLiquidGlass(cornerRadius: RaycastTheme.windowCornerRadius)
        .preferredColorScheme(.dark)
        .onExitCommand {
            onDismiss()
        }
    }

    private func presetPill(_ title: String, w: String, h: String) -> some View {
        Button {
            withAnimation(RaycastTheme.microSpring) {
                widthInput = w
                heightInput = h
            }
        } label: {
            Text(title)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(widthInput == w && heightInput == h ? RaycastTheme.accent : RaycastTheme.textSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(
                    Capsule()
                        .fill(widthInput == w && heightInput == h ? RaycastTheme.accent.opacity(0.16) : Color.white.opacity(0.05))
                )
        }
        .buttonStyle(.plain)
    }

    private func quickTogglePill(title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        Button {
            withAnimation(RaycastTheme.microSpring) {
                isOn.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 9.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(isOn.wrappedValue ? RaycastTheme.accent : RaycastTheme.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(isOn.wrappedValue ? RaycastTheme.accent.opacity(0.16) : Color.white.opacity(0.05))
                    .overlay(
                        Capsule()
                            .strokeBorder(isOn.wrappedValue ? RaycastTheme.accent.opacity(0.45) : Color.white.opacity(0.10), lineWidth: 0.75)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func hudButton(_ title: String, systemImage: String, shortcut: String, action: @escaping () -> Void) -> some View {
        RaycastInteractiveTile(cornerRadius: RaycastTheme.rowCornerRadius, action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(RaycastTheme.textPrimary)
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(RaycastTheme.textPrimary)
                RaycastKeycapBadge(shortcut)
                    .scaleEffect(0.84)
            }
            .frame(width: 72, height: 68)
        }
    }
}
