import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

public final class AnnotateEditorViewModel: ObservableObject {
    @Published public var baseImage: CGImage
    @Published public var state: AnnotationDocumentState
    @Published public var activeTool: AnnotationToolKind = .arrow
    @Published public var activeColor: CodableColor = CodableColor(hex: "#0D44E8")
    @Published public var activeStrokeWidth: Double = 4.0
    @Published public var activeArrowStyle: ArrowStyle = .straight
    @Published public var activeTextStyle: TextAnnotationStyle = .roundedBoxed
    @Published public var activeBlurMode: BlurMode = .secure
    @Published public var showBackgroundPanel: Bool = SettingsStore.shared.rememberBackgroundToolOpened
    @Published public var brandPresets: [BrandPreset] = []
    @Published public var statusMessage: String?

    private var undoStack: [AnnotationDocumentState] = []
    private var redoStack: [AnnotationDocumentState] = []
    private var nextCounterValue: Int = 1

    public let title: String
    public let historyItem: CaptureHistoryItem?

    public init(baseImage: CGImage, title: String, state: AnnotationDocumentState = AnnotationDocumentState(), historyItem: CaptureHistoryItem? = nil) {
        self.baseImage = baseImage
        self.title = title
        self.state = state
        self.historyItem = historyItem
        let maxCounter = state.annotations.filter { $0.kind == .counter }.map(\.counterNumber).max() ?? 0
        self.nextCounterValue = maxCounter + 1
        loadBrandPresets()
    }

    public var renderedComposite: CGImage {
        AnnotationRenderer.renderComposite(baseImage: baseImage, state: state)
    }

    public func pushUndoSnapshot() {
        undoStack.append(state)
        redoStack.removeAll()
    }

    public func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(state)
        state = prev
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        state = next
    }

    public func addAnnotation(_ item: AnnotationItem) {
        pushUndoSnapshot()
        var copy = item
        if copy.kind == .counter {
            copy.counterNumber = nextCounterValue
            nextCounterValue += 1
        }
        state.annotations.append(copy)
    }

    public func addCombinedImage(from url: URL) {
        guard let nsImage = NSImage(contentsOf: url),
              let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let pngData = CatchDocument.pngData(from: cg) else {
            return
        }
        pushUndoSnapshot()
        let layer = CombinedImageLayer(
            pngData: pngData,
            frame: CodableRect(x: 40, y: 40, width: Double(min(cg.width, 400)), height: Double(min(cg.height, 300)))
        )
        state.combinedImages.append(layer)
    }

    public func rotateClockwise() {
        pushUndoSnapshot()
        state.rotationQuarterTurns = (state.rotationQuarterTurns + 1) % 4
    }

    public func flipHorizontal() {
        pushUndoSnapshot()
        state.flipHorizontal.toggle()
    }

    public func flipVertical() {
        pushUndoSnapshot()
        state.flipVertical.toggle()
    }

    public func saveBrandPreset(name: String) {
        let preset = BrandPreset(name: name, config: state.background)
        brandPresets.append(preset)
        if let data = try? JSONEncoder().encode(brandPresets) {
            UserDefaults.standard.set(data, forKey: "com.catchapp.brandPresets")
        }
    }

    private func loadBrandPresets() {
        if let data = UserDefaults.standard.data(forKey: "com.catchapp.brandPresets"),
           let loaded = try? JSONDecoder().decode([BrandPreset].self, from: data) {
            brandPresets = loaded
        }
    }
}

public final class AnnotateWindowController {
    private static var controllers: [UUID: NSWindow] = [:]

