import SwiftUI
import TimeCore

@main
struct WatchApp: App {
    @State private var state = WatchState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView {
                WatchStintView()
                WatchTodayView()
                WatchSettingsView()
            }
            .tabViewStyle(.verticalPage)
            .environment(state)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await state.syncNow(reason: "foreground") } }
        }
    }
}
