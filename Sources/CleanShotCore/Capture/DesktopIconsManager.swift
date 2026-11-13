import Foundation
import AppKit

public final class DesktopIconsManager: ObservableObject {
    public static let shared = DesktopIconsManager()

    @Published public private(set) var iconsHidden: Bool = false
    private var overlayWindows: [NSWindow] = []
    private var spaceObserver: NSObjectProtocol?

    public init() {
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.iconsHidden, SettingsStore.shared.updateWallpaperWhenSwitchingSpaces else { return }
            self.refreshOverlays()
        }
    }

    deinit {
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
    }

    public func toggleDesktopIcons() {
        if iconsHidden {
            showDesktopIcons()
        } else {
            hideDesktopIcons()
        }
    }

    public func hideDesktopIcons() {
        DispatchQueue.main.async {
            self.iconsHidden = true
            self.refreshOverlays()
        }
    }

    public func showDesktopIcons() {
        DispatchQueue.main.async {
            self.iconsHidden = false
            for win in self.overlayWindows {
                win.orderOut(nil)
            }
            self.overlayWindows.removeAll()
        }
    }

    public func resolveBackdropImage(for screen: NSScreen) -> CGImage? {
        let settings = SettingsStore.shared
        switch settings.desktopWallpaperMode {
        case .desktopWallpaper:
            if let url = NSWorkspace.shared.desktopImageURL(for: screen),
               let nsImg = NSImage(contentsOf: url),
               let cg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                return cg
            }
            return nil
        case .customImage:
            if !settings.customWallpaperPath.isEmpty,
               let nsImg = NSImage(contentsOfFile: settings.customWallpaperPath),
               let cg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                return cg
            }
            return nil
        case .plainColor:
            let color = CodableColor(hex: settings.customWallpaperColorHex).cgColor
            let w = max(1, Int(screen.frame.width))
            let h = max(1, Int(screen.frame.height))
            if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.setFillColor(color)
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                return ctx.makeImage()
            }
            return nil
        }
    }

    private func refreshOverlays() {
        for win in overlayWindows {
            win.orderOut(nil)
        }
        overlayWindows.removeAll()

        let desktopLevel = Int(CGWindowLevelForKey(.desktopIconWindow)) + 1
        for screen in NSScreen.screens {
            let win = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            win.level = NSWindow.Level(rawValue: desktopLevel)
            win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            win.ignoresMouseEvents = true
            win.isReleasedWhenClosed = false

            let imageView = NSImageView(frame: CGRect(origin: .zero, size: screen.frame.size))
            imageView.imageScaling = .scaleAxesIndependently
            if let cg = resolveBackdropImage(for: screen) {
                imageView.image = NSImage(cgImage: cg, size: screen.frame.size)
            } else {
                imageView.wantsLayer = true
                imageView.layer?.backgroundColor = CodableColor(hex: SettingsStore.shared.customWallpaperColorHex).cgColor
            }
            win.contentView = imageView
            win.orderFrontRegardless()
            overlayWindows.append(win)
        }
    }
}
