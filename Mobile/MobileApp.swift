import CloudKit
import SwiftUI
import UIKit

final class MobileAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard CKNotification(fromRemoteNotificationDictionary: userInfo) != nil else { completionHandler(.noData); return }
        Task { @MainActor in await MobileState.shared?.syncNow(reason: "push"); completionHandler(.newData) }
    }
}

@main
struct MobileApp: App {
    @UIApplicationDelegateAdaptor(MobileAppDelegate.self) private var delegate
    @State private var state = MobileState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView {
                StintView().tabItem { Label("Stint", systemImage: "timer") }
                MobileEntriesView().tabItem { Label("Entries", systemImage: "list.bullet") }
                MobileSettingsView().tabItem { Label("Settings", systemImage: "gear") }
            }
            .environment(state)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await state.syncNow(reason: "foreground"); await state.syncIssues() } }
        }
    }
}
