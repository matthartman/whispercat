import XCTest
@testable import GhostPepper

final class AudioRecorderTests: XCTestCase {
    func testBufferStartsEmpty() {
        let recorder = AudioRecorder()
        XCTAssertTrue(recorder.audioBuffer.isEmpty)
    }

    func testBufferClearsOnReset() {
        let recorder = AudioRecorder()
        recorder.audioBuffer = [1.0, 2.0, 3.0]
        recorder.resetBuffer()
        XCTAssertTrue(recorder.audioBuffer.isEmpty)
    }
}
