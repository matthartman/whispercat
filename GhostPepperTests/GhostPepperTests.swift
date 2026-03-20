import XCTest
@testable import GhostPepper

final class GhostPepperTests: XCTestCase {
    func testAppStateInitialStatus() {
        // AppState is @MainActor so we test basic enum
        XCTAssertEqual(AppStatus.ready.rawValue, "Ready")
        XCTAssertEqual(AppStatus.recording.rawValue, "Recording...")
        XCTAssertEqual(AppStatus.transcribing.rawValue, "Transcribing...")
        XCTAssertEqual(AppStatus.error.rawValue, "Error")
    }
}