    public static func open(image: CGImage, title: String = "Annotate", state: AnnotationDocumentState = AnnotationDocumentState(), historyItem: CaptureHistoryItem? = nil) {
        DispatchQueue.main.async {
            if SettingsStore.shared.showDockIconInAnnotate {
                NSApp.setActivationPolicy(.regular)
            }
            let id = UUID()
            let vm = AnnotateEditorViewModel(baseImage: image, title: title, state: state, historyItem: historyItem)
            let win = NSWindow(
                contentRect: CGRect(x: 160, y: 120, width: 1060, height: 740),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            win.title = title
            win.level = SettingsStore.shared.annotateAlwaysOnTop ? .floating : .normal
            win.isReleasedWhenClosed = false
            win.contentView = NSHostingView(rootView: AnnotateEditorView(viewModel: vm))
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            controllers[id] = win
        }
    }

    public static func openFile(url: URL) {
        if url.pathExtension.lowercased() == "catch",
           let doc = try? CatchDocument.load(from: url) {
            open(image: doc.baseImage, title: url.deletingPathExtension().lastPathComponent, state: doc.manifest.documentState)
            return
        }
        guard let nsImage = NSImage(contentsOf: url),
              let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }
        open(image: cg, title: url.deletingPathExtension().lastPathComponent)
    }

    public static func openFromClipboard() {
        let pb = NSPasteboard.general
        if let nsImage = pb.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
           let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            open(image: cg, title: "Clipboard Capture")
        }
    }
}

public struct AnnotateEditorView: View {
    @ObservedObject var viewModel: AnnotateEditorViewModel
    @State private var showColorPopover = false
    @State private var showTextPrompt = false
    @State private var pendingTextPoint = CGPoint(x: 80, y: 80)
    @State private var pendingTextString = "Callout Text"
    @State private var newPresetName = ""
    @State private var showPresetPrompt = false

