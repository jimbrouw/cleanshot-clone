import AppKit
import Combine
import SwiftUI

/// Non-activating floating companion card displayed when Catch opens macOS System Settings
/// for a TCC permission (Screen Recording or Accessibility). It stays visible above System
/// Settings, detects approval automatically, offers a one-click Relaunch when Screen Recording
/// requires a fresh process, and surfaces a "Reset & Ask Again" recovery action for stale builds.
public final class CatchPermissionGuidePanel {
    public static let shared = CatchPermissionGuidePanel()

    private var panel: NSPanel?
    private var watcher: AnyCancellable?
    private var autoDismissWork: DispatchWorkItem?
    private var staleHintWork: DispatchWorkItem?
    private let pollingID = UUID()

    private init() {}

    public func present(for kind: CatchPermissionKind) {
        guard kind.requiresSystemSettingsToggle else { return }
        DispatchQueue.main.async { [weak self] in
            self?.showOnMain(kind: kind)
        }
    }

    public func dismiss() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.autoDismissWork?.cancel()
            self.autoDismissWork = nil
            self.staleHintWork?.cancel()
            self.staleHintWork = nil
            self.watcher = nil
            self.panel?.orderOut(nil)
            self.panel = nil
            SystemPermissionsManager.shared.setPollingSurface(self.pollingID, visible: false)
        }
    }

    private func showOnMain(kind: CatchPermissionKind) {
        autoDismissWork?.cancel()
        staleHintWork?.cancel()
        watcher = nil
        panel?.orderOut(nil)
        panel = nil

        let state = GuideCardState(kind: kind)
        let cardView = CatchPermissionGuideCardView(
            state: state,
            onOpenSettings: { SystemPermissionsManager.shared.openSettings(for: kind) },
            onResetAndRetry: { SystemPermissionsManager.shared.resetAndRequest(kind, showFloatingGuide: true) },
            onRelaunch: { SystemPermissionsManager.shared.relaunchApplication() },
            onClose: { [weak self] in self?.dismiss() }
        )

        let hosting = NSHostingView(rootView: cardView)
        let size = NSSize(width: 336, height: hosting.fittingSize.height + 8)
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let origin = NSPoint(
            x: visible.maxX - size.width - 20,
            y: visible.maxY - size.height - 20
        )

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        panel.orderFrontRegardless()
        self.panel = panel

        SystemPermissionsManager.shared.setPollingSurface(pollingID, visible: true)

        let staleWork = DispatchWorkItem { [weak state, weak self] in
            guard let state, !state.isGranted else { return }
            state.showStaleRecovery = true
            self?.resizePanelToFit()
        }
        staleHintWork = staleWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 9.0, execute: staleWork)

        let stream: AnyPublisher<Bool, Never> = kind == .accessibility
            ? SystemPermissionsManager.shared.$hasAccessibility.eraseToAnyPublisher()
            : SystemPermissionsManager.shared.$hasScreenRecording.eraseToAnyPublisher()

        watcher = stream
            .removeDuplicates()
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak state] _ in
                guard let self, let state else { return }
                state.isGranted = true
                state.showStaleRecovery = false
                self.staleHintWork?.cancel()
                SystemPermissionsManager.shared.setPollingSurface(self.pollingID, visible: false)
                self.resizePanelToFit()

                if kind == .accessibility {
                    let dismissWork = DispatchWorkItem { [weak self] in self?.dismiss() }
                    self.autoDismissWork = dismissWork
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: dismissWork)
                }
            }
    }

    private func resizePanelToFit() {
        guard let panel, let contentView = panel.contentView else { return }
        contentView.layoutSubtreeIfNeeded()
        let fitted = contentView.fittingSize
        guard fitted.height > 20 else { return }
        let oldTop = panel.frame.maxY
        let newFrame = NSRect(
            x: panel.frame.origin.x,
            y: oldTop - fitted.height,
            width: panel.frame.width,
            height: fitted.height
        )
        panel.setFrame(newFrame, display: true, animate: true)
    }
}

private final class GuideCardState: ObservableObject {
    let kind: CatchPermissionKind
    @Published var isGranted: Bool = false
    @Published var showStaleRecovery: Bool = false

    init(kind: CatchPermissionKind) {
        self.kind = kind
    }
}

private struct CatchPermissionGuideCardView: View {
    @ObservedObject var state: GuideCardState
    let onOpenSettings: () -> Void
    let onResetAndRetry: () -> Void
    let onRelaunch: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: state.kind.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(state.isGranted ? .green : RaycastTheme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Allow \(state.kind.displayName)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(RaycastTheme.textPrimary)
                    Text("Catch Permission Guide")
                        .font(.system(size: 10.5))
                        .foregroundStyle(RaycastTheme.textTertiary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(RaycastTheme.textTertiary)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 6) {
                stepLine(1, "Find Catch in System Settings → \(state.kind.displayName).")
                stepLine(2, "Switch Catch On (click + to add Catch.app if not listed).")
                stepLine(3, state.kind == .screenRecording
                    ? "Return here and relaunch Catch to activate capture."
                    : "Return to Catch — access activates automatically.")
            }

            HStack(spacing: 8) {
                if state.isGranted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("\(state.kind.displayName) Granted")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.green)
                    Spacer()
                    if state.kind == .screenRecording {
                        Button("Relaunch Catch", action: onRelaunch)
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            .controlSize(.small)
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for approval…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(RaycastTheme.textSecondary)
                    Spacer()
                    Button("Open Settings", action: onOpenSettings)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(.top, 2)

            if state.showStaleRecovery && !state.isGranted {
                VStack(alignment: .leading, spacing: 6) {
                    Divider().overlay(RaycastTheme.borderSubtle)
                    Text("Switch already ON? Rebuilt copies of Catch can have a stale macOS entry.")
                        .font(.system(size: 11))
                        .foregroundStyle(RaycastTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Reset Entry & Ask Again", action: onResetAndRetry)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(width: 336, alignment: .leading)
        .raycastLiquidGlass(cornerRadius: 14, tintAlpha: 0.92)
        .preferredColorScheme(.dark)
        .animation(.easeOut(duration: 0.2), value: state.isGranted)
        .animation(.easeOut(duration: 0.2), value: state.showStaleRecovery)
    }

    private func stepLine(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(RaycastTheme.accent))
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(RaycastTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
