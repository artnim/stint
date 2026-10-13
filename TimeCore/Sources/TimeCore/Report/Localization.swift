import Foundation

public enum Language: String, Codable, CaseIterable, Identifiable {
    case de, en
    public var id: String { rawValue }
}

public struct Strings: Equatable {
    public let title, client, project, user, period, total, generated: String
    public let time, issue, description, tags, duration: String
    public let summaryTags, noTag, summaryProjects, days, entries, several: String
    public let weekdays: [String]   // Monday first
    public let months: [String]     // index 1...12; index 0 unused

    public static func of(_ lang: Language) -> Strings {
        switch lang {
        case .de: return .de
        case .en: return .en
        }
    }

    static let de = Strings(
        title: "Leistungsnachweis", client: "Kunde", project: "Projekt", user: "Bearbeiter",
        period: "Zeitraum", total: "Gesamt", generated: "Erstellt am",
        time: "Zeit", issue: "Ticket", description: "Tätigkeit", tags: "Tags", duration: "Dauer",
        summaryTags: "Aufteilung nach Tags", noTag: "ohne Tag", summaryProjects: "Aufteilung nach Projekt",
        days: "Arbeitstage", entries: "Einträge", several: "mehrere",
        weekdays: ["Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag"],
        months: ["", "Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August",
                 "September", "Oktober", "November", "Dezember"])

    static let en = Strings(
        title: "Time Report", client: "Client", project: "Project", user: "User",
        period: "Period", total: "Total", generated: "Generated",
        time: "Time", issue: "Issue", description: "Activity", tags: "Tags", duration: "Duration",
        summaryTags: "Breakdown by tag", noTag: "untagged", summaryProjects: "Breakdown by project",
        days: "working days", entries: "entries", several: "several",
        weekdays: ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"],
        months: ["", "January", "February", "March", "April", "May", "June", "July", "August",
                 "September", "October", "November", "December"])
}
