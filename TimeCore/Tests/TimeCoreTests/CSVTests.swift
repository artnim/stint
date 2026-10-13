import XCTest
@testable import TimeCore

final class CSVTests: XCTestCase {
    func testSimpleRows() {
        XCTAssertEqual(parseCSV("a,b,c\n1,2,3\n"), [["a", "b", "c"], ["1", "2", "3"]])
    }

    func testQuotesCommasNewlinesAndCRLF() {
        let text = "h1,h2\r\n\"x, y\",\"he said \"\"hi\"\"\"\r\n\"line1\nline2\",z\r\n"
        XCTAssertEqual(parseCSV(text), [["h1", "h2"], ["x, y", "he said \"hi\""], ["line1\nline2", "z"]])
    }

    func testEmptyFieldsAndTrailingComma() {
        XCTAssertEqual(parseCSV("a,,c,\n"), [["a", "", "c", ""]])
    }

    func testBOMIsStripped() {
        XCTAssertEqual(parseCSV("\u{FEFF}a,b\n"), [["a", "b"]])
    }

    func testBlankTrailingLinesIgnored() {
        XCTAssertEqual(parseCSV("a,b\n\n"), [["a", "b"]])
    }
}
