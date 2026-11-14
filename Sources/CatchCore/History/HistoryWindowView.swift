import Foundation
import AppKit
import SwiftUI

public final class HistoryWindowController {
    public static let shared = HistoryWindowController()
    private var window: NSWindow?

    public func show() {
        DispatchQueue.main.async {
            if let window = self.window {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            let win = NSWindow(
                contentRect: CGRect(x: 200, y: 180, width: 780, height: 520),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            win.title = "Capture History"
            win.isReleasedWhenClosed = false
            win.contentView = NSHostingView(rootView: HistoryWindowView())
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            self.window = win
        }
    }
}

public struct HistoryWindowView: View {
    @ObservedObject private var store = HistoryStore.shared
    @State private var selectedTab: HistoryFilterTab = .all
    @State private var searchQuery: String = ""

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $selectedTab) {
                    ForEach(HistoryFilterTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)

                Spacer()

                TextField("Search captures...", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            .padding(12)

            Divider()

            let items = store.filteredItems(tab: selectedTab, query: searchQuery)
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No captures in history")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14)], spacing: 14) {
                        ForEach(items) { item in
                            HistoryCardCell(item: item)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .onAppear {
            store.reload()
        }
    }
}

private struct HistoryCardCell: View {
    let item: CaptureHistoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let nsImg = NSImage(contentsOfFile: item.filePath) {
                Image(nsImage: nsImg)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 120)
                    .frame(maxWidth: .infinity)
                    .background(Color.black.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 120)
            }

            Text(item.title)
                .font(.caption.bold())
                .lineLimit(1)

            HStack {
                Text("\(item.width)×\(item.height)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if item.mediaType == .video {
                    Button("Review") { TakeReviewWindowController.shared.show(url: URL(fileURLWithPath: item.filePath)) }
                        .controlSize(.mini)
                } else {
                Button("Restore") {
                    QuickAccessOverlayManager.shared.restore(historyItem: item)
                }
                .controlSize(.mini)
                Button("Annotate") {
                    if let proj = item.projectPath {
                        AnnotateWindowController.openFile(url: URL(fileURLWithPath: proj))
                    } else {
                        AnnotateWindowController.openFile(url: URL(fileURLWithPath: item.filePath))
                    }
                }
                .controlSize(.mini)
                }
                Button(role: .destructive) {
                    HistoryStore.shared.deleteItem(id: item.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
    }
}
