import SwiftUI
import AppKit

/// Reveal state machine anchored to `RaycastDesktopApp/MainWindow.swift` (`0x100b84040`).
public enum RaycastPanelState: String, Sendable {
    case idle
    case warming
    case revealing
    case cancelling
    case expanded
}

public final class ClipboardWindowController: NSObject, NSWindowDelegate {
    public static let shared = ClipboardWindowController()
    private var panel: NSPanel?
    public private(set) var previousFrontmostApp: NSRunningApplication?
    public private(set) var panelState: RaycastPanelState = .idle

    private override init() {
        super.init()
    }

    public var windowDiagnostics: [String: Any] {
        guard let panel,
              let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(panel.windowNumber)) as? [[String: Any]],
              let info = list.first else {
            return ["state": panelState.rawValue]
        }
        return [
            "state": panelState.rawValue,
            "layer": info[kCGWindowLayer as String] as? Int ?? 0,
            "alpha": info[kCGWindowAlpha as String] as? Double ?? 0,
            "sharingState": info[kCGWindowSharingState as String] as? Int ?? 0,
            "ownerPID": info[kCGWindowOwnerPID as String] as? Int ?? 0
        ]
    }

    public func show() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let front = NSWorkspace.shared.frontmostApplication,
               front.bundleIdentifier != Bundle.main.bundleIdentifier {
                self.previousFrontmostApp = front
            }

            if let existing = self.panel {
                self.panelState = .revealing
                existing.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                self.panelState = .expanded
                return
            }

            self.panelState = .warming
            let screen = NSScreen.main ?? NSScreen.screens.first
            let width: CGFloat = 820
            let height: CGFloat = 540
            let originX = (screen?.visibleFrame.midX ?? 600) - width / 2
            let originY = (screen?.visibleFrame.midY ?? 450) - height / 2 + 20

            let p = NSPanel(
                contentRect: NSRect(x: originX, y: originY, width: width, height: height),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            p.title = "Catch Clipboard History"
            p.titleVisibility = .visible
            p.titlebarAppearsTransparent = false
            p.level = .normal
            p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            p.appearance = NSAppearance(named: .darkAqua)
            p.backgroundColor = NSColor(srgbRed: 0.075, green: 0.082, blue: 0.102, alpha: 1.0)
            p.isOpaque = true
            p.hasShadow = true
            p.isReleasedWhenClosed = false
            p.minSize = NSSize(width: 720, height: 480)
            p.delegate = self

            let hosting = NSHostingController(rootView: RaycastClipboardHistoryView(
                onClose: { [weak self] in
                    self?.close()
                }
            ))
            p.contentViewController = hosting
            self.panelState = .revealing
            p.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            self.panelState = .expanded
            self.panel = p
        }
    }

    public func toggle() {
        if let existing = panel, existing.isVisible {
            close()
        } else {
            show()
        }
    }

    public func close() {
        panelState = .cancelling
        let current = panel
        panel = nil
        current?.orderOut(nil)
        panelState = .idle
    }

    public func windowWillClose(_ notification: Notification) {
        panel = nil
        panelState = .idle
    }
}

public struct RaycastClipboardHistoryView: View {
    @ObservedObject private var store = ClipboardHistoryStore.shared
    @State private var searchText: String = ""
    @State private var selectedCategory: ClipboardCategory = .all
    @State private var selectedTag: String = ""
    @State private var selectedEntryID: UUID?
    @State private var showActionPanel: Bool = false
    @State private var actionSearchText: String = ""
    @State private var toastMessage: String?

    @State private var isRenaming: Bool = false
    @State private var renameDraft: String = ""
    @State private var isEditingText: Bool = false
    @State private var editDraft: String = ""
    @State private var isAddingTag: Bool = false
    @State private var newTagDraft: String = ""

    public var onClose: () -> Void

    public init(onClose: @escaping () -> Void = {}) {
        self.onClose = onClose
    }

    private var filteredEntries: [ClipboardEntry] {
        store.filteredEntries(
            query: searchText,
            category: selectedCategory,
            tag: selectedTag.isEmpty ? nil : selectedTag
        )
    }

