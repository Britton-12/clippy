import SwiftUI

/// Drives one AI action through its lifecycle (running -> proposal -> applied or
/// failed) and publishes state for a sheet. Building the service from settings,
/// running the async call, and surfacing errors all live here so call sites stay
/// a one-liner. The actual write happens in the caller's `onApply`, after the
/// user approves — the preview + confirm contract.
@MainActor
final class AIActionRunner: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running
        case proposal(AIProposal)
        case failed(String)
    }

    @Published var phase: Phase = .idle

    var isPresenting: Bool {
        switch phase { case .idle: return false; default: return true }
    }

    /// Start an action. `work` builds the proposal from the configured service;
    /// returning nil means "nothing to propose" (e.g. no matching category).
    func run(_ work: @escaping (AIService) async throws -> AIProposal?) {
        switch AIService.fromSettings() {
        case .failure(let error):
            phase = .failed(error.localizedDescription)
        case .success(let service):
            phase = .running
            Task { [weak self] in
                do {
                    if let proposal = try await work(service) {
                        self?.phase = .proposal(proposal)
                    } else {
                        self?.phase = .failed("No suggestion was available.")
                    }
                } catch {
                    self?.phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    func reset() { phase = .idle }
}

/// The preview + confirm surface. Shows progress, the proposed change (with a
/// before/after when the action edits existing content), and Apply / Cancel.
struct AIActionSheet: View {
    @ObservedObject var runner: AIActionRunner
    /// Called with the approved text when the user taps Apply.
    let onApply: (AIProposal) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder
    private var content: some View {
        switch runner.phase {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Asking the model...")
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
        case .failed(let message):
            Label("AI action failed", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Spacer()
                Button("Close") { runner.reset() }.keyboardShortcut(.cancelAction)
            }
        case .proposal(let proposal):
            Text(proposal.label)
                .font(.headline)
            if let original = proposal.original {
                diff(original: original, proposed: proposal.proposed)
            } else {
                box(proposal.proposed)
            }
            HStack {
                Spacer()
                Button("Cancel") { runner.reset() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    onApply(proposal)
                    runner.reset()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func box(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxHeight: 220)
        .padding(8)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    private func diff(original: String, proposed: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Before").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            box(original)
            Text("After").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            box(proposed)
        }
    }
}
