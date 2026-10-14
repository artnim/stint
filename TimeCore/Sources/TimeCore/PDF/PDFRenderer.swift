#if os(macOS)
import CoreGraphics
import CoreText
import Foundation

public enum PDFRenderer {
    public static func render(_ report: Report) -> Data {
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data)!
        var mediaBox = CGRect(origin: .zero, size: PDFStyles.pageSize)
        let info: [CFString: Any] = [kCGPDFContextTitle: report.title, kCGPDFContextAuthor: report.meta.user]
        let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary)!
        let writer = PageWriter(ctx: ctx, report: report)
        writer.beginPage()
        writer.drawTitleBlock()
        writer.drawTable()
        if report.options.summary && !report.tagSummary.isEmpty {
            writer.drawTagSummary()
        }
        writer.endPage()
        ctx.closePDF()
        return data as Data
    }
}

/// One table row: a text block per column; `spanFirst` merges all but the last column into the first.
private struct Row {
    var cells: [TextBlock]
    var spanFirst = false
    var background: CGColor? = nil
    var padV: CGFloat = PDFStyles.padV
    var lineAbove: (CGFloat, CGColor)? = nil
    var lineBelow: (CGFloat, CGColor)? = nil

    var height: CGFloat { (cells.map(\.height).max() ?? 0) + 2 * padV }
}

private final class PageWriter {
    let ctx: CGContext
    let r: Report
    let t: Strings
    let widths: [CGFloat]
    let hm: DateFormatter
    var y: CGFloat = PDFStyles.marginTop
    var page = 0

    private var limit: CGFloat { PDFStyles.pageSize.height - PDFStyles.marginBottom }
    private var pageH: CGFloat { PDFStyles.pageSize.height }
    private var x0: CGFloat { PDFStyles.marginL }

    init(ctx: CGContext, report: Report) {
        self.ctx = ctx
        self.r = report
        self.t = report.strings
        var w: [CGFloat] = report.columns.map { c in
            switch c {
            case .time: return PDFStyles.colTime
            case .issue: return PDFStyles.colIssue
            case .tags: return PDFStyles.colTags
            case .duration: return PDFStyles.colDuration
            case .description: return 0
            }
        }
        let descIndex = report.columns.firstIndex(of: .description)!
        w[descIndex] = PDFStyles.avail - w.reduce(0, +)
        widths = w
        hm = DateFormatter()
        hm.calendar = report.calendar
        hm.timeZone = report.calendar.timeZone
        hm.locale = Locale(identifier: "en_US_POSIX")
        hm.dateFormat = "HH:mm"
    }

    // MARK: pages

    func beginPage() {
        page += 1
        ctx.beginPDFPage(nil)
        y = PDFStyles.marginTop
        drawFooter()
    }

    func endPage() { ctx.endPDFPage() }

    private func newPage(repeatHeader: Bool) {
        endPage()
        beginPage()
        if repeatHeader { drawRow(headerRow()) }
    }

    private func ensure(_ h: CGFloat, repeatHeader: Bool) {
        if y + h > limit { newPage(repeatHeader: repeatHeader) }
    }

