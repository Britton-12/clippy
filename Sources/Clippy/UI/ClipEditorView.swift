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
    @ObservedObject private var actionStore = AIActionStore.shared
    @StateObject private var ai = AIActionRunner()
    @State private var text: String
    @State private var title: String
    @State private var statusMessage: String?
    /// The action awaiting an instruction (for {instruction} templates).
    @State private var instructionAction: AIAction?
    /// The instruction the user types into the prompt.
    @State private var instructionText: String = ""

    private var tokens: ThemeTokens { settings.theme }

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
                // Editor content honors the user's panel typography and text color
                // so it reads the same as the card the editor opened from.
                .font(PanelTypography.body(settings))
                .foregroundStyle(tokens.textPrimary)
            Divider()
            HStack {
                Text(statsSummary)
                    .font(PanelTypography.metadata(settings))
                    .foregroundStyle(tokens.textSecondary)
                    .accessibilityLabel("\(text.unicodeScalars.count) Unicode scalars, \(wordCount) words, \(lineCount) lines")
                if let statusMessage {
                    Text(statusMessage)
                        .font(PanelTypography.metadata(settings))
                        .foregroundStyle(tokens.accent)
                        .transition(.opacity)
                }
                Spacer()
                Button("Cancel", role: .cancel) { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 480, minHeight: 360)
        .background(tokens.cardSurface)
        .sheet(isPresented: aiSheetBinding) {
            AIActionSheet(runner: ai) { proposal in apply(proposal) }
        }
        // Instruction prompt for AI actions whose template needs {instruction}.
        .alert(instructionAction?.name ?? "AI Action",
               isPresented: Binding(
                get: { instructionAction != nil },
                set: { if !$0 { instructionAction = nil } }
               )) {
            TextField("Instruction", text: $instructionText)
            Button("Run") {
                let trimmed = instructionText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let action = instructionAction, !trimmed.isEmpty {
                    runActionNow(action, instruction: trimmed)
                }
                instructionAction = nil
            }
            Button("Cancel", role: .cancel) { instructionAction = nil }
        } message: {
            Text(instructionPromptMessage)
        }
    }

    private var aiMenu: some View {
        Menu {
            // Custom actions from the store - same execution path as ClipListView.
            ForEach(actionStore.actions) { action in
                Button {
                    runAction(action)
                } label: {
                    HStack {
                        ActionIconView(kind: action.iconKind, value: action.symbolName)
                        Text(action.name)
                    }
                }
            }
            if actionStore.actions.isEmpty {
                Text("No actions configured.")
            }
        } label: {
            Label("AI", systemImage: "sparkles")
        }
        // Native bordered pull-down so the menu reads as a control in a titled
        // editor rather than a borderless web-style affordance.
        .menuStyle(.button)
        .fixedSize()
    }

    /// Run a store action against the current editor text, mirroring
    /// ClipListView.runAIAction. Suggest Category routes through suggestCategory
    /// (so it files the clip), and {instruction} templates prompt first.
    private func runAction(_ action: AIAction) {
        if action.isSuggestCategory {
            let clipText = text
            let categoryNames = store.categories.map(\.name)
            ai.run { service in
                try await service.suggestCategory(forText: clipText, categories: categoryNames)
            }
            return
        }
        if action.needsInstruction {
            instructionAction = action
            instructionText = ""
            return
        }
        runActionNow(action, instruction: "")
    }

    /// Execute the action immediately against the current editor text.
    private func runActionNow(_ action: AIAction, instruction: String) {
        let clipText = text
        ai.run { service in
            try await service.run(action: action, on: clipText, instruction: instruction)
        }
    }

    /// Tailored prompt copy per built-in, mirroring ClipListView.
    private var instructionPromptMessage: String {
        switch instructionAction?.name {
        case "Translate":     return "Which language should this be translated to?"
        case "Change Tone":   return "What tone? (e.g. formal, friendly, concise)"
        case "Rewrite":       return "How should this be rewritten?"
        case "Generate Clip": return "What should the new clip contain?"
        default:              return "Enter an instruction for this action."
        }
    }

    private func apply(_ proposal: AIProposal) {
        switch proposal.kind {
        case .title:
            // Preview: store in @State so it writes on Save.
            title = proposal.proposed
        case .rewrite, .summary:
            // Preview: store in @State so it writes on Save.
            text = proposal.proposed
        case .newClip:
            // Side effect applied immediately: insert as a fresh history entry.
            // Does NOT overwrite the clip currently open in the editor.
            store.saveScriptOutput(proposal.proposed)
            showStatus("New clip created")
        case .copyToClipboard:
            // Side effect applied immediately: write result to the general pasteboard.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(proposal.proposed, forType: .string)
            showStatus("Copied to clipboard")
        case .category:
            // Resolve the proposed name to a Category and assign the clip immediately.
            // No Save required — addClip(id:toCategory:) is a direct store mutation.
            assignClipToCategory(named: proposal.proposed)
        }
    }

    /// Assigns the open clip to a category whose name matches `name`
    /// (case-insensitive, trimmed). Creates a new category with default
    /// appearance if no match exists, mirroring CategoryEditorView's defaults.
    /// Takes effect immediately via store.addClip(id:toCategory:).
    private func assignClipToCategory(named name: String) {
        guard let clipID = clip.id else {
            showStatus("Could not assign: clip has no ID")
            return
        }
        let target = name.trimmingCharacters(in: .whitespaces)
        // Find an existing category by name (case-insensitive).
        if let existing = store.categories.first(where: {
            $0.name.compare(target, options: .caseInsensitive) == .orderedSame
        }), let catID = existing.id {
            store.addClip(id: clipID, toCategory: catID)
            showStatus("Filed under \"\(existing.name)\"")
        } else {
            // No matching category — create one with CategoryEditorView defaults,
            // then immediately assign so the user sees the result without extra steps.
            let created = store.createCategory(
                named: target,
                colorHex: CategoryPalette.hexes[0],
                iconKind: .symbol,
                iconValue: "pin.fill"
            )
            if let catID = created?.id {
                store.addClip(id: clipID, toCategory: catID)
                showStatus("Created \"\(target)\" and filed")
            } else {
                showStatus("Could not create category \"\(target)\"")
            }
        }
    }

    private func showStatus(_ message: String) {
        statusMessage = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if statusMessage == message {
                statusMessage = nil
            }
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

    private var statsSummary: String {
        "\(pluralize(text.unicodeScalars.count, "Unicode scalar"))  |  \(pluralize(wordCount, "word"))  |  \(pluralize(lineCount, "line"))"
    }

    /// Counts runs of non-whitespace, so multiple/Unicode whitespace between
    /// words is collapsed rather than producing empty tokens.
    private var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
    private var lineCount: Int {
        text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// "1 line" / "2 lines": appends "s" only when the count is not 1.
    private func pluralize(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}

// MARK: - Image

private struct ImageClipEditor: View {
    let clip: Clip
    let store: ClipStore
    let onClose: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    @State private var working: NSImage?
    @State private var title: String
    @State private var cropping = false
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var saveError: String?
    @State private var canvasSize: CGSize = .zero

    private var tokens: ThemeTokens { settings.theme }

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
        .background(tokens.cardSurface)
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button { transform { ImageEditing.rotated($0, byDegrees: -90) } } label: {
                Image(systemName: "rotate.left")
            }.help("Rotate left").accessibilityLabel("Rotate left")
            Button { transform { ImageEditing.rotated($0, byDegrees: 90) } } label: {
                Image(systemName: "rotate.right")
            }.help("Rotate right").accessibilityLabel("Rotate right")
            Button { transform { ImageEditing.flipped($0, horizontal: true) } } label: {
                Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
            }.help("Flip horizontal").accessibilityLabel("Flip horizontal")
            Button { transform { ImageEditing.flipped($0, horizontal: false) } } label: {
                Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")
            }.help("Flip vertical").accessibilityLabel("Flip vertical")
            Divider().frame(height: 16)
            Toggle(isOn: $cropping) { Label("Crop", systemImage: "crop") }
                .toggleStyle(.button)
            if cropping {
                Button("Apply crop") { applyCrop() }
                    .disabled(selectionRectInImage == nil)
            }
            Spacer()
            if let working {
                Text("\(Int(pixelSize(working).width)) x \(Int(pixelSize(working).height))")
                    .font(PanelTypography.metadata(settings))
                    .foregroundStyle(tokens.textSecondary)
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
                imageLoadError
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .padding(8)
        .background(tokens.scrollBackground)
    }

    /// Error treatment mirroring the panel's empty state (icon + themed message),
    /// shown when the clip's image file cannot be loaded.
    private var imageLoadError: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Could not load the image. The file may have been moved or deleted.")
                .font(PanelTypography.body(settings))
                .foregroundStyle(tokens.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }

    @ViewBuilder
    private func cropOverlay(fitted: CGSize) -> some View {
        if cropping, let rect = selectionRectInView(fitted: fitted) {
            Rectangle()
                .strokeBorder(tokens.accent, lineWidth: 1.5)
                .background(tokens.accent.opacity(0.12))
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
                // System red for the destructive/error state; ThemeTokens has no
                // dedicated danger token, and this matches the panel's accent vocabulary.
                Text(saveError)
                    .font(PanelTypography.metadata(settings))
                    .foregroundStyle(Color(nsColor: .systemRed))
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
