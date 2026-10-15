import Foundation

/// Records whether this device registered for remote notifications and when the last CloudKit push
/// arrived, so Settings can show it. Diagnostic only; sync never depends on it.
public enum PushDiagnostics {
    private static let registeredKey = "push.registered"
    private static let errorKey = "push.error"
    private static let lastKey = "push.last"

    public static func registered() {
        UserDefaults.standard.set(true, forKey: registeredKey)
        UserDefaults.standard.removeObject(forKey: errorKey)
    }

    public static func failed(_ error: Error) {
        UserDefaults.standard.set(false, forKey: registeredKey)
        UserDefaults.standard.set(error.localizedDescription, forKey: errorKey)
    }

    public static func received(at date: Date = Date()) {
        UserDefaults.standard.set(date, forKey: lastKey)
    }

    /// e.g. "Push: registered · last 16:31, 15 Oct" or "Push: failed – no valid aps-environment".
    public static var summary: String {
        let d = UserDefaults.standard
        let state: String
        if let error = d.string(forKey: errorKey) { state = "failed – \(error)" }
        else if d.bool(forKey: registeredKey) { state = "registered" }
        else { state = "not registered" }
        let last = (d.object(forKey: lastKey) as? Date).map { "last " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "none received"
        return "Push: \(state) · \(last)"
    }
}
