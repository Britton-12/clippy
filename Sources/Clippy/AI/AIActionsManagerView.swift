import SwiftUI

// MARK: - Actions manager (shown inside Settings AI tab)

/// A list of all AI actions (built-in + custom) with full create/edit/delete
/// support. Built-ins are editable but non-deletable and restorable to defaults.
struct AIActionsManagerView: View {
    @ObservedObject private var store = AIActionStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var editingAction: AIAction?
    @State private var isCreating = false
    @State private var deletingAction: AIAction?
    @State private var draggingOverActionID: String?

    private var tokens: ThemeTokens { settings.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            listHeader
            Divider()
            if store.actions.isEmpty {
                emptyState
            } else {
                actionList
            }
        }
        .sheet(isPresented: $isCreating) {
            AIActionEditorView(action: nil) { newAction in
                store.add(newAction)
                isCreating = false
            } onCancel: {
                isCreating = false
            }
        }
        .sheet(item: $editingAction) { action in
            AIActionEditorView(action: action) { updated in
                store.update(updated)
                editingAction = nil
            } onCancel: {
                editingAction = nil
            }
        }
    }

    // MARK: Header

    private var listHeader: some View {
        HStack {
            Text("Actions")
                .font(.headline)
            Spacer()
            Button {
                isCreating = true
            } label: {
                Label("New Action", systemImage: "plus")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Empty state

    private var emptyState: some View {
        ContentUnavailableView("No actions yet.", systemImage: "wand.and.sparkles")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Action list

    private var actionList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(store.actions) { action in
                    actionRow(action)
                        .reorderDraggable(id: action.id.uuidString)
                        .reorderDropDestination(
                            id: action.id.uuidString,
                            draggingOver: $draggingOverActionID
                        ) { draggedStr, targetStr in
                            if let d = UUID(uuidString: draggedStr),
                               let t = UUID(uuidString: targetStr) {
                                store.moveAction(draggedID: d, before: t)
                            }
                        }
                }
            }
            .padding(8)
        }
        .confirmationDialog(
            "Delete \"\(deletingAction?.name ?? "")\"?",
            isPresented: Binding(
                get: { deletingAction != nil },
                set: { if !$0 { deletingAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let action = deletingAction { store.delete(id: action.id) }
                deletingAction = nil
            }
            Button("Cancel", role: .cancel) { deletingAction = nil }
        } message: {
            Text("This action cannot be recovered.")
        }
    }

    private func actionRow(_ action: AIAction) -> some View {
        HStack(spacing: 10) {
            ActionIconView(kind: action.iconKind, value: action.symbolName)
                .frame(width: 20)
                .foregroundStyle(tokens.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(action.name)
                        .font(.body)
                        .foregroundStyle(tokens.textPrimary)
                    if action.isBuiltIn {
                        Text("Built-in")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(tokens.textSecondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(tokens.cardBorder.opacity(0.5),
                                        in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text(action.outputDisposition.label)
                    .font(.caption)
                    .foregroundStyle(tokens.textSecondary)
            }
            Spacer()
            Button("Edit") { editingAction = action }
                .buttonStyle(.borderless)
                .controlSize(.small)
            if !action.isBuiltIn {
                Button("Delete", role: .destructive) { deletingAction = action }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.red)
            } else {
                Button("Restore") {
                    if let original = AIAction.builtIns.first(where: { $0.id == action.id }) {
                        store.update(original)
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(tokens.textSecondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(tokens.cardSurface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(tokens.cardBorder, lineWidth: 1)
        )
        .help(dispositionHelp(for: action.outputDisposition))
    }

    private func dispositionHelp(for disposition: AIActionOutputDisposition) -> String {
        switch disposition {
        case .proposeEdit:
            return "Propose Edit: shows a before/after diff and asks you to confirm before overwriting."
        case .newClip:
            return "New Clip: inserts the result as a new clip in your history."
        case .copyToClipboard:
            return "Copy to Clipboard: copies the result directly to the clipboard."
        }
    }
}

// MARK: - Action editor sheet

/// Create or edit an AIAction. Shows all fields with inline placeholder help.
struct AIActionEditorView: View {
    // Input: nil = create, non-nil = edit.
    let initial: AIAction?
    let onSave: (AIAction) -> Void
    let onCancel: () -> Void

    // Local form state
    @State private var name: String
    @State private var iconKind: CategoryIconKind
    @State private var symbolName: String
    @State private var promptTemplate: String
    @State private var temperature: Double
    @State private var maxTokens: Int
    @State private var outputDisposition: AIActionOutputDisposition

    init(
        action: AIAction?,
        onSave: @escaping (AIAction) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.initial = action
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: action?.name ?? "")
        _iconKind = State(initialValue: action?.iconKind ?? .symbol)
        _symbolName = State(initialValue: action?.symbolName ?? "wand.and.sparkles")
        _promptTemplate = State(initialValue: action?.promptTemplate ?? "")
        _temperature = State(initialValue: action?.temperature ?? 0.4)
        _maxTokens = State(initialValue: action?.maxTokens ?? 512)
        _outputDisposition = State(initialValue: action?.outputDisposition ?? .proposeEdit)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !promptTemplate.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title bar
            HStack {
                Text(initial == nil ? "New Action" : "Edit Action")
                    .font(.headline)
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)
            Divider()
            Form {
                Section("Name and Icon") {
                    TextField("Action name", text: $name)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            ActionIconView(kind: iconKind, value: symbolName)
                                .foregroundStyle(.secondary)
                            Text("Icon")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        IconPickerView(iconKind: $iconKind, iconValue: $symbolName)
                    }
                }

                Section {
                    TextEditor(text: $promptTemplate)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 100, maxHeight: 200)
                } header: {
                    Text("Prompt Template")
                } footer: {
                    Text("{clip} is replaced with the clip text. {instruction} is replaced with any extra instruction you provide at run time. Both are optional.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Output") {
                    Picker("Disposition", selection: $outputDisposition) {
                        ForEach(AIActionOutputDisposition.allCases) { d in
                            Text(d.label).tag(d)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(dispositionHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Model Parameters") {
                    LabeledContent {
                        Slider(value: $temperature, in: 0.0...1.0, step: 0.1)
                    } label: {
                        Text("Temperature: \(temperature, format: .number.precision(.fractionLength(1)))")
                    }
                    Text("Lower = more deterministic. Higher = more creative.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Stepper("Max tokens: \(maxTokens)",
                            value: $maxTokens, in: 16...4096, step: 64)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 520, height: 560)
    }

    private var dispositionHelp: String {
        switch outputDisposition {
        case .proposeEdit:
            return "Shows a before/after diff and asks you to confirm before overwriting the clip."
        case .newClip:
            return "Inserts the result as a new clip in your history."
        case .copyToClipboard:
            return "Copies the result directly to the clipboard without modifying any clip."
        }
    }

    private func save() {
        // Ensure a fallback symbol value so `.symbol` kind never renders a blank icon.
        let resolvedValue: String
        if iconKind == .symbol && symbolName.trimmingCharacters(in: .whitespaces).isEmpty {
            resolvedValue = "wand.and.sparkles"
        } else {
            resolvedValue = symbolName
        }
        let action = AIAction(
            id: initial?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            iconKind: iconKind,
            symbolName: resolvedValue,
            promptTemplate: promptTemplate,
            temperature: temperature,
            maxTokens: maxTokens,
            outputDisposition: outputDisposition,
            isBuiltIn: initial?.isBuiltIn ?? false
        )
        onSave(action)
    }
}

// MARK: - Disposition label helper

private extension AIActionOutputDisposition {
    var label: String {
        switch self {
        case .proposeEdit:      return "Propose Edit"
        case .newClip:          return "New Clip"
        case .copyToClipboard:  return "Copy to Clipboard"
        }
    }
}