    private var selectedEntry: ClipboardEntry? {
        if let id = selectedEntryID, let match = filteredEntries.first(where: { $0.id == id }) {
            return match
        }
        return filteredEntries.first
    }

    private var sectionOrder: [String] {
        ["Pinned", "Today", "Yesterday", "This Week", "This Month", "Older"]
    }

    private var groupedSections: [(title: String, items: [ClipboardEntry])] {
        let grouped = Dictionary(grouping: filteredEntries) { $0.timeSectionTitle() }
        return sectionOrder.compactMap { title in
            guard let items = grouped[title], !items.isEmpty else { return nil }
            return (title, items)
        }
    }

    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                topNavigationBar
                dividerLine

                if filteredEntries.isEmpty {
                    emptyStateView
                } else {
                    HSplitViewCompat
                }

                bottomBar
            }

            if showActionPanel, let entry = selectedEntry {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.14)) { showActionPanel = false }
                    }
                actionPanelPopover(for: entry)
                    .padding(.trailing, 14)
                    .padding(.bottom, 52)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let toast = toastMessage {
                toastPill(toast)
                    .padding(.bottom, 54)
                    .padding(.leading, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(RaycastTheme.windowBackground)
        .preferredColorScheme(.dark)
        .onAppear {
            store.checkSystemPasteboard()
            if selectedEntryID == nil {
                selectedEntryID = filteredEntries.first?.id
            }
        }
        .sheet(isPresented: $isRenaming) {
            renameSheet
        }
        .sheet(isPresented: $isEditingText) {
            editTextSheet
        }
        .sheet(isPresented: $isAddingTag) {
            addTagSheet
        }
    }

    private var dividerLine: some View {
        Rectangle()
            .fill(RaycastTheme.borderSubtle)
            .frame(height: 1)
    }

    // MARK: - Native Header & Filter Bar

    private var topNavigationBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(RaycastTheme.textTertiary)

                    TextField("Search copied text, screenshots, links, or OCR…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5, weight: .regular))
                        .foregroundStyle(RaycastTheme.textPrimary)

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(RaycastTheme.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(RaycastTheme.panelSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(RaycastTheme.borderSubtle, lineWidth: 1)
                        )
                )

                if !store.allTags.isEmpty {
                    Menu {
                        Button("All Tags") { selectedTag = "" }
                        Divider()
                        ForEach(store.allTags, id: \.self) { tag in
                            Button(tag) { selectedTag = tag }
                        }
                    } label: {
                        Label(selectedTag.isEmpty ? "Tags" : selectedTag, systemImage: "tag")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .controlSize(.small)
                }

                Button("Clear") {
                    store.clearAll(includePinned: false)
                    showToast("Cleared unpinned history")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.entries.isEmpty)
                .help("Clear all unpinned clipboard items")
            }

            // 1-Click Category Filter Pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach([ClipboardCategory.all, .text, .image, .link, .color, .file]) { category in
                        let active = selectedCategory == category
                        Button {
                            selectedCategory = category
                            selectedEntryID = filteredEntries.first?.id
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: category.systemImage)
                                    .font(.system(size: 10.5, weight: .semibold))
                                Text(category == .all ? "All" : category.displayName.replacingOccurrences(of: " Only", with: ""))
                                    .font(.system(size: 11.5, weight: active ? .semibold : .medium))
                            }
                            .foregroundStyle(active ? .white : RaycastTheme.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4.5)
                            .background(
                                Capsule()
                                    .fill(active ? RaycastTheme.accent.opacity(0.85) : Color.white.opacity(0.06))
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(active ? RaycastTheme.accent : RaycastTheme.borderSubtle, lineWidth: 0.75)
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RaycastTheme.panelSurface.opacity(0.65))
    }

    // MARK: - Split Master-Detail Content

    private var HSplitViewCompat: some View {
        HStack(spacing: 0) {
            leftEntryList
                .frame(width: 296)

            Rectangle()
                .fill(RaycastTheme.borderSubtle)
                .frame(width: 1)

            if let entry = selectedEntry {
                rightDetailPane(for: entry)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var leftEntryList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                ForEach(groupedSections, id: \.title) { section in
                    HStack {
                        Text(section.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(RaycastTheme.textTertiary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 3)

                    ForEach(section.items) { entry in
                        entryRow(entry, isSelected: entry.id == selectedEntry?.id)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
        }
    }

    private func entryRow(_ entry: ClipboardEntry, isSelected: Bool) -> some View {
        Button {
            selectedEntryID = entry.id
        } label: {
            HStack(spacing: 10) {
                entryIcon(entry)

                Text(entry.displayTitle)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(RaycastTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                if !entry.tags.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(entry.tags.prefix(3), id: \.self) { tag in
                            Circle()
                                .fill(RaycastTheme.tagColor(for: tag))
                                .frame(width: 6, height: 6)
                        }
                    }
                }

                if entry.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(RaycastTheme.accent)
                }

                if entry.copyCount > 1 {
                    Text("\(entry.copyCount)×")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(RaycastTheme.textTertiary)
                }

                if isSelected {
                    Button("Copy") {
                        store.copyEntryToClipboard(entry)
                        showToast("Copied to clipboard")
                    }
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(RaycastTheme.accent.opacity(0.85)))
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: RaycastTheme.rowCornerRadius, style: .continuous)
                    .fill(isSelected ? RaycastTheme.rowSelection : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                store.copyEntryToClipboard(entry)
                showToast("Copied to clipboard")
            }
        )
        .contextMenu {
            Button("Paste to Active App") { store.pasteEntryToActiveApp(entry) }
            Button("Copy to Clipboard") {
                store.copyEntryToClipboard(entry)
                showToast("Copied to clipboard")
            }
            Divider()
            Button(entry.isPinned ? "Unpin Entry" : "Pin Entry") { store.togglePin(id: entry.id) }
            Button("Open in Catch Annotate") { openInAnnotate(entry) }
            Button("Pin as Floating Screenshot") { pinAsFloating(entry) }
            Divider()
            Button("Delete Entry", role: .destructive) { store.deleteEntry(id: entry.id) }
        }
    }

    @ViewBuilder
    private func entryIcon(_ entry: ClipboardEntry) -> some View {
        if let hex = entry.colorHex, let comps = ClipboardSmartDetector.parseColor(hex) {
            RoundedRectangle(cornerRadius: RaycastTheme.iconCornerRadius, style: .continuous)
                .fill(Color(red: comps.red, green: comps.green, blue: comps.blue))
                .frame(width: 22, height: 22)
                .overlay(
                    RoundedRectangle(cornerRadius: RaycastTheme.iconCornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                )
        } else if let png = entry.imagePNGData, let img = NSImage(data: png) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: RaycastTheme.iconCornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: RaycastTheme.iconCornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.75)
                )
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: RaycastTheme.iconCornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 22, height: 22)
                Image(systemName: entry.primaryCategory.systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(entry.primaryCategory == .link ? Color.cyan : RaycastTheme.textSecondary)
            }
        }
    }

    // MARK: - Right Detail Pane

    private func rightDetailPane(for entry: ClipboardEntry) -> some View {
        VStack(spacing: 0) {
            // Prominent Action Header Bar
            HStack(spacing: 8) {
                Button {
                    store.copyEntryToClipboard(entry)
                    showToast("Copied to clipboard")
                } label: {
                    Label("Copy to Clipboard", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .tint(RaycastTheme.accent)
                .controlSize(.small)

                Button {
                    store.pasteEntryToActiveApp(entry)
                } label: {
                    Label("Paste into App", systemImage: "arrow.uturn.left.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button {
                    store.togglePin(id: entry.id)
                    showToast(entry.isPinned ? "Unpinned entry" : "Pinned entry")
                } label: {
                    Image(systemName: entry.isPinned ? "pin.slash" : "pin")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(entry.isPinned ? "Unpin Entry" : "Pin Entry")

                Button(role: .destructive) {
                    store.deleteEntry(id: entry.id)
                    showToast("Deleted entry")
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Delete Entry")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(RaycastTheme.panelSurface.opacity(0.45))

            dividerLine

            // Top Preview Stage
            previewStage(for: entry)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(14)

            dividerLine

            // Bottom Information Metadata Table
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Information")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(RaycastTheme.textTertiary)
                        Spacer()
                        Button("+ Tag") {
                            newTagDraft = ""
                            isAddingTag = true
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(RaycastTheme.accent)
                        .buttonStyle(.plain)
                    }

                    metadataRow("Source", value: entry.sourceAppName)

                    if !entry.tags.isEmpty {
                        HStack(alignment: .center) {
                            Text("Tags")
                                .font(.system(size: 12))
                                .foregroundStyle(RaycastTheme.textSecondary)
                            Spacer()
                            HStack(spacing: 4) {
                                ForEach(entry.tags, id: \.self) { tag in
                                    RaycastTagPill(name: tag) {
                                        store.removeTag(id: entry.id, tag: tag)
                                    }
                                }
                            }
                        }
                    }

                    metadataRow("Type", value: entry.primaryCategory.typeLabel)

                    if entry.imagePNGData != nil {
                        if let w = entry.imageWidth, let h = entry.imageHeight {
                            metadataRow("Dimensions", value: "\(w) × \(h)")
                        }
                        if let bytes = entry.imagePNGData?.count {
                            metadataRow("Size", value: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                        }
                    } else if let path = entry.fileURLPath {
                        metadataRow("Path", value: path)
                        if let size = entry.fileSize {
                            metadataRow("Size", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        }
                    } else if entry.text != nil {
                        metadataRow("Characters", value: "\(entry.characterCount)")
                        metadataRow("Words", value: "\(entry.wordCount)")
                    }

                    if entry.copyCount > 1 {
                        metadataRow("Times copied", value: "\(entry.copyCount)")
                        metadataRow("Last copied", value: Self.dateFormatter.string(from: entry.updatedAt))
                        metadataRow("First copied", value: Self.dateFormatter.string(from: entry.createdAt))
                    } else {
                        metadataRow("Copied", value: Self.dateFormatter.string(from: entry.updatedAt))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .frame(height: 176)
            .background(Color.black.opacity(0.16))
        }
    }

    @ViewBuilder
    private func previewStage(for entry: ClipboardEntry) -> some View {
        if let hex = entry.colorHex, let comps = ClipboardSmartDetector.parseColor(hex) {
            VStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(red: comps.red, green: comps.green, blue: comps.blue))
                    .frame(height: 105)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                    )
                    .overlay(alignment: .bottomLeading) {
                        Text(comps.hex)
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 2)
                            .padding(10)
                    }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(entry.colorFormats, id: \.label) { fmt in
                        Button {
                            store.copyTextToPasteboard(fmt.value)
                            showToast("Copied \(fmt.label): \(fmt.value)")
                        } label: {
                            HStack {
                                Text(fmt.label)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(RaycastTheme.textTertiary)
                                Spacer()
                                Text(fmt.value)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(RaycastTheme.textPrimary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.07)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } else if let png = entry.imagePNGData, let img = NSImage(data: png) {
            VStack(spacing: 10) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 155)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(RaycastTheme.borderSubtle, lineWidth: 1)
                    )

                HStack(spacing: 8) {
                    Button {
                        openInAnnotate(entry)
                    } label: {
                        Label("Annotate", systemImage: "pencil.and.outline")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(RaycastTheme.accent)
                    .controlSize(.small)

                    Button {
                        pinAsFloating(entry)
                    } label: {
                        Label("Pin Window", systemImage: "pin")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        if let text = store.extractOCROnDemand(id: entry.id) {
                            store.copyTextToPasteboard(text)
                            showToast("Copied OCR text (\(text.count) chars)")
                        } else {
                            showToast("No text detected in image")
                        }
                    } label: {
                        Label("Copy OCR", systemImage: "text.viewfinder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    Text(entry.text ?? entry.fileURLPath ?? entry.displayTitle)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(RaycastTheme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(RaycastTheme.panelSurface)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(RaycastTheme.borderSubtle, lineWidth: 1))
                )

                if let pretty = entry.formattedJSON {
                    HStack {
                        Label("Valid JSON detected", systemImage: "curlybraces")
                            .font(.system(size: 11))
                            .foregroundStyle(.cyan)
                        Spacer()
                        Button("Copy Formatted JSON") {
                            store.copyTextToPasteboard(pretty)
                            showToast("Copied formatted JSON")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            }
        }
    }

    private func metadataRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(RaycastTheme.textSecondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(RaycastTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(RaycastTheme.textTertiary)
            Text(searchText.isEmpty ? "Clipboard History is Empty" : "No Matching Entries")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(RaycastTheme.textPrimary)
            Text("Copy any text, code, screenshot, color hex (#FF6363), URL, or file to see it appear here instantly.")
                .font(.system(size: 12))
                .foregroundStyle(RaycastTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bottom Status & Action Bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Text("\(filteredEntries.count) \(filteredEntries.count == 1 ? "item" : "items") • Double-click any item to copy")
                .font(.system(size: 11.5))
                .foregroundStyle(RaycastTheme.textSecondary)

            Spacer()

            if !store.entries.isEmpty {
                Button {
                    if let pasted = store.pasteNextSequential() {
                        showToast("Sequential Paste: \(pasted.displayTitle)")
                    }
                } label: {
                    Label(
                        "Seq Paste \(min(store.sequentialPasteIndex + 1, max(1, store.entries.count)))/\(store.entries.count)",
                        systemImage: "text.insert"
                    )
                    .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Paste next item sequentially (⌃⇧⌘V)")
            }

            if selectedEntry != nil {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        actionSearchText = ""
                        showActionPanel.toggle()
                    }
                } label: {
                    Text("More (⌘K)")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut("k", modifiers: .command)
            }

            Button("Close") {
                onClose()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(RaycastTheme.panelSurface.opacity(0.75))
        .overlay(alignment: .top) {
            dividerLine
        }
    }

    private struct ActionItem: Identifiable {
        let id = UUID()
        let title: String
        let systemImage: String
        let keys: [String]
        let isDestructive: Bool
        let run: () -> Void
    }

    private func buildActions(for entry: ClipboardEntry) -> [ActionItem] {
        var list: [ActionItem] = [
            ActionItem(title: "Paste to Active App", systemImage: "doc.on.clipboard", keys: ["↵"], isDestructive: false) {
                store.pasteEntryToActiveApp(entry)
            },
            ActionItem(title: "Copy to Clipboard", systemImage: "square.on.square", keys: ["⌘", "↵"], isDestructive: false) {
                store.copyEntryToClipboard(entry)
                showToast("Copied to clipboard")
            },
            ActionItem(title: "Paste as Plain Text", systemImage: "text.alignleft", keys: ["⇧", "⌘", "V"], isDestructive: false) {
                store.pasteEntryToActiveApp(entry, asPlainText: true)
            },
            ActionItem(title: "Open in Catch Annotate", systemImage: "pencil.and.outline", keys: ["⌘", "E"], isDestructive: false) {
                openInAnnotate(entry)
            },
            ActionItem(title: "Pin as Floating Screenshot", systemImage: "pin.square", keys: ["⌘", "T"], isDestructive: false) {
                pinAsFloating(entry)
            },
            ActionItem(title: entry.isPinned ? "Unpin Entry" : "Pin Entry", systemImage: entry.isPinned ? "pin.slash" : "pin", keys: ["⇧", "⌘", "P"], isDestructive: false) {
                store.togglePin(id: entry.id)
                showToast(entry.isPinned ? "Unpinned entry" : "Pinned entry")
            }
        ]

        if entry.imagePNGData != nil {
            list.append(ActionItem(title: "Copy Text from Image (OCR)", systemImage: "text.viewfinder", keys: ["⌘", "O"], isDestructive: false) {
                if let ocr = store.extractOCROnDemand(id: entry.id) {
                    store.copyTextToPasteboard(ocr)
                    showToast("Copied OCR text")
                } else {
                    showToast("No text found")
                }
            })
            list.append(ActionItem(title: "Decode QR Code", systemImage: "qrcode.viewfinder", keys: ["⌘", "Q"], isDestructive: false) {
                let payloads = store.decodeQROnDemand(id: entry.id)
                if let first = payloads.first {
                    store.copyTextToPasteboard(first)
                    showToast("Copied QR payload")
                } else {
                    showToast("No QR code found")
                }
            })
        }

        if let pretty = entry.formattedJSON {
            list.append(ActionItem(title: "Copy Formatted JSON", systemImage: "curlybraces", keys: ["⌘", "J"], isDestructive: false) {
                store.copyTextToPasteboard(pretty)
                showToast("Copied formatted JSON")
            })
        }

        if entry.text != nil {
            list.append(ActionItem(title: "Edit Entry Text…", systemImage: "pencil", keys: ["⌘", "I"], isDestructive: false) {
                editDraft = entry.text ?? ""
                isEditingText = true
            })
        }

        list.append(ActionItem(title: "Rename Entry…", systemImage: "tag.square", keys: ["⌘", "R"], isDestructive: false) {
            renameDraft = entry.displayTitle
            isRenaming = true
        })

        list.append(ActionItem(title: "Delete Entry", systemImage: "trash", keys: ["⌫"], isDestructive: true) {
            store.deleteEntry(id: entry.id)
            showToast("Deleted entry")
        })
        list.append(ActionItem(title: "Clear Unpinned History", systemImage: "trash.slash", keys: ["⌃", "⌘", "⌫"], isDestructive: true) {
            store.clearAll(includePinned: false)
            showToast("Cleared unpinned entries")
        })

        let q = actionSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return list }
        return list.filter { $0.title.lowercased().contains(q) }
    }

    private func actionPanelPopover(for entry: ClipboardEntry) -> some View {
        let items = buildActions(for: entry)
        return VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(items) { item in
                        Button {
                            withAnimation(.easeOut(duration: 0.12)) { showActionPanel = false }
                            item.run()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: item.systemImage)
                                    .font(.system(size: 12))
                                    .foregroundStyle(item.isDestructive ? Color.red : RaycastTheme.textSecondary)
                                    .frame(width: 16)
                                Text(item.title)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(item.isDestructive ? Color.red : RaycastTheme.textPrimary)
                                Spacer()
                                RaycastKeycapBadge(item.keys)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 270)

            dividerLine

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(RaycastTheme.textTertiary)
                TextField("Search for actions…", text: $actionSearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(RaycastTheme.textPrimary)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
        }
        .frame(width: 310)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(RaycastTheme.elevatedSurface.opacity(0.98))
                .shadow(color: .black.opacity(0.55), radius: 22, x: 0, y: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(RaycastTheme.borderHighlight, lineWidth: 1)
        )
    }

    // MARK: - Helpers & Sheets

    private func openInAnnotate(_ entry: ClipboardEntry) {
        if let cg = store.makeCGImage(for: entry) {
            AnnotateWindowController.open(image: cg, title: entry.displayTitle)
        }
    }

    private func pinAsFloating(_ entry: ClipboardEntry) {
        if let cg = store.makeCGImage(for: entry) {
            PinnedScreenshotController.shared.pin(image: cg, title: entry.displayTitle)
            showToast("Pinned floating screenshot")
        }
    }

    private func showToast(_ msg: String) {
        withAnimation(.easeOut(duration: 0.16)) { toastMessage = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeIn(duration: 0.2)) {
                if toastMessage == msg { toastMessage = nil }
            }
        }
    }

    private func toastPill(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 12))
            Text(message)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(RaycastTheme.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(RaycastTheme.elevatedSurface)
                .overlay(Capsule().strokeBorder(RaycastTheme.borderHighlight, lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
        )
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Clipboard Entry")
                .font(.headline)
            TextField("Entry title", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { isRenaming = false }
                Button("Save") {
                    if let entry = selectedEntry {
                        store.renameEntry(id: entry.id, customTitle: renameDraft)
                    }
                    isRenaming = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private var editTextSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Clipboard Text")
                .font(.headline)
            TextEditor(text: $editDraft)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 180)
                .border(Color.secondary.opacity(0.3))
            HStack {
                Spacer()
                Button("Cancel") { isEditingText = false }
                Button("Save & Move to Top") {
                    if let entry = selectedEntry {
                        store.updateEntryText(id: entry.id, newText: editDraft)
                    }
                    isEditingText = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var addTagSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Tag")
                .font(.headline)
            TextField("e.g. code, palette, work", text: $newTagDraft)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { isAddingTag = false }
                Button("Add") {
                    if let entry = selectedEntry {
                        store.addTag(id: entry.id, tag: newTagDraft)
                    }
                    isAddingTag = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 300)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
