import SwiftUI

// MARK: - Actions manager (shown inside Settings AI tab)

/// A list of all AI actions (built-in + custom) with full create/edit/delete
/// support. Built-ins are editable but non-deletable and restorable to defaults.
struct AIActionsManagerView: View {
    @ObservedObject private var store = AIActionStore.shared
    @State private var editingAction: AIAction?
    @State private var isCreating = false

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
        VStack(spacing: 12) {
            Image(systemName: "wand.and.sparkles")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("No actions yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Action list

    private var actionList: some View {
        List {
            ForEach(store.actions) { action in
                actionRow(action)
            }
        }
        .listStyle(.inset)
    }

    private func actionRow(_ action: AIAction) -> some View {
        HStack(spacing: 10) {
            Image(systemName: action.symbolName)
                .font(.system(size: 13))
                .frame(width: 20)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(action.name)
                        .font(.body)
                    if action.isBuiltIn {
                        Text("Built-in")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text(action.outputDisposition.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Edit") { editingAction = action }
                .buttonStyle(.borderless)
                .controlSize(.small)
            if !action.isBuiltIn {
                Button("Delete", role: .destructive) { store.delete(id: action.id) }
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
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
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
                    HStack(spacing: 8) {
                        Image(systemName: symbolName)
                            .frame(width: 20, height: 20)
                            .foregroundStyle(.secondary)
                        TextField("SF Symbol name", text: $symbolName,
                                  prompt: Text("e.g. wand.and.sparkles"))
                    }
                    Text("Enter any SF Symbol name. Preview updates instantly.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    LabeledContent("Temperature: \(String(format: "%.1f", temperature))") {
                        Slider(value: $temperature, in: 0.0...1.0, step: 0.1)
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
        let action = AIAction(
            id: initial?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            symbolName: symbolName.trimmingCharacters(in: .whitespaces).isEmpty
                ? "wand.and.sparkles" : symbolName.trimmingCharacters(in: .whitespaces),
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
