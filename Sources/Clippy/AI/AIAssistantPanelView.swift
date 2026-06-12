import SwiftUI

// MARK: - Message model

/// One turn in the assistant conversation.
struct AssistantMessage: Identifiable {
    enum Role { case user, assistant }
    /// Inline tool activity shown below the last assistant bubble while
    /// the agent is still running.
    enum ToolActivity: Equatable {
        case running(String)   // tool name currently executing
        case done(String)      // "Ran search_clips"
    }

    let id = UUID()
    let role: Role
    var text: String
    /// Tool activity notices attached to this message (assistant turns only).
    var toolActivities: [ToolActivity] = []
}

// MARK: - View model

/// Drives one agentic conversation. Lives for the panel session; discarded
/// when the panel closes (persistence is intentionally out of scope for v1).
@MainActor
final class AIAssistantViewModel: ObservableObject {
    enum State: Equatable {
        case ready
        case thinking
        case notConfigured(String)   // human-readable reason
    }

    @Published private(set) var messages: [AssistantMessage] = []
    @Published private(set) var state: State = .ready
    @Published var inputText: String = ""

    // Confirmation sheet state
    @Published var pendingConfirmation: PendingConfirmation?

    struct PendingConfirmation: Identifiable {
        let id = UUID()
        let prompt: String
        var continuation: CheckedContinuation<Bool, Never>?
    }

    private var confirmationResult: Bool = false

    /// Kick off a user turn. Builds the provider from current settings,
    /// dispatches to the agent loop, feeds replies back to `messages`.
    func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""

        // Validate configuration before touching the network.
        switch AIService.fromSettings() {
        case .failure(let err):
            state = .notConfigured(err.localizedDescription)
            return
        case .success:
            break
        }

        let settings = AppSettings.shared
        // Build an AIAgentProvider from the same settings used by AIService.
        let kind = settings.aiProvider
        let base = settings.aiBaseURL.isEmpty ? kind.defaultBaseURL : settings.aiBaseURL
        let model = settings.aiModel.isEmpty ? kind.defaultModel : settings.aiModel
        var apiKey = ""
        if kind.needsAPIKey {
            apiKey = KeychainStore.shared.read(account: kind.keychainAccount) ?? ""
        }
        let config = AIProviderConfig(
            baseURL: base, apiKey: apiKey, model: model,
            apiVersion: settings.aiAzureAPIVersion
        )
        let provider = AIAgentProviderFactory.make(kind: kind, config: config)

        // Append the user turn.
        messages.append(AssistantMessage(role: .user, text: text))
        state = .thinking

        let userMessage = AssistantMessage(role: .assistant, text: "")
        messages.append(userMessage)
        let assistantIndex = messages.count - 1

        let history = buildHistory()

        Task { [weak self] in
            guard let self else { return }

            let registry = AIToolRegistry.makeFiltered(
                allowScripts: settings.aiAgentAllowScripts,
                allowCodeExecution: settings.aiAgentAllowCodeExecution,
                confirmHook: { [weak self] prompt in
                    guard let self else { return false }
                    return await self.askConfirmation(prompt)
                }
            )

            do {
                let answer = try await AIAgent.completeWithTools(
                    messages: history,
                    provider: provider,
                    tools: registry.all,
                    confirm: { [weak self] prompt in
                        guard let self else { return false }
                        return await self.askConfirmation(prompt)
                    }
                )
                self.messages[assistantIndex].text = answer
                self.state = .ready
            } catch {
                self.messages[assistantIndex].text = error.localizedDescription
                self.state = .ready
            }
        }
    }

    func clearConversation() {
        messages = []
        state = .ready
        inputText = ""
    }

    // MARK: - Confirmation

    /// Present a confirmation sheet and suspend until the user responds.
    private func askConfirmation(_ prompt: String) async -> Bool {
        await withCheckedContinuation { cont in
            pendingConfirmation = PendingConfirmation(
                prompt: prompt,
                continuation: cont
            )
        }
    }

    func resolveConfirmation(_ allowed: Bool) {
        guard let confirmation = pendingConfirmation else { return }
        pendingConfirmation = nil
        confirmation.continuation?.resume(returning: allowed)
    }

    // MARK: - Helpers

    private func buildHistory() -> [AIMessage] {
        messages.compactMap { msg -> AIMessage? in
            // Skip empty trailing assistant placeholder.
            guard !msg.text.isEmpty || msg.role == .user else { return nil }
            let role: AIRole = msg.role == .user ? .user : .assistant
            return AIMessage(role: role, content: msg.text)
        }
    }
}

// MARK: - Main view

/// The AI Assistant pane shown when `.assistant` is selected in the sidebar.
struct AIAssistantPanelView: View {
    @ObservedObject var store: ClipStore
    let onOpenSettings: () -> Void

    @StateObject private var vm = AIAssistantViewModel()
    @ObservedObject private var settings = AppSettings.shared
    @FocusState private var inputFocused: Bool

