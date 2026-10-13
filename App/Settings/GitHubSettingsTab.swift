import SwiftUI
import TimeCore

struct GitHubSettingsTab: View {
    @Environment(AppState.self) private var state
    @State private var token = ""
    @State private var status = ""

    var body: some View {
        Form {
            SecureField("Personal access token", text: $token)
            Text("Fine-grained token with read access to Issues and Pull requests on the repos you track. Nothing is written to GitHub.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Save") {
                    do { try KeychainStore.write(KeychainStore.tokenAccount, token); status = "Saved." }
                    catch { status = "Keychain error \((error as? KeychainStore.KeychainError)?.status ?? -1)" }
                }
                .disabled(token.isEmpty)
                Button("Test") {
                    Task {
                        status = "Testing…"
                        do {
                            let n = try await GitHubClient(token: token).assignedIssues().count
                            status = "OK: \(n) open items assigned to you."
                        } catch { status = "Failed: \(error)" }
                    }
                }
                .disabled(token.isEmpty)
                Button("Remove") { KeychainStore.delete(KeychainStore.tokenAccount); token = ""; status = "Removed." }
                Spacer()
                Text(status).font(.caption)
            }
        }
        .padding()
        .onAppear { token = KeychainStore.read(KeychainStore.tokenAccount) ?? "" }
    }
}
