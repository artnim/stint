import Foundation

private let monthAbbrev = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

public func fmtHours(_ h: Double, _ lang: Language) -> String {
    var s = String(format: "%.2f", h)
    if lang == .de { s = s.replacingOccurrences(of: ".", with: ",") }
    return s + " h"
}

private func weekdayIndex(_ day: Day) -> Int {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let wd = cal.component(.weekday, from: day.date(in: cal))   // 1 = Sunday
    return (wd + 5) % 7                                           // 0 = Monday
}

private func fmtShortDate(_ d: Day, _ lang: Language) -> String {
    lang == .de
        ? String(format: "%02d.%02d.%04d", d.day, d.month, d.year)
        : String(format: "%02d %@ %04d", d.day, monthAbbrev[d.month], d.year)
}

public func fmtDate(_ d: Day, _ lang: Language) -> String {
    "\(Strings.of(lang).weekdays[weekdayIndex(d)]), \(fmtShortDate(d, lang))"
}

public func fmtPeriod(_ a: Day, _ b: Day, _ lang: Language) -> String {
    "\(fmtShortDate(a, lang)) – \(fmtShortDate(b, lang))"
}

/// Tag lists often repeat whole issue titles — keep them short.
public func shortTags(_ tags: [String], maxTags: Int, maxChars: Int) -> String {
    var shown = tags.prefix(maxTags).map { t -> String in
        if t.count <= maxChars { return t }
        let cut = String(t.prefix(maxChars - 1))
        return cut.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) + "\u{2026}"
    }
    let rest = tags.count - shown.count
    if rest > 0 { shown.append("+\(rest)") }
    return shown.joined(separator: ", ")
}

/// Replace {Month}/{Monat} and {Year}/{Jahr} in a title template.
public func expandTitle(_ template: String, month: Int, year: Int, lang: Language) -> String {
    let m = Strings.of(lang).months[month]
    return template
        .replacingOccurrences(of: "{Month}", with: m)
        .replacingOccurrences(of: "{Monat}", with: m)
        .replacingOccurrences(of: "{Year}", with: String(year))
        .replacingOccurrences(of: "{Jahr}", with: String(year))
}
