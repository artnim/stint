import Foundation

/// Minimal RFC 4180 parser: quoted fields, doubled quotes, embedded newlines, CRLF or LF.
public func parseCSV(_ input: String) -> [[String]] {
    var text = Substring(input)
    if text.hasPrefix("\u{FEFF}") { text = text.dropFirst() }
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var inQuotes = false
    var i = text.startIndex

    func endField() { row.append(field); field = "" }
    func endRow() { endField(); rows.append(row); row = [] }

    while i < text.endIndex {
        let ch = text[i]
        let next = text.index(after: i)
        if inQuotes {
            if ch == "\"" {
                if next < text.endIndex && text[next] == "\"" {
                    field.append("\""); i = text.index(after: next); continue
                }
                inQuotes = false
            } else {
                field.append(ch)
            }
        } else {
            switch ch {
            case "\"": inQuotes = true
            case ",": endField()
            case "\r": break
            case "\n", "\r\n": endRow()   // Swift folds CRLF into one Character
            default: field.append(ch)
            }
        }
        i = next
    }
    if !field.isEmpty || !row.isEmpty { endRow() }
    return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
}
