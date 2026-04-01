import XCTest
@testable import MacGuard

final class StringEscapingTests: XCTestCase {
    func testBasicEscaping() {
        let input = "filename.txt"
        let expected = "filename.txt"
        XCTAssertEqual(input.esc, expected)
    }

    func testApostropheEscaping() {
        let input = "file'name.txt"
        let expected = "file'\\''name.txt"
        XCTAssertEqual(input.esc, expected)
    }
    
    func testMultipleApostrophes() {
        let input = "O'Connor's File.doc"
        let expected = "O'\\''Connor'\\''s File.doc"
        XCTAssertEqual(input.esc, expected)
    }
}
