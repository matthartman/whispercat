import XCTest
@testable import GhostPepper

final class TextPasterTests: XCTestCase {
    func testSaveAndRestoreClipboard() {
        let paster = TextPaster()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("original content", forType: .string)

        let saved = paster.saveClipboard()
        XCTAssertNotNil(saved)

        pasteboard.clearContents()
        pasteboard.setString("new content", forType: .string)

        paster.restoreClipboard(saved!)
        XCTAssertEqual(pasteboard.string(forType: .string), "original content")
    }
}