    private func drawFooter() {
        let line = CTLineCreateWithAttributedString(
            TextStyle.footer.attributed("\(r.meta.client) · \(r.meta.project) · \(r.meta.period)"))
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: x0, y: 12 * PDFStyles.mm)
        CTLineDraw(line, ctx)
        let num = CTLineCreateWithAttributedString(TextStyle.footer.attributed("\(page)"))
        let w = CTLineGetTypographicBounds(num, nil, nil, nil)
        ctx.textPosition = CGPoint(x: PDFStyles.pageSize.width - PDFStyles.marginR - CGFloat(w), y: 12 * PDFStyles.mm)
        CTLineDraw(num, ctx)
        ctx.restoreGState()
        hline(at: pageH - 15 * PDFStyles.mm, width: 0.4, color: PDFStyles.rule)
    }

    /// Horizontal rule across the body; `cgY` is in CG coordinates.
    private func hline(at cgY: CGFloat, width: CGFloat, color: CGColor, from xa: CGFloat? = nil, to xb: CGFloat? = nil) {
        ctx.saveGState()
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.move(to: CGPoint(x: xa ?? x0, y: cgY))
        ctx.addLine(to: CGPoint(x: xb ?? (x0 + PDFStyles.avail), y: cgY))
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: title block

    func drawTitleBlock() {
        let title = TextBlock(r.title, .title, width: PDFStyles.avail)
        title.draw(in: ctx, x: x0, top: y)
        y += title.height + 5
        hline(at: pageH - y, width: 0.8, color: PDFStyles.rule)
        y += 1 + 7

        // left: meta key/value table, 45 % of the width, key column 22 mm
        let leftW = PDFStyles.avail * 0.45
        let keyW = 22 * PDFStyles.mm
        let pairs = [(t.client, r.meta.client), (t.project, r.meta.project), (t.user, r.meta.user), (t.period, r.meta.period)]
        var ly = y
        for (k, v) in pairs {
            let kb = TextBlock(k, .metaKey, width: keyW)
            let vb = TextBlock(v, .metaValue, width: leftW - keyW)
            let h = max(kb.height, vb.height) + 2
            kb.draw(in: ctx, x: x0, top: ly + 1)
            vb.draw(in: ctx, x: x0 + keyW, top: ly + 1)
            ly += h
        }

        // right: big total and counts, right-aligned in the remaining 55 %
        let rightX = x0 + leftW
        let rightW = PDFStyles.avail * 0.55
        let big = TextBlock(fmtHours(r.totalHours, r.options.language), .big, width: rightW)
        big.draw(in: ctx, x: rightX, top: y)
        let counts = TextBlock("\(r.days.count) \(t.days) · \(r.entryCount) \(t.entries)", .bigKey, width: rightW)
        counts.draw(in: ctx, x: rightX, top: y + big.height)

        y = max(ly, y + big.height + counts.height) + 10
    }

    // MARK: table

    private func cellWidth(_ i: Int, span: Bool) -> CGFloat {
        let w = span ? widths.dropLast().reduce(0, +) : widths[i]
        return w - 2 * PDFStyles.padH
    }

    private func headerRow() -> Row {
        let cells = r.columns.enumerated().map { i, c -> TextBlock in
            let label: String
            switch c {
            case .time: label = t.time
            case .issue: label = t.issue
            case .description: label = t.description
            case .tags: label = t.tags
            case .duration: label = t.duration
            }
            return TextBlock(label, c == .duration ? .headRight : .head, width: cellWidth(i, span: false))
        }
        return Row(cells: cells, lineBelow: (0.6, PDFStyles.muted))
    }

    private func spannedRow(label: String, hours: Double, style: TextStyle, rightStyle: TextStyle,
                            background: CGColor?, padV: CGFloat, lineAbove: (CGFloat, CGColor)?) -> Row {
        let last = widths.count - 1
        var cells: [TextBlock] = [TextBlock(label, style, width: cellWidth(0, span: true))]
        for _ in 1..<last { cells.append(TextBlock("", .cell, width: 0)) }
        cells.append(TextBlock(fmtHours(hours, r.options.language), rightStyle, width: cellWidth(last, span: false)))
        return Row(cells: cells, spanFirst: true, background: background, padV: padV, lineAbove: lineAbove)
    }

    private func entryRow(_ e: ReportEntry, banded: Bool) -> Row {
        let o = r.options
        let cells = r.columns.enumerated().map { i, c -> TextBlock in
            let w = cellWidth(i, span: false)
            switch c {
            case .time: return TextBlock("\(hm.string(from: e.start)) – \(hm.string(from: e.end))", .cell, width: w)
            case .issue: return TextBlock(e.issue, .cell, width: w)
            case .description: return TextBlock(e.description.isEmpty ? "—" : e.description, .cell, width: w)
            case .tags: return TextBlock(shortTags(e.tags, maxTags: o.maxTags, maxChars: o.tagChars), .cellMuted, width: w)
            case .duration: return TextBlock(fmtHours(e.hours, o.language), .num, width: w)
            }
        }
        return Row(cells: cells, background: banded ? PDFStyles.band : nil)
    }

    private func drawRow(_ row: Row) {
        let h = row.height
        let top = pageH - y
        if let bg = row.background {
            ctx.saveGState()
            ctx.setFillColor(bg)
            ctx.fill(CGRect(x: x0, y: top - h, width: PDFStyles.avail, height: h))
            ctx.restoreGState()
        }
        if let (w, c) = row.lineAbove { hline(at: top, width: w, color: c) }
        var x = x0
        for (i, cell) in row.cells.enumerated() {
            if row.spanFirst && i > 0 && i < row.cells.count - 1 { continue }   // covered by the span
            cell.draw(in: ctx, x: x + PDFStyles.padH, top: y + row.padV)
            x += (row.spanFirst && i == 0) ? widths.dropLast().reduce(0, +) : widths[i]
        }
        if let (w, c) = row.lineBelow { hline(at: top - h, width: w, color: c) }
        y += h
    }

    func drawTable() {
        let header = headerRow()
        ensure(header.height + 30, repeatHeader: false)
        drawRow(header)
        for day in r.days {
            let dayRow = spannedRow(label: day.label, hours: day.totalHours, style: .day, rightStyle: .dayRight,
                                    background: PDFStyles.dayBG, padV: 5, lineAbove: nil)
            ensure(dayRow.height, repeatHeader: true)
            drawRow(dayRow)
            for (i, e) in day.entries.enumerated() {
                let row = entryRow(e, banded: i % 2 == 1)
                ensure(row.height, repeatHeader: true)
                drawRow(row)
            }
        }
        let total = spannedRow(label: t.total, hours: r.totalHours, style: .day, rightStyle: .dayRight,
                               background: nil, padV: 6, lineAbove: (0.9, PDFStyles.ink))
        ensure(total.height, repeatHeader: true)
        drawRow(total)
    }

    // MARK: summary

    func drawTagSummary() {
        let heading = TextBlock(t.summaryTags, .section, width: PDFStyles.avail)
        let nameW = PDFStyles.avail - 25 * PDFStyles.mm
        let rows = r.tagSummary.enumerated().map { i, s -> Row in
            Row(cells: [TextBlock(s.name, .cell, width: nameW - 2 * PDFStyles.padH),
                        TextBlock(fmtHours(s.hours, r.options.language), .num, width: 25 * PDFStyles.mm - 2 * PDFStyles.padH)],
                lineBelow: i < r.tagSummary.count - 1 ? (0.3, PDFStyles.rule) : nil)
        }
        let block = 10 + heading.height + 4 + rows.reduce(0) { $0 + $1.height }
        if y + block > limit && block < limit - PDFStyles.marginTop { newPage(repeatHeader: false) }
        y += 10
        heading.draw(in: ctx, x: x0, top: y)
        y += heading.height + 4
        for row in rows {
            ensure(row.height, repeatHeader: false)
            // two-column layout: draw by hand instead of the table widths
            let top = pageH - y
            row.cells[0].draw(in: ctx, x: x0 + PDFStyles.padH, top: y + row.padV)
            row.cells[1].draw(in: ctx, x: x0 + nameW + PDFStyles.padH, top: y + row.padV)
            if let (w, c) = row.lineBelow { hline(at: top - row.height, width: w, color: c) }
            y += row.height
        }
    }
}
#endif
