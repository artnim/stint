import SwiftUI
import CloudKit
import TimeCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.registerForRemoteNotifications()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in await AppState.shared?.syncNow(reason: "active") }
        }
    }
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        if CKNotification(fromRemoteNotificationDictionary: userInfo) != nil {
            Task { @MainActor in await AppState.shared?.syncNow(reason: "push") }
        }
    }
}

@main
struct StintApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState.load()

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environment(state)
        } label: {
            // template image from Assets.xcassets (ring + stint arc); the elapsed time shows a running timer
            Label { Text(state.menuTitle) } icon: { Image("MenuBarIcon") }
                .labelStyle(.titleAndIcon)
        }
        .menuBarExtraStyle(.window)

        Window("Entries", id: "entries") {
            EntriesView().environment(state)
        }
        .defaultSize(width: 900, height: 600)

        Window("Reports", id: "reports") {
            ReportsView().environment(state)
        }
        .defaultSize(width: 1100, height: 760)

        Settings {
            SettingsView().environment(state)
        }
    }
}
