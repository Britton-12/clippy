import AppKit
import SwiftUI

/// The main-pane content for the virtual "1Password" category: lists items from
/// the configured vault, reveals/copies a secret on demand (which prompts the
/// 1Password app), and creates a new secret. No values are stored by Clippy.
struct OnePasswordView: View {
    @ObservedObject private var settings = AppSettings.shared

    @State private var items: [OPItem] = []
    @State private var loading = false
    @State private var error: String?
    @State private var creating = false
    @State private var newTitle = ""
    @State private var newValue = ""
    @State private var status: String?

    private var service: OnePasswordService { OnePasswordService(vault: settings.onePasswordVault) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear { reload() }
    }

    private var header: some View {
        HStack {
            Label("1Password · \(settings.onePasswordVault)", systemImage: "key.fill")
                .font(.headline)
            Spacer()
            Button { creating.toggle() } label: { Image(systemName: "plus") }
                .help("New secret")
            Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
                .disabled(loading)
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        if !OnePasswordService.isInstalled {
            message("The 1Password CLI (op) was not found.",
                    detail: "Install 1Password 8 and turn on the command-line tool in its Developer settings.")
        } else if let error {
            message("Could not reach 1Password", detail: error)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if creating { newSecretForm }
                    if let status {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                    if loading {
                        ProgressView().controlSize(.small)
                    } else if items.isEmpty {
                        Text("No secrets in this vault yet. Use + to add one.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(items) { item in itemRow(item) }
                    }
                }
                .padding(10)
            }
        }
    }

    private var newSecretForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Title", text: $newTitle).textFieldStyle(.roundedBorder)
            SecureField("Secret value", text: $newValue).textFieldStyle(.roundedBorder)
            HStack {
                Button("Create") { create() }
                    .disabled(newTitle.isEmpty || newValue.isEmpty)
                Button("Cancel") { creating = false; newTitle = ""; newValue = "" }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func itemRow(_ item: OPItem) -> some View {
        HStack {
            Image(systemName: "lock.doc").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                Text(item.category.capitalized).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Copy") { copy(item) }
                .controlSize(.small)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    private func message(_ title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "key.slash").font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Actions

    private func reload() {
        guard OnePasswordService.isInstalled else { return }
        loading = true
        error = nil
        Task {
            do {
                let fetched = try await service.listItems()
                await MainActor.run { items = fetched; loading = false }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; loading = false }
            }
        }
    }

    private func copy(_ item: OPItem) {
        status = "Revealing \(item.title)..."
        Task {
            do {
                let value = try await service.revealValue(itemID: item.id)
                await MainActor.run {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    // Mark the write transient so the clipboard monitor never
                    // records a secret into history.
                    pb.setString(value, forType: .string)
                    pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
                    status = "Copied \(item.title) to the clipboard."
                }
            } catch {
                await MainActor.run { status = error.localizedDescription }
            }
        }
    }

    private func create() {
        let title = newTitle, value = newValue
        status = "Creating \(title)..."
        Task {
            do {
                try await service.createSecret(title: title, value: value)
                await MainActor.run {
                    creating = false; newTitle = ""; newValue = ""
                    status = "Created \(title)."
                    reload()
                }
            } catch {
                await MainActor.run { status = error.localizedDescription }
            }
        }
    }
}
