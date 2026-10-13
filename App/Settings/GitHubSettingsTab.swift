import SwiftUI
import TimeCore

struct GitHubSettingsTab: View {
    @Environment(AppState.self) private var state
    @State private var accounts: [GitHubAccount] = []
    @State private var newLabel = ""
    @State private var newToken = ""
    @State private var status = ""

    private var trimmedLabel: String { newLabel.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedToken: String { newToken.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canAdd: Bool {
        !trimmedLabel.isEmpty && !trimmedToken.isEmpty && !accounts.contains { $0.label == trimmedLabel }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("One fine-grained token per resource owner (your account, each organisation), with read access to Issues and Pull requests on the repos you track. Nothing is written to GitHub.")
                .font(.caption).foregroundStyle(.secondary)
            List(accounts) { account in
                HStack {
                    Text(account.label).frame(width: 160, alignment: .leading)
                    Text(masked(account.token)).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    Button("Test") { test(account.token, label: account.label) }
                    Button("Remove") { remove(account) }
                }
            }
            .frame(minHeight: 120)
            HStack {
                TextField("Label (e.g. org name)", text: $newLabel).frame(width: 160)
                SecureField("Personal access token", text: $newToken)
                Button("Add") { add() }.disabled(!canAdd)
            }
            Text(status).font(.caption)
            Spacer()
        }
        .padding()
        .onAppear { accounts = KeychainStore.githubAccounts() }
    }

    private func masked(_ token: String) -> String {
        token.count > 8 ? "\(token.prefix(4))…\(token.suffix(4))" : "••••"
    }

    private func test(_ token: String, label: String) {
        Task {
            status = "Testing \(label)…"
            do {
                let n = try await GitHubClient(token: token).assignedIssues().count
                status = "\(label): OK, \(n) open items assigned to you."
            } catch { status = "\(label): failed: \(error)" }
        }
    }

    private func add() {
        let account = GitHubAccount(label: trimmedLabel, token: trimmedToken)
        Task {
            status = "Testing \(account.label)…"
            do {
                let n = try await GitHubClient(token: account.token).assignedIssues().count
                try save(accounts + [account])
                newLabel = ""; newToken = ""
                status = "\(account.label): saved, \(n) open items assigned to you."
                await state.syncIssues()
            } catch { status = "\(account.label): not saved, \(error)" }
        }
    }

    private func remove(_ account: GitHubAccount) {
        do {
            try save(accounts.filter { $0.label != account.label })
            status = "Removed \(account.label)."
            Task { await state.syncIssues() }
        } catch { status = "Keychain error \((error as? KeychainStore.KeychainError)?.status ?? -1)" }
    }

    private func save(_ list: [GitHubAccount]) throws {
        try KeychainStore.saveGitHubAccounts(list)
        accounts = list
    }
}