    private var tokens: ThemeTokens { settings.theme }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            inputBar
        }
        .sheet(item: $vm.pendingConfirmation) { confirmation in
            ToolConfirmationSheet(
                prompt: confirmation.prompt,
                onAllow: { vm.resolveConfirmation(true) },
                onDeny: { vm.resolveConfirmation(false) }
            )
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tokens.accent)
            Text("AI Assistant")
                .font(PanelTypography.body(settings).weight(.semibold))
                .foregroundStyle(tokens.textPrimary)
            Spacer()
            if !vm.messages.isEmpty {
                Button {
                    vm.clearConversation()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(tokens.textSecondary)
                }
                .buttonStyle(.borderless)
                .help("Clear conversation")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tokens.headerBar.opacity(settings.panelOpacity))
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !settings.aiEnabled {
            notConfiguredState(
                icon: "sparkles.slash",
                message: "AI features are turned off.",
                cta: "Open Settings"
            )
        } else if case .notConfigured(let reason) = vm.state {
            notConfiguredState(icon: "exclamationmark.triangle", message: reason, cta: "Open Settings")
        } else if vm.messages.isEmpty {
            emptyState
        } else {
            messageThread
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "sparkles")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(tokens.textSecondary)
                Text("Ask the assistant anything about your clips, or ask it to create, search, or transform content.")
                    .font(PanelTypography.body(settings))
                    .foregroundStyle(tokens.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                VStack(alignment: .leading, spacing: 8) {
                    suggestionButton("Search my clips for meeting notes")
                    suggestionButton("Create a clip with a bash one-liner to list files")
                    suggestionButton("Summarize what I copied today")
                }
            }
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .background(tokens.scrollBackground.opacity(settings.panelOpacity))
    }

    private func suggestionButton(_ text: String) -> some View {
        Button {
            vm.inputText = text
            inputFocused = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(tokens.accent)
                Text(text)
                    .font(PanelTypography.body(settings))
                    .foregroundStyle(tokens.textPrimary)
                    .multilineTextAlignment(.leading)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(tokens.cardSurface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(tokens.cardBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    private var messageThread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(vm.messages) { message in
                        MessageBubble(message: message, tokens: tokens, settings: settings)
                            .id(message.id)
                    }
                    if vm.state == .thinking {
                        thinkingIndicator
                            .id("thinking")
                    }
                }
                .padding(10)
            }
            .background(tokens.scrollBackground.opacity(settings.panelOpacity))
            .onChange(of: vm.messages.count) { _, _ in
                if let last = vm.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: vm.state) { _, newState in
                if newState == .thinking {
                    withAnimation { proxy.scrollTo("thinking", anchor: .bottom) }
                }
            }
        }
    }

    private var thinkingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Thinking...")
                .font(PanelTypography.body(settings))
                .foregroundStyle(tokens.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func notConfiguredState(icon: String, message: String, cta: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(tokens.textSecondary)
            Text(message)
                .font(PanelTypography.body(settings))
                .foregroundStyle(tokens.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Button(cta) { onOpenSettings() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tokens.scrollBackground.opacity(settings.panelOpacity))
    }

    // MARK: Input bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask anything...", text: $vm.inputText, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .font(PanelTypography.body(settings))
                .foregroundStyle(tokens.textPrimary)
                .focused($inputFocused)
                .onSubmit {
                    if !vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && vm.state == .ready {
                        vm.send()
                    }
                }
                .onAppear { inputFocused = true }
            Button {
                vm.send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(
                        vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || vm.state == .thinking
                        ? tokens.textSecondary
                        : tokens.accent
                    )
            }
            .buttonStyle(.plain)
            .disabled(
                vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || vm.state == .thinking
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tokens.footerBar.opacity(settings.panelOpacity))
    }
}

// MARK: - Message bubble

private struct MessageBubble: View {
    let message: AssistantMessage
    let tokens: ThemeTokens
    let settings: AppSettings

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            HStack {
                if message.role == .user { Spacer(minLength: 40) }
                Text(message.text.isEmpty ? " " : message.text)
                    .font(PanelTypography.body(settings))
                    .foregroundStyle(message.role == .user ? Color.white : tokens.textPrimary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        message.role == .user
                            ? tokens.accent
                            : tokens.cardSurface,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                message.role == .user ? Color.clear : tokens.cardBorder,
                                lineWidth: 1
                            )
                    )
                if message.role == .assistant { Spacer(minLength: 40) }
            }
            // Tool activity notices (assistant turns only).
            ForEach(Array(message.toolActivities.enumerated()), id: \.offset) { _, activity in
                toolActivityLabel(activity)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    private func toolActivityLabel(_ activity: AssistantMessage.ToolActivity) -> some View {
        let (icon, label): (String, String) = {
            switch activity {
            case .running(let name): return ("gear", "Running \(name)...")
            case .done(let name):    return ("checkmark.circle", "Ran \(name)")
            }
        }()
        return Label(label, systemImage: icon)
            .font(PanelTypography.metadata(settings))
            .foregroundStyle(tokens.textSecondary)
            .padding(.leading, 4)
    }
}

// MARK: - Tool confirmation sheet

/// Shown when the agent wants to run a gated tool (run_script, execute_code).
/// The user sees the full prompt before deciding.
struct ToolConfirmationSheet: View {
    let prompt: String
    let onAllow: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Tool Confirmation Required", systemImage: "exclamationmark.shield")
                .font(.headline)
            Text("The AI assistant wants to perform the following action. Review it carefully before allowing.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(prompt)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .frame(maxHeight: 200)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("Deny", role: .cancel) { onDeny() }
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Allow") { onAllow() }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
