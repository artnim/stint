import CoreGraphics
import CoreText
import Foundation

enum PDFStyles {
    static let mm: CGFloat = 72.0 / 25.4
    static let pageSize = CGSize(width: 595.2756, height: 841.8898)   // A4
    static let marginL: CGFloat = 18 * mm
    static let marginR: CGFloat = 18 * mm
    static let marginTop: CGFloat = 16 * mm
    static let marginBottom: CGFloat = 20 * mm
    static var avail: CGFloat { pageSize.width - marginL - marginR }

    static func color(_ hex: UInt32) -> CGColor {
        CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
    static let ink = color(0x1c1c1e)
    static let muted = color(0x6b6b70)
    static let rule = color(0xd8d8dc)
    static let band = color(0xf4f4f6)
    static let dayBG = color(0xe8eaef)

    static let colTime: CGFloat = 24 * mm
    static let colIssue: CGFloat = 15 * mm
    static let colTags: CGFloat = 30 * mm
    static let colDuration: CGFloat = 18 * mm
    static let padH: CGFloat = 4
    static let padV: CGFloat = 3
}

struct TextStyle {
    var bold: Bool
    var size: CGFloat
    var leading: CGFloat
    var color: CGColor
    var right: Bool = false

    static let cell = TextStyle(bold: false, size: 8.5, leading: 10.5, color: PDFStyles.ink)
    static let cellMuted = TextStyle(bold: false, size: 7.5, leading: 9.5, color: PDFStyles.muted)
    static let head = TextStyle(bold: true, size: 7.5, leading: 9, color: PDFStyles.muted)
    static let headRight = TextStyle(bold: true, size: 7.5, leading: 9, color: PDFStyles.muted, right: true)
    static let day = TextStyle(bold: true, size: 8.5, leading: 11, color: PDFStyles.ink)
    static let dayRight = TextStyle(bold: true, size: 8.5, leading: 11, color: PDFStyles.ink, right: true)
    static let num = TextStyle(bold: false, size: 8.5, leading: 10.5, color: PDFStyles.ink, right: true)
    static let title = TextStyle(bold: true, size: 17, leading: 20, color: PDFStyles.ink)
    static let metaKey = TextStyle(bold: false, size: 8.5, leading: 12, color: PDFStyles.muted)
    static let metaValue = TextStyle(bold: true, size: 8.5, leading: 12, color: PDFStyles.ink)
    static let big = TextStyle(bold: true, size: 15, leading: 17, color: PDFStyles.ink, right: true)
    static let bigKey = TextStyle(bold: false, size: 8, leading: 10, color: PDFStyles.muted, right: true)
    static let section = TextStyle(bold: true, size: 10, leading: 13, color: PDFStyles.ink)
    static let footer = TextStyle(bold: false, size: 7.5, leading: 9, color: PDFStyles.muted)

    /// Plain Core Text attributes, so the same renderer runs on macOS and iOS.
    func attributed(_ s: String) -> NSAttributedString {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        var alignment: CTTextAlignment = right ? .right : .left
        var lineHeight = leading
        let para = withUnsafeBytes(of: &alignment) { a in
            withUnsafeBytes(of: &lineHeight) { h in
                let settings = [
                    CTParagraphStyleSetting(spec: .alignment, valueSize: a.count, value: a.baseAddress!),
                    CTParagraphStyleSetting(spec: .minimumLineHeight, valueSize: h.count, value: h.baseAddress!),
                    CTParagraphStyleSetting(spec: .maximumLineHeight, valueSize: h.count, value: h.baseAddress!),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        return NSAttributedString(string: s, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): para,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
    }
}

/// Measured, drawable block of text.
struct TextBlock {
    let attributed: NSAttributedString
    let width: CGFloat
    let height: CGFloat

    init(_ s: String, _ style: TextStyle, width: CGFloat) {
        attributed = style.attributed(s)
        self.width = width
        if s.isEmpty {
            height = 0
        } else {
            let fs = CTFramesetterCreateWithAttributedString(attributed)
            let size = CTFramesetterSuggestFrameSizeWithConstraints(
                fs, CFRange(location: 0, length: 0), nil,
                CGSize(width: width, height: .greatestFiniteMagnitude), nil)
            height = ceil(size.height)
        }
    }

    /// `top` is a top-based y; converted to CG coordinates here.
    func draw(in ctx: CGContext, x: CGFloat, top: CGFloat) {
        guard height > 0 else { return }
        let rect = CGRect(x: x, y: PDFStyles.pageSize.height - top - height, width: width, height: height + 2)
        let fs = CTFramesetterCreateWithAttributedString(attributed)
        let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        ctx.saveGState()
        ctx.textMatrix = .identity
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }
}
