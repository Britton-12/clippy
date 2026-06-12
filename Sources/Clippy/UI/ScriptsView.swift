import AppKit
import SwiftUI

/// Manage and run stored scripts. Picking a script loads it into an editor;
/// Run executes it in a subprocess (after a confirmation) and shows the output.
struct ScriptsView: View {
    @ObservedObject private var store = ScriptStore.shared
    @ObservedObject private var settings = AppSettings.shared

    private var tokens: ThemeTokens { settings.theme }

    @State private var selection: UUID?
    @State private var editing = Script(name: "")
    @State private var running = false
    @State private var result: ScriptResult?
    @State private var confirmRun = false

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

    // MARK: - Header (picker + add/delete)

    private var header: some View {
        HStack {
            Picker("Script", selection: $selection) {
                Text("New script").tag(UUID?.none)
                ForEach(store.scripts) { script in
                    Text(script.name.isEmpty ? "Untitled" : script.name).tag(Optional(script.id))
                }
            }
            .labelsHidden()
            .onChange(of: selection) { select(selection) }

            Spacer()
            Button { newScript() } label: { Image(systemName: "plus") }
                .help("New script")
            Button { deleteSelected() } label: { Image(systemName: "trash") }
                .help("Delete script")
                .disabled(selection == nil)
        }
        .padding(10)
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
                    ProgressView().controlSize(.small)
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
                Image(systemName: result.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(result.succeeded ? .green : .red)
                Text(result.timedOut ? "Timed out" : "Exit \(result.exitCode) · \(result.durationMs) ms")
                    .font(.caption)
                Spacer()
                if !result.stdout.isEmpty {
                    Button("Copy output") { copyToPasteboard(result.stdout) }
                        .controlSize(.small)
                }
            }
            if !result.stdout.isEmpty { outputBox(result.stdout, mono: true) }
            if !result.stderr.isEmpty {
                Text("stderr").font(.caption2).foregroundStyle(.secondary)
                outputBox(result.stderr, mono: true)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func outputBox(_ text: String, mono: Bool) -> some View {
        ScrollView {
            Text(text)
                .font(mono ? .system(.caption, design: .monospaced) : .caption)
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
