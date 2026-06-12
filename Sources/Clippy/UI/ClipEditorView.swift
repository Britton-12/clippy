import AppKit
import SwiftUI

/// The clip editor. Text clips get a full text editor with a title field, live
/// counts, and (when configured) AI actions. Image clips get rotate / flip /
/// crop tools that save back to the media store. Both share the title + Save /
/// Cancel chrome.
struct ClipEditorView: View {
    let clip: Clip
    let store: ClipStore
    let onClose: () -> Void

    var body: some View {
        if clip.contentKind == .image {
            ImageClipEditor(clip: clip, store: store, onClose: onClose)
        } else {
            TextClipEditor(clip: clip, store: store, onClose: onClose)
        }
    }
}

// MARK: - Text

private struct TextClipEditor: View {
    let clip: Clip
    let store: ClipStore
    let onClose: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var ai = AIActionRunner()
    @State private var text: String
    @State private var title: String

    init(clip: Clip, store: ClipStore, onClose: @escaping () -> Void) {
        self.clip = clip
        self.store = store
        self.onClose = onClose
        _text = State(initialValue: clip.contentText)
        _title = State(initialValue: clip.userTitle ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Title (optional)", text: $title)
                    .textFieldStyle(.roundedBorder)
                if settings.aiEnabled {
                    aiMenu
                }
            }
            .padding(10)
            Divider()
            PlainTextEditor(text: $text)
            Divider()
            HStack {
                Text("\(text.count) characters · \(wordCount) words · \(lineCount) lines")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 480, minHeight: 360)
        .sheet(isPresented: aiSheetBinding) {
            AIActionSheet(runner: ai) { proposal in apply(proposal) }
        }
    }

