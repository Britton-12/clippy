import SwiftUI
import AppKit

/// The main-pane view shown when Scripts is selected in the side panel.
/// Lists every saved script with a Run button; shows inline output after each
/// run with stdout/stderr distinguished, exit code, and duration.
/// Respects feedsClipboard (stdin from current clipboard) and
/// outputToClipboard (writes stdout to pasteboard on success).
struct ScriptsPanelView: View {
    @ObservedObject var store: ClipStore
    let onOpenSettings: () -> Void

    @ObservedObject private var scriptStore = ScriptStore.shared
    @ObservedObject private var settings = AppSettings.shared

    /// Per-script run state, keyed by script UUID.
    @State private var runStates: [UUID: RunState] = [:]

    private var tokens: ThemeTokens { settings.theme }

    var body: some View {
        if scriptStore.scripts.isEmpty {
            emptyState
        } else {
            scriptList
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(tokens.textSecondary)
            Text("No scripts yet")
                .font(PanelTypography.body(settings).weight(.semibold))
                .foregroundStyle(tokens.textPrimary)
            Text("Add scripts in Settings to run them from here.")
                .font(PanelTypography.metadata(settings))
                .foregroundStyle(tokens.textSecondary)
                .multilineTextAlignment(.center)
            Button("Open Settings > Scripts") {
                onOpenSettings()
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Script list

    private var scriptList: some View {
        VStack(spacing: 0) {
            manageHeader
            Divider()
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(scriptStore.scripts) { script in
                        ScriptRowView(
                            script: script,
                            store: store,
                            runState: Binding(
                                get: { runStates[script.id] ?? .idle },
                                set: { runStates[script.id] = $0 }
                            ),
                            tokens: tokens,
                            settings: settings
                        )
                    }
                }
                .padding(10)
            }
        }
    }

    private var manageHeader: some View {
        HStack {
            Text("SCRIPTS")
                .font(PanelTypography.micro(settings).weight(.semibold))
                .kerning(0.6)
                .foregroundStyle(tokens.textSecondary)
            Spacer()
            Button("Manage...") {
                onOpenSettings()
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .foregroundStyle(tokens.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tokens.headerBar.opacity(settings.panelOpacity))
    }
}

// MARK: - Per-script row

private struct ScriptRowView: View {
    let script: Script
    let store: ClipStore
    @Binding var runState: RunState
    let tokens: ThemeTokens
    let settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            rowHeader
            if case .running = runState {
                runningView
            } else if case .done(let result) = runState {
                outputView(result)
            }
        }
        .padding(10)
        .background(tokens.cardSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tokens.cardBorder, lineWidth: 1)
        )
    }

    // MARK: Header row

    private var rowHeader: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(script.name.isEmpty ? "Untitled" : script.name)
                    .font(PanelTypography.body(settings).weight(.medium))
                    .foregroundStyle(tokens.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    interpreterBadge
                    if script.feedsClipboard {
                        flagBadge("arrow.up.to.line", "Reads clipboard")
                    }
                    if script.outputToClipboard {
                        flagBadge("arrow.down.to.line", "Writes to clipboard")
                    }
                    Spacer(minLength: 0)
                    Text(script.updatedAt, format: Date.RelativeFormatStyle(presentation: .numeric, unitsStyle: .narrow))
                        .font(PanelTypography.micro(settings))
                        .foregroundStyle(tokens.textSecondary)
                }
            }
            Spacer(minLength: 8)
            runButton
        }
    }

    private var interpreterBadge: some View {
        Text(script.interpreter.displayName)
            .font(PanelTypography.micro(settings).weight(.medium))
            .foregroundStyle(tokens.accent)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                tokens.accent.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
    }

    private func flagBadge(_ icon: String, _ help: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(tokens.textSecondary)
            .help(help)
    }

    private var runButton: some View {
        let isRunning: Bool = {
            if case .running = runState { return true }
            return false
        }()
        return Button {
            run()
        } label: {
            Group {
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isRunning)
        .help("Run script")
        .accessibilityLabel("Run \(script.name)")
    }

    // MARK: Running indicator

    private var runningView: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Running...")
                .font(PanelTypography.metadata(settings))
                .foregroundStyle(tokens.textSecondary)
        }
        .padding(.vertical, 4)
    }

    // MARK: Output view

    @ViewBuilder
    private func outputView(_ result: ScriptResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status line
            HStack(spacing: 6) {
                Image(systemName: result.timedOut
                    ? "exclamationmark.clock.fill"
                    : (result.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill"))
                    .foregroundStyle(result.succeeded ? Color(nsColor: .systemGreen) : Color(nsColor: .systemRed))
                    .font(.system(size: 12))
                Text(statusLabel(result))
                    .font(PanelTypography.metadata(settings).weight(.medium))
                    .foregroundStyle(result.succeeded ? Color(nsColor: .systemGreen) : Color(nsColor: .systemRed))
                Spacer()
                Text("\(result.durationMs) ms")
                    .font(PanelTypography.micro(settings))
                    .foregroundStyle(tokens.textSecondary)
                    .monospacedDigit()
            }

            // stdout (only shown when non-empty)
            if !result.stdout.isEmpty {
                outputBlock(result.stdout, label: "stdout", isError: false)
            }

            // stderr (only shown when non-empty, clearly labeled in red)
            if !result.stderr.isEmpty {
                outputBlock(result.stderr, label: "stderr", isError: true)
            }

            if result.stdout.isEmpty && result.stderr.isEmpty {
                Text("(no output)")
                    .font(PanelTypography.metadata(settings))
                    .foregroundStyle(tokens.textSecondary)
                    .italic()
            }

            outputActions(result)
        }
        .padding(8)
        .background(tokens.scrollBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func outputBlock(_ text: String, label: String, isError: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(PanelTypography.micro(settings).weight(.semibold))
                .foregroundStyle(isError ? Color(nsColor: .systemRed).opacity(0.8) : tokens.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(String(text.trimmingCharacters(in: .newlines).prefix(2000)))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(tokens.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
        }
    }

    @ViewBuilder
    private func outputActions(_ result: ScriptResult) -> some View {
        let hasStdout = !result.stdout.isEmpty
        HStack(spacing: 8) {
            if hasStdout {
                Button("Copy output") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(result.stdout, forType: .string)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)

                Button("Save as clip") {
                    store.saveScriptOutput(result.stdout)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
            Spacer()
            Button("Dismiss") {
                runState = .idle
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .foregroundStyle(tokens.textSecondary)
        }
    }

    // MARK: Status label

    private func statusLabel(_ result: ScriptResult) -> String {
        if result.timedOut { return "Timed out" }
        return result.exitCode == 0 ? "Succeeded" : "Failed (exit \(result.exitCode))"
    }

    // MARK: Run action

    private func run() {
        let input = script.feedsClipboard ? NSPasteboard.general.string(forType: .string) : nil
        runState = .running
        Task { @MainActor in
            let result = await ScriptRunner.run(script, input: input)
            // Honor outputToClipboard before surfacing the result in the UI.
            if script.outputToClipboard, result.succeeded, !result.stdout.isEmpty {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(result.stdout, forType: .string)
            }
            runState = .done(result)
        }
    }
}

// MARK: - Run state

/// The three states a per-script row can be in.
enum RunState: Equatable {
    case idle
    case running
    case done(ScriptResult)
}
