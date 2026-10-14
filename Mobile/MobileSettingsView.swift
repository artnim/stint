import SwiftUI
import TimeCore

struct MobileSettingsView: View {
    @Environment(MobileState.self) private var state
    @State private var name = ""
    @State private var accounts: [GitHubAccount] = []
    @State private var newLabel = ""
    @State private var newToken = ""
    @State private var status = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Reports") { TextField("Your name", text: $name).onChange(of: name) { if name != state.userName { state.userName = name } } }
                Section("iCloud sync") {
                    Text(state.syncStatus).font(.caption)
                    Button("Sync now") { Task { await state.syncNow(reason: "manual") } }
                }
                Section("GitHub accounts") {
                    ForEach(accounts) { a in
                        HStack { Text(a.label); Spacer(); Text(a.token.prefix(4) + "…").font(.caption.monospaced()).foregroundStyle(.secondary) }
                    }
                    .onDelete { offsets in
                        var list = accounts; list.remove(atOffsets: offsets)
                        try? KeychainStore.saveGitHubAccounts(list); accounts = list
                    }
                    TextField("Label", text: $newLabel)
                    SecureField("Token", text: $newToken)
                    Button("Add") { add() }.disabled(newLabel.isEmpty || newToken.isEmpty)
                    if !status.isEmpty { Text(status).font(.caption) }
                }
                Section("Repositories") {
                    ForEach(state.repos) { r in
                        Picker(r.fullName, selection: Binding(get: { r.projectId }, set: { state.assignRepo(r.id!, to: $0) })) {
                            Text("Unmapped").tag(Int64?.none)
                            ForEach(state.projects) { p in Text(p.name).tag(Int64?.some(p.id!)) }
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear { name = state.userName; accounts = KeychainStore.githubAccounts() }
        }
    }

    private func add() {
        let account = GitHubAccount(label: newLabel.trimmingCharacters(in: .whitespaces), token: newToken.trimmingCharacters(in: .whitespacesAndNewlines))
        Task {
            do {
                let n = try await GitHubClient(token: account.token).assignedIssues().count
                try KeychainStore.saveGitHubAccounts(accounts + [account])
                accounts.append(account); newLabel = ""; newToken = ""
                status = "\(account.label): \(n) open items assigned to you."
                await state.syncIssues()
            } catch { status = "\(account.label): \(error)" }
        }
    }
}