    private var aiMenu: some View {
        Menu {
            Button("Suggest title") {
                ai.run { try await $0.suggestTitle(forText: text) }
            }
            Menu("Rewrite") {
                Button("Fix spelling & grammar") { rewrite("Fix spelling and grammar, keep the meaning") }
                Button("Make it more formal") { rewrite("Make it more formal and professional") }
                Button("Make it more concise") { rewrite("Make it more concise") }
                Button("Improve clarity") { rewrite("Improve clarity and flow") }
            }
            Button("Summarize") {
                ai.run { try await $0.summarize(text) }
            }
        } label: {
            Label("AI", systemImage: "sparkles")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func rewrite(_ instruction: String) {
        ai.run { try await $0.rewrite(text, instruction: instruction) }
    }

    private func apply(_ proposal: AIProposal) {
        switch proposal.kind {
        case .title: title = proposal.proposed
        case .rewrite, .summary, .newClip: text = proposal.proposed
        case .category: break
        case .copyToClipboard:
            // The ClipListView handler already wrote to NSPasteboard; nothing
            // to do in the editor. The case must be handled to keep the switch
            // exhaustive as Kind grows.
            break
        }
    }

    private var aiSheetBinding: Binding<Bool> {
        Binding(get: { ai.isPresenting }, set: { if !$0 { ai.reset() } })
    }

    private func save() {
        if text != clip.contentText {
            store.updateText(of: clip, to: text)
        }
        store.renameClip(clip, userTitle: title)
        onClose()
    }

    private var wordCount: Int {
        text.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
    }
    private var lineCount: Int {
        text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
    }
}

// MARK: - Image

private struct ImageClipEditor: View {
    let clip: Clip
    let store: ClipStore
    let onClose: () -> Void

    @State private var working: NSImage?
    @State private var title: String
    @State private var cropping = false
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var saveError: String?
    @State private var canvasSize: CGSize = .zero

    init(clip: Clip, store: ClipStore, onClose: @escaping () -> Void) {
        self.clip = clip
        self.store = store
        self.onClose = onClose
        _title = State(initialValue: clip.userTitle ?? "")
        _working = State(initialValue: store.imageURL(for: clip).flatMap { NSImage(contentsOf: $0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Title (optional)", text: $title)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(10)
            Divider()
            toolbar
            Divider()
            canvas
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 460)
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button { transform { ImageEditing.rotated($0, byDegrees: -90) } } label: {
                Image(systemName: "rotate.left")
            }.help("Rotate left")
            Button { transform { ImageEditing.rotated($0, byDegrees: 90) } } label: {
                Image(systemName: "rotate.right")
            }.help("Rotate right")
            Button { transform { ImageEditing.flipped($0, horizontal: true) } } label: {
                Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
            }.help("Flip horizontal")
            Button { transform { ImageEditing.flipped($0, horizontal: false) } } label: {
                Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")
            }.help("Flip vertical")
            Divider().frame(height: 16)
            Toggle(isOn: $cropping) { Label("Crop", systemImage: "crop") }
                .toggleStyle(.button)
            if cropping {
                Button("Apply crop") { applyCrop() }
                    .disabled(selectionRectInImage == nil)
            }
            Spacer()
            if let working {
                Text("\(Int(pixelSize(working).width)) × \(Int(pixelSize(working).height))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
    }

    private var canvas: some View {
        GeometryReader { geo in
            if let working {
                let fitted = fittedSize(image: pixelSize(working), in: geo.size)
                ZStack {
                    Image(nsImage: working)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fitted.width, height: fitted.height)
                        .overlay(cropOverlay(fitted: fitted))
                        .gesture(cropGesture)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .onAppear { canvasSize = geo.size }
                .onChange(of: geo.size) { canvasSize = geo.size }
            } else {
                Text("Could not load the image.")
                    .foregroundStyle(.secondary)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .padding(8)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    @ViewBuilder
    private func cropOverlay(fitted: CGSize) -> some View {
        if cropping, let rect = selectionRectInView(fitted: fitted) {
            Rectangle()
                .strokeBorder(Color.accentColor, lineWidth: 1.5)
                .background(Color.accentColor.opacity(0.12))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
    }

    private var cropGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard cropping, let working else { return }
                let fitted = fittedSize(image: pixelSize(working), in: canvasSize)
                if dragStart == nil { dragStart = clamp(value.startLocation, to: fitted) }
                dragCurrent = clamp(value.location, to: fitted)
            }
    }

    private var footer: some View {
        HStack {
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red)
            }
            Button("Save a copy...") { saveCopy() }
            Spacer()
            Button("Cancel", role: .cancel) { onClose() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(working == nil)
        }
        .padding(12)
    }

    // MARK: - Operations

    private func transform(_ op: (NSImage) -> NSImage?) {
        guard let working, let result = op(working) else { return }
        self.working = result
        resetSelection()
    }

    private func applyCrop() {
        guard let working, let pixelRect = selectionRectInImage,
              let cropped = ImageEditing.cropped(working, to: pixelRect) else { return }
        self.working = cropped
        cropping = false
        resetSelection()
    }

    private func save() {
        guard let working, let data = ImageEditing.pngData(working) else {
            saveError = "Could not encode the image."
            return
        }
        if store.updateImage(of: clip, to: data) {
            store.renameClip(clip, userTitle: title)
            onClose()
        } else {
            saveError = "Could not save the image."
        }
    }

    private func saveCopy() {
        guard let working, let data = ImageEditing.pngData(working) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "clip.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }

    // MARK: - Geometry

    private func pixelSize(_ image: NSImage) -> CGSize {
        if let cg = ImageEditing.cgImage(image) {
            return CGSize(width: cg.width, height: cg.height)
        }
        return image.size
    }

    private func fittedSize(image: CGSize, in container: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return .zero }
        let scale = min(container.width / image.width, container.height / image.height, 1)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    private func clamp(_ point: CGPoint, to size: CGSize) -> CGPoint {
        CGPoint(x: min(max(0, point.x), size.width), y: min(max(0, point.y), size.height))
    }

    /// The selection rectangle in the fitted view's coordinate space.
    private func selectionRectInView(fitted: CGSize) -> CGRect? {
        guard let start = dragStart, let current = dragCurrent else { return nil }
        let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                          width: abs(start.x - current.x), height: abs(start.y - current.y))
        return rect.width > 2 && rect.height > 2 ? rect : nil
    }

    /// The selection mapped to image pixel coordinates (top-left origin). The
    /// drag coordinates live in the fitted-view space, so they are scaled by the
    /// pixel/fitted ratio.
    private var selectionRectInImage: CGRect? {
        guard let working, let start = dragStart, let current = dragCurrent else { return nil }
        let pixels = pixelSize(working)
        let fitted = fittedSize(image: pixels, in: canvasSize)
        guard fitted.width > 0, fitted.height > 0 else { return nil }
        let view = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                          width: abs(start.x - current.x), height: abs(start.y - current.y))
        guard view.width > 2, view.height > 2 else { return nil }
        let sx = pixels.width / fitted.width
        let sy = pixels.height / fitted.height
        return CGRect(x: view.minX * sx, y: view.minY * sy,
                      width: view.width * sx, height: view.height * sy)
    }

    private func resetSelection() {
        dragStart = nil
        dragCurrent = nil
    }
}
