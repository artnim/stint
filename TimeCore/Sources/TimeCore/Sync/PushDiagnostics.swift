import Foundation

/// Records whether this device registered for remote notifications and when the last CloudKit push
/// arrived, so Settings can show it. Diagnostic only; sync never depends on it.
public enum PushDiagnostics {
    private static let registeredKey = "push.registered"
    private static let errorKey = "push.error"
    private static let lastKey = "push.last"
    private static let outcomeKey = "push.outcome"

    private static let requestedKey = "push.requested"

    public static func requested(at date: Date = Date()) {
        UserDefaults.standard.set(date, forKey: requestedKey)
    }

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

    /// The watch marks a push it starts handling and overwrites the mark with the result, so a push whose
    /// handling was cut short (the app suspended mid-sync) still reads "did not finish".
    public static func handling() {
        UserDefaults.standard.set("did not finish", forKey: outcomeKey)
    }

    public static func handled(_ outcome: String) {
        UserDefaults.standard.set(outcome, forKey: outcomeKey)
    }

    /// e.g. "Push: registered · last 16:31, 15 Oct" or "Push: failed – no valid aps-environment".
    public static var summary: String {
        let d = UserDefaults.standard
        let state: String
        if let error = d.string(forKey: errorKey) { state = "failed – \(error)" }
        else if d.bool(forKey: registeredKey) { state = "registered" }
        else if let asked = d.object(forKey: requestedKey) as? Date {
            state = "no answer to request at " + asked.formatted(date: .omitted, time: .shortened)
        } else { state = "never requested" }
        let last = (d.object(forKey: lastKey) as? Date).map { "last " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "none received"
        let outcome = d.string(forKey: outcomeKey).map { " → \($0)" } ?? ""
        return "Push: \(state) · \(last)\(outcome)"
    }
}
