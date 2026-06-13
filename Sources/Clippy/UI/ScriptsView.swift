import AppKit
import SwiftUI

/// Manage and run stored scripts. Picking a script loads it into an editor;
/// Run executes it in a subprocess (after a confirmation) and shows the output.
struct ScriptsView: View {
    @ObservedObject private var store = ScriptStore.shared
    // Theme tokens drive surfaces/borders/text so a theme switch repaints this view.
    @ObservedObject private var settings = AppSettings.shared
    private var tokens: ThemeTokens { settings.theme }

    @State private var selection: UUID?
    @State private var editing = Script(name: "")
    @State private var running = false
    @State private var result: ScriptResult?
    @State private var confirmRun = false
    @State private var draggingOverScriptID: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            editor
        }
        .onAppear { if store.scripts.isEmpty { newScript() } else { select(store.scripts.first?.id) } }
        .confirmationDialog("Run \"\(editing.name.isEmpty ? "Untitled" : editing.name)\"?",
                            isPresented: $confirmRun, titleVisibility: .visible) {
            Button("Run", role: .destructive) { run() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This executes code on your Mac with your user permissions.")
        }
    }

    // MARK: - Header (script list + add/delete)

    private var header: some View {
        VStack(spacing: 0) {
            // Toolbar row: title + add/delete buttons
            HStack {
                Text("Scripts")
                    .font(.headline)
                Spacer()
                Button { newScript() } label: { Image(systemName: "plus") }
                    .help("New script")
                Button { deleteSelected() } label: { Image(systemName: "trash") }
                    .help("Delete script")
                    .disabled(selection == nil)
            }
            .padding(10)
            Divider()
            // Reorderable script list replaces the Picker so rows can be dragged.
            ScrollView {
                LazyVStack(spacing: 2) {
                    // "New script" row mirrors the old Picker's nil-tag entry.
                    Button {
                        newScript()
                    } label: {
                        HStack {
                            Text("New script")
                                .font(.body)
                                .foregroundStyle(selection == nil ? Color.accentColor : tokens.textSecondary)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            selection == nil
                                ? tokens.cardSurface
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                    }
                    .buttonStyle(.plain)

                    ForEach(store.scripts) { script in
                        Button {
                            select(script.id)
                        } label: {
                            HStack {
                                Text(script.name.isEmpty ? "Untitled" : script.name)
                                    .font(.body)
                                    .foregroundStyle(
                                        selection == script.id
                                            ? Color.accentColor
                                            : tokens.textPrimary
                                    )
                                    .lineLimit(1)
                                Spacer()
                                Text(script.interpreter.displayName)
                                    .font(.caption2)
                                    .foregroundStyle(tokens.textSecondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                selection == script.id
                                    ? tokens.cardSurface
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 5)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(
                                        selection == script.id
                                            ? tokens.cardBorder
                                            : Color.clear,
                                        lineWidth: 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .reorderDraggable(id: script.id.uuidString)
                        .reorderDropDestination(
                            id: script.id.uuidString,
                            draggingOver: $draggingOverScriptID
                        ) { draggedStr, targetStr in
                            if let d = UUID(uuidString: draggedStr),
                               let t = UUID(uuidString: targetStr) {
                                store.moveScript(draggedID: d, before: t)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 160)
            Divider()
        }
    }

    // MARK: - Editor

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Name", text: $editing.name)
                    .textFieldStyle(.roundedBorder)

                Picker("Interpreter", selection: $editing.interpreter) {
                    ForEach(ScriptInterpreter.allCases) { Text($0.displayName).tag($0) }
                }

                PlainTextEditor(text: $editing.body)
                    .frame(minHeight: 140)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(tokens.cardBorder, lineWidth: 1))

                Toggle("Feed the current clipboard text to the script (stdin and $CLIPPY_CLIP)",
                       isOn: $editing.feedsClipboard)
                Toggle("Offer the output as a new clip when it finishes",
                       isOn: $editing.outputToClipboard)

                HStack {
                    Button("Save") { save() }
                        .disabled(editing.name.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button(running ? "Running..." : "Run") { confirmRun = true }
                        .disabled(running || editing.body.isEmpty)
                    Spacer()
                }

                if running {
                    // No cancel yet (out of scope); label clarifies the script is still running.
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Running...").font(.caption).foregroundStyle(tokens.textSecondary)
                    }
                    .help("The script is still running.")
                }
                if let result {
                    outputView(result)
                }
            }
            .padding(12)
        }
    }

    private func outputView(_ result: ScriptResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                // Green/red are kept here: they carry true success/failure status,
                // for which the token table has no semantic color.
                Image(systemName: result.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(result.succeeded ? .green : .red)
                Text(result.timedOut ? "Timed out" : "Exit \(result.exitCode) - \(result.durationMs) ms")
                    .font(.caption)
                    .foregroundStyle(tokens.textPrimary)
                Spacer()
                if !result.stdout.isEmpty {
                    Button("Copy output") { copyToPasteboard(result.stdout) }
                        .controlSize(.small)
                }
            }
            if !result.stdout.isEmpty { outputBox(result.stdout, mono: true) }
            if !result.stderr.isEmpty {
                Text("stderr").font(.caption2).foregroundStyle(tokens.textSecondary)
                outputBox(result.stderr, mono: true)
            }
        }
        .padding(8)
        .background(tokens.cardSurface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(tokens.cardBorder))
    }

    private func outputBox(_ text: String, mono: Bool) -> some View {
        ScrollView {
            Text(text)
                .font(mono ? .system(.caption, design: .monospaced) : .caption)
                .foregroundStyle(tokens.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxHeight: 140)
    }

    // MARK: - Actions

    private func newScript() {
        editing = Script(name: "")
        selection = nil
        result = nil
    }

    private func select(_ id: UUID?) {
        result = nil
        guard let id, let script = store.script(id: id) else { newScript(); return }
        editing = script
        selection = id
    }

    private func save() {
        if store.script(id: editing.id) != nil {
            store.update(editing)
        } else {
            store.add(editing)
        }
        selection = editing.id
    }

    private func deleteSelected() {
        guard let id = selection else { return }
        store.delete(id: id)
        newScript()
    }

    private func run() {
        let input = editing.feedsClipboard ? NSPasteboard.general.string(forType: .string) : nil
        running = true
        result = nil
        Task {
            let outcome = await ScriptRunner.run(editing, input: input)
            await MainActor.run {
                result = outcome
                running = false
            }
        }
    }

    private func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
