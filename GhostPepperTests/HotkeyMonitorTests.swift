import XCTest
@testable import GhostPepper

final class HotkeyMonitorTests: XCTestCase {
    func testControlOnlyDetection() {
        let controlOnly: CGEventFlags = .maskControl
        XCTAssertTrue(HotkeyMonitor.isControlOnly(flags: controlOnly))
    }

    func testControlWithOtherModifierRejected() {
        let controlCmd: CGEventFlags = [.maskControl, .maskCommand]
        XCTAssertFalse(HotkeyMonitor.isControlOnly(flags: controlCmd))
    }

    func testNoControlRejected() {
        let noFlags: CGEventFlags = []
        XCTAssertFalse(HotkeyMonitor.isControlOnly(flags: noFlags))
    }

    func testMinimumHoldDuration() {
        let monitor = HotkeyMonitor()
        XCTAssertFalse(monitor.isHoldLongEnough(duration: 0.2))
        XCTAssertTrue(monitor.isHoldLongEnough(duration: 0.4))
    }
}
