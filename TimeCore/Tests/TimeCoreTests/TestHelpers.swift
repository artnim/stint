import Foundation
@testable import TimeCore

let berlin: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/Berlin")!
    c.locale = Locale(identifier: "en_US_POSIX")
    return c
}()

/// "2026-08-03 13:09:00" in Europe/Berlin -> Date
func local(_ s: String) -> Date {
    let f = DateFormatter()
    f.calendar = berlin
    f.timeZone = berlin.timeZone
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = s.count == 16 ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd HH:mm:ss"
    return f.date(from: s)!
}

func hhmm(_ d: Date) -> String {
    let f = DateFormatter()
    f.timeZone = berlin.timeZone
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "HH:mm"
    return f.string(from: d)
}
