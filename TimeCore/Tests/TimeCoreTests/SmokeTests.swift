import XCTest
@testable import TimeCore

final class SmokeTests: XCTestCase {
    func testVersionIsSet() {
        XCTAssertEqual(TimeCore.version, "0.1.0")
    }
}
