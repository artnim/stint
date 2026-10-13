import SwiftUI
import TimeCore

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab().tabItem { Label("General", systemImage: "gear") }
            GitHubSettingsTab().tabItem { Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right") }
        }
        .frame(width: 560, height: 420)
    }
}

struct GeneralSettingsTab: View {
    @Environment(AppState.self) private var state
    @State private var name = ""

    var body: some View {
        Form {
            TextField("Your name (shown on reports)", text: $name)
                .onSubmit { state.userName = name }
            LabeledContent("Database") { Text(AppState.databaseURL.path).textSelection(.enabled) }
        }
        .padding()
        .onAppear { name = state.userName }
    }
}