    public var body: some View {
        VStack(spacing: 0) {
            toolbarView
            Divider()
            HStack(spacing: 0) {
                canvasArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if viewModel.showBackgroundPanel {
                    Divider()
                    backgroundSidebar
                        .frame(width: 280)
                }
            }
            Divider()
            bottomActionBar
        }
        .sheet(isPresented: $showTextPrompt) {
            VStack(spacing: 12) {
                Text("Add Text Annotation")
                    .font(.headline)
                TextField("Text", text: $pendingTextString)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                Picker("Style", selection: $viewModel.activeTextStyle) {
                    ForEach(TextAnnotationStyle.allCases, id: \.self) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
                .frame(width: 260)
                HStack {
                    Button("Cancel") { showTextPrompt = false }
                    Button("Add") {
                        let item = AnnotationItem(
                            kind: .text,
                            rect: CodableRect(x: pendingTextPoint.x, y: pendingTextPoint.y, width: max(140, Double(pendingTextString.count * 12)), height: 40),
                            color: viewModel.activeColor,
                            text: pendingTextString,
                            textStyle: viewModel.activeTextStyle,
                            drawShadow: SettingsStore.shared.drawShadowOnObjects
                        )
                        viewModel.addAnnotation(item)
                        showTextPrompt = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
        }
    }

    private var toolbarView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                toolButton(.select, icon: "cursorarrow", label: "Select")
                toolButton(.cropResize, icon: "crop", label: "Crop")
                toolButton(.arrow, icon: "arrow.up.right", label: "Arrow")
                toolButton(.rectangle, icon: "rectangle", label: "Rect")
                toolButton(.filledRectangle, icon: "rectangle.fill", label: "Fill")
                toolButton(.ellipse, icon: "circle", label: "Ellipse")
                toolButton(.line, icon: "line.diagonal", label: "Line")
                toolButton(.pencil, icon: "pencil.tip", label: "Pencil")
                toolButton(.highlighter, icon: "highlighter", label: "Highlight")
                toolButton(.text, icon: "textformat", label: "Text")
                toolButton(.counter, icon: "1.circle", label: "Counter")
                toolButton(.spotlight, icon: "light.beacon.max", label: "Spotlight")
                toolButton(.pixelate, icon: "squareshape.split.3x3", label: "Pixelate")
                toolButton(.blur, icon: "aqi.medium", label: "Blur")

                Divider().frame(height: 24)

                Button {
                    showColorPopover.toggle()
                } label: {
                    Circle()
                        .fill(Color(nsColor: viewModel.activeColor.nsColor))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(Color.primary.opacity(0.3)))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showColorPopover) {
                    ColorPickerPopoverView(selectedColor: $viewModel.activeColor)
                }

                if viewModel.activeTool == .arrow {
                    Picker("", selection: $viewModel.activeArrowStyle) {
                        Text("Straight").tag(ArrowStyle.straight)
                        Text("Curved").tag(ArrowStyle.curved)
                        Text("Tapered").tag(ArrowStyle.tapered)
                        Text("Double").tag(ArrowStyle.doubleHeaded)
                    }
                    .frame(width: 100)
                } else if viewModel.activeTool == .blur {
                    Picker("", selection: $viewModel.activeBlurMode) {
                        Text("Secure").tag(BlurMode.secure)
                        Text("Smooth").tag(BlurMode.smooth)
                    }
                    .frame(width: 90)
                } else if viewModel.activeTool == .text {
                    Picker("", selection: $viewModel.activeTextStyle) {
                        ForEach(TextAnnotationStyle.allCases, id: \.self) { s in
                            Text(s.rawValue).tag(s)
                        }
                    }
                    .frame(width: 130)
                }

                Divider().frame(height: 24)

                Button { viewModel.rotateClockwise() } label: { Image(systemName: "rotate.right") }.help("Rotate 90°")
                Button { viewModel.flipHorizontal() } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }.help("Flip Horizontal")
                Button { viewModel.undo() } label: { Image(systemName: "arrow.uturn.backward") }.help("Undo")
                Button { viewModel.redo() } label: { Image(systemName: "arrow.uturn.forward") }.help("Redo")

                Toggle("Background", isOn: $viewModel.showBackgroundPanel)
                    .toggleStyle(.button)

                DragMeExportButton(viewModel: viewModel)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(
            ZStack {
                RaycastTheme.panelSurface.opacity(0.55)
                LinearGradient(
                    colors: [Color.white.opacity(0.06), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(RaycastTheme.borderSubtle)
                .frame(height: 1)
        }
    }

    private func toolButton(_ kind: AnnotationToolKind, icon: String, label: String) -> some View {
        AnnotateToolButtonView(
            icon: icon,
            label: label,
            isSelected: viewModel.activeTool == kind
        ) {
            withAnimation(RaycastTheme.microSpring) {
                viewModel.activeTool = kind
            }
        }
    }

    private var canvasArea: some View {
        AnnotationCanvasRepresentable(viewModel: viewModel) { textPoint in
            pendingTextPoint = textPoint
            showTextPrompt = true
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url {
                        DispatchQueue.main.async {
                            viewModel.addCombinedImage(from: url)
                        }
                    }
                }
            }
            return true
        }
    }

    private var backgroundSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Background Tool")
                    .font(.headline)

                Picker("Mode", selection: $viewModel.state.background.mode) {
                    Text("None").tag(BackgroundMode.none)
                    Text("Gradients").tag(BackgroundMode.gradient)
                    Text("Wallpapers").tag(BackgroundMode.wallpaper)
                    Text("Blurred").tag(BackgroundMode.blurred)
                    Text("Plain color").tag(BackgroundMode.plainColor)
                }
                .pickerStyle(.menu)

                if viewModel.state.background.mode == .gradient || viewModel.state.background.mode == .wallpaper {
                    Text("20 Built-In Backgrounds")
                        .font(.caption.bold())
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                        ForEach(BackgroundToolConfig.builtInBackgrounds) { preset in
                            Button {
                                viewModel.pushUndoSnapshot()
                                viewModel.state.background.selectedBuiltInIndex = preset.id
                            } label: {
                                LinearGradient(
                                    colors: [
                                        Color(nsColor: CodableColor(hex: preset.startHex).nsColor),
                                        Color(nsColor: CodableColor(hex: preset.endHex).nsColor)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                .frame(height: 36)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.primary, lineWidth: viewModel.state.background.selectedBuiltInIndex == preset.id ? 2 : 0)
                                )
                            }
                            .buttonStyle(.plain)
                            .help(preset.name)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Padding: \(Int(viewModel.state.background.padding))px").font(.caption)
                    Slider(value: $viewModel.state.background.padding, in: 0...160)

                    Text("Corner Radius: \(Int(viewModel.state.background.cornerRadius))px").font(.caption)
                    Slider(value: $viewModel.state.background.cornerRadius, in: 0...40)

                    Text("Shadow: \(Int(viewModel.state.background.shadowRadius))px").font(.caption)
                    Slider(value: $viewModel.state.background.shadowRadius, in: 0...60)
                }

                Picker("Aspect Ratio", selection: $viewModel.state.background.aspectRatioPreset) {
                    ForEach(AspectRatioPreset.allCases, id: \.self) { ratio in
                        Text(ratio.rawValue).tag(ratio)
                    }
                }

                Toggle("Auto-balance content", isOn: $viewModel.state.background.autoBalanceEnabled)

                Divider()
                HStack {
                    Text("Brand Presets").font(.caption.bold())
                    Spacer()
                    Button("+ Save") {
                        showPresetPrompt = true
                    }
                    .controlSize(.small)
                }
                ForEach(viewModel.brandPresets) { preset in
                    Button(preset.name) {
                        viewModel.pushUndoSnapshot()
                        viewModel.state.background = preset.config
                    }
                    .controlSize(.small)
                }
            }
            .padding(14)
        }
        .alert("Save Brand Preset", isPresented: $showPresetPrompt) {
            TextField("Preset Name", text: $newPresetName)
            Button("Save") {
                if !newPresetName.isEmpty {
                    viewModel.saveBrandPreset(name: newPresetName)
                    newPresetName = ""
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var bottomActionBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Text("\(viewModel.baseImage.width) × \(viewModel.baseImage.height)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(RaycastTheme.textSecondary)
                Text("·")
                    .foregroundStyle(RaycastTheme.textTertiary)
                Text("\(viewModel.state.annotations.count) layers")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(RaycastTheme.textSecondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.06)))

            if let status = viewModel.statusMessage {
                Text(status)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(RaycastTheme.accent)
            }
            Spacer()
            Button("Save as .catch...") {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "\(viewModel.title).catch"
                if panel.runModal() == .OK, let url = panel.url {
                    let doc = CatchDocument(baseImage: viewModel.baseImage, state: viewModel.state)
                    try? doc.save(to: url)
                    viewModel.statusMessage = "Saved .catch project"
                }
            }
            Button("Pin") {
                PinnedScreenshotController.shared.pin(image: viewModel.renderedComposite, title: viewModel.title)
            }
            Button {
                let cg = viewModel.renderedComposite
                let ns = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([ns])
                viewModel.statusMessage = "Copied to clipboard"
            } label: {
                HStack(spacing: 4) {
                    Text("Copy")
                    RaycastKeycapBadge("⌘C").scaleEffect(0.82)
                }
            }
            Button {
                let cg = viewModel.renderedComposite
                let data = ImagePostProcessor.encode(image: cg, format: SettingsStore.shared.outputFormat) ?? Data()
                let res = CaptureResult(
                    image: cg,
                    encodedData: data,
                    fileName: viewModel.title,
                    format: SettingsStore.shared.outputFormat,
                    sourceRect: CGRect(x: 0, y: 0, width: cg.width, height: cg.height),
                    displayScale: 1.0
                )
                if let url = CaptureEngine.shared.saveCapture(result: res, askDestination: false) {
                    viewModel.statusMessage = "Saved \(url.lastPathComponent)"
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Save")
                    RaycastKeycapBadge("⌘S").scaleEffect(0.82)
                }
            }
            Button("Upload to Cloud") {
                let cg = viewModel.renderedComposite
                let data = ImagePostProcessor.encode(image: cg, format: .png) ?? Data()
                Task { @MainActor in
                    let uploaded = await CloudUploadService.shared.upload(image: cg, data: data, title: viewModel.title)
                    viewModel.statusMessage = uploaded != nil ? "Uploaded & link copied" : "Upload failed"
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(RaycastTheme.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RaycastTheme.panelSurface.opacity(0.65))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(RaycastTheme.borderSubtle)
                .frame(height: 1)
        }
    }
}

private struct AnnotateToolButtonView: View {
    let icon: String
    let label: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                Text(label)
                    .font(.system(size: 9, weight: isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? RaycastTheme.accent : (isHovered ? RaycastTheme.textPrimary : RaycastTheme.textSecondary))
            .frame(width: 48, height: 36)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? RaycastTheme.accent.opacity(0.22) : (isHovered ? Color.white.opacity(0.08) : Color.clear))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(isSelected ? RaycastTheme.accent.opacity(0.55) : Color.clear, lineWidth: 1)
                    )
            )
            .scaleEffect(isHovered ? 1.04 : 1.0)
            .animation(RaycastTheme.microSpring, value: isHovered)
            .animation(RaycastTheme.microSpring, value: isSelected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct DragMeExportButton: NSViewRepresentable {
    let viewModel: AnnotateEditorViewModel

    func makeNSView(context: Context) -> DragMeNSButton {
        let btn = DragMeNSButton(title: "Drag me", target: nil, action: nil)
        btn.bezelStyle = .rounded
        btn.viewModel = viewModel
        return btn
    }

    func updateNSView(_ nsView: DragMeNSButton, context: Context) {
        nsView.viewModel = viewModel
    }
}

private final class DragMeNSButton: NSButton, NSDraggingSource {
    weak var viewModel: AnnotateEditorViewModel?

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    override func mouseDragged(with event: NSEvent) {
        guard let vm = viewModel else { return }
        let cg = vm.renderedComposite
        let data = CatchDocument.pngData(from: cg) ?? Data()
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(vm.title).png")
        try? data.write(to: tempURL)
        let nsImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        let dragItem = NSDraggingItem(pasteboardWriter: tempURL as NSURL)
        dragItem.setDraggingFrame(bounds, contents: nsImage)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }
}

private struct AnnotationCanvasRepresentable: NSViewRepresentable {
    @ObservedObject var viewModel: AnnotateEditorViewModel
    let onRequestTextAt: (CGPoint) -> Void

    func makeNSView(context: Context) -> AnnotationCanvasNSView {
        let view = AnnotationCanvasNSView(viewModel: viewModel, onRequestTextAt: onRequestTextAt)
        return view
    }

    func updateNSView(_ nsView: AnnotationCanvasNSView, context: Context) {
        nsView.viewModel = viewModel
        nsView.needsDisplay = true
    }
}

private final class AnnotationCanvasNSView: NSView {
    var viewModel: AnnotateEditorViewModel
    let onRequestTextAt: (CGPoint) -> Void

    private var dragStart: CGPoint?
    private var currentDragItem: AnnotationItem?
    private var freehandPoints: [CodablePoint] = []

    init(viewModel: AnnotateEditorViewModel, onRequestTextAt: @escaping (CGPoint) -> Void) {
        self.viewModel = viewModel
        self.onRequestTextAt = onRequestTextAt
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func imageScaleAndOrigin(for composite: CGImage) -> (scale: CGFloat, origin: CGPoint, drawRect: CGRect) {
        let iw = CGFloat(composite.width)
        let ih = CGFloat(composite.height)
        let availW = max(1, bounds.width - 32)
        let availH = max(1, bounds.height - 32)
        let scale = min(1.0, min(availW / max(1, iw), availH / max(1, ih)))
        let drawW = iw * scale
        let drawH = ih * scale
        let ox = (bounds.width - drawW) / 2
        let oy = (bounds.height - drawH) / 2
        return (scale, CGPoint(x: ox, y: oy), CGRect(x: ox, y: oy, width: drawW, height: drawH))
    }

    private func toImageCoords(_ viewPoint: CGPoint, composite: CGImage) -> CGPoint {
        let info = imageScaleAndOrigin(for: composite)
        return CGPoint(
            x: (viewPoint.x - info.origin.x) / info.scale,
            y: (viewPoint.y - info.origin.y) / info.scale
        )
    }

    override func mouseDown(with event: NSEvent) {
        let composite = viewModel.renderedComposite
        let pt = toImageCoords(convert(event.locationInWindow, from: nil), composite: composite)
        dragStart = pt

        if viewModel.activeTool == .counter {
            let item = AnnotationItem(
                kind: .counter,
                rect: CodableRect(x: pt.x - 16, y: pt.y - 16, width: 32, height: 32),
                color: viewModel.activeColor,
                drawShadow: SettingsStore.shared.drawShadowOnObjects
            )
            viewModel.addAnnotation(item)
            needsDisplay = true
            return
        }

        if viewModel.activeTool == .text {
            onRequestTextAt(pt)
            return
        }

        if viewModel.activeTool == .pencil || viewModel.activeTool == .highlighter {
            freehandPoints = [CodablePoint(pt)]
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let composite = viewModel.renderedComposite
        let pt = toImageCoords(convert(event.locationInWindow, from: nil), composite: composite)

        if viewModel.activeTool == .pencil || viewModel.activeTool == .highlighter {
            freehandPoints.append(CodablePoint(pt))
            currentDragItem = AnnotationItem(
                kind: viewModel.activeTool,
                points: freehandPoints,
                color: viewModel.activeColor,
                strokeWidth: viewModel.activeStrokeWidth,
                drawShadow: SettingsStore.shared.drawShadowOnObjects
            )
        } else {
            let r = CGRect(
                x: min(start.x, pt.x),
                y: min(start.y, pt.y),
                width: abs(pt.x - start.x),
                height: abs(pt.y - start.y)
            )
            let invert = SettingsStore.shared.inverseArrowDirection != event.modifierFlags.contains(.option)
            currentDragItem = AnnotationItem(
                kind: viewModel.activeTool,
                rect: CodableRect(r),
                startPoint: CodablePoint(start),
                endPoint: CodablePoint(pt),
                controlPoint: viewModel.activeArrowStyle == .curved ? CodablePoint(CGPoint(x: (start.x + pt.x) / 2, y: min(start.y, pt.y) - 40)) : nil,
                color: viewModel.activeColor,
                strokeWidth: viewModel.activeStrokeWidth,
                arrowStyle: viewModel.activeArrowStyle,
                invertArrow: invert,
                blurMode: viewModel.activeBlurMode,
                drawShadow: SettingsStore.shared.drawShadowOnObjects
            )
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let item = currentDragItem {
            if item.kind == .cropResize {
                if item.rect.width >= 10 && item.rect.height >= 10 {
                    viewModel.pushUndoSnapshot()
                    viewModel.state.cropRect = item.rect
                }
            } else {
                viewModel.addAnnotation(item)
            }
        }
        dragStart = nil
        currentDragItem = nil
        freehandPoints = []
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        var previewState = viewModel.state
        if let currentDragItem, currentDragItem.kind != .cropResize {
            previewState.annotations.append(currentDragItem)
        }
        let composite = AnnotationRenderer.renderComposite(baseImage: viewModel.baseImage, state: previewState)
        let info = imageScaleAndOrigin(for: composite)
        let nsImg = NSImage(cgImage: composite, size: NSSize(width: composite.width, height: composite.height))
        nsImg.draw(in: info.drawRect)

        if let currentDragItem, currentDragItem.kind == .cropResize {
            let cropViewRect = CGRect(
                x: info.origin.x + currentDragItem.rect.x * info.scale,
                y: info.origin.y + currentDragItem.rect.y * info.scale,
                width: currentDragItem.rect.width * info.scale,
                height: currentDragItem.rect.height * info.scale
            )
            NSColor.white.setStroke()
            let p = NSBezierPath(rect: cropViewRect)
            p.lineWidth = 2
            p.stroke()
        }
    }
}
