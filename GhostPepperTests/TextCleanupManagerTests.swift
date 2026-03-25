import XCTest
@testable import GhostPepper

@MainActor
final class TextCleanupManagerTests: XCTestCase {
    func testCleanupModelDescriptorsUseQwenThreeFamilyModels() {
        XCTAssertEqual(
            TextCleanupManager.fastModel.displayName,
            "Qwen 3 1.7B (fast cleanup)"
        )
        XCTAssertEqual(
            TextCleanupManager.fastModel.fileName,
            "Qwen3-1.7B.Q4_K_M.gguf"
        )
        XCTAssertEqual(
            TextCleanupManager.fullModel.displayName,
            "Qwen 3.5 4B (full cleanup)"
        )
        XCTAssertEqual(
            TextCleanupManager.fullModel.fileName,
            "Qwen3.5-4B-Q4_K_M.gguf"
        )
    }

    func testAutomaticPolicyPrefersFastForShortInput() {
        let manager = TextCleanupManager(
            localModelPolicy: .automatic,
            fastModelAvailabilityOverride: true,
            fullModelAvailabilityOverride: true
        )

        XCTAssertEqual(
            manager.selectedModelKind(wordCount: 4, isQuestion: false),
            .fast
        )
    }

    func testFastOnlyPolicyAlwaysReturnsFastWhenReady() {
        let manager = TextCleanupManager(
            localModelPolicy: .fastOnly,
            fastModelAvailabilityOverride: true,
            fullModelAvailabilityOverride: true
        )

        XCTAssertEqual(
            manager.selectedModelKind(wordCount: 40, isQuestion: true),
            .fast
        )
    }

    func testFullOnlyPolicyAlwaysReturnsFullWhenReady() {
        let manager = TextCleanupManager(
            localModelPolicy: .fullOnly,
            fastModelAvailabilityOverride: true,
            fullModelAvailabilityOverride: true
        )

        XCTAssertEqual(
            manager.selectedModelKind(wordCount: 4, isQuestion: false),
            .full
        )
    }

    func testQuestionSelectionStillFlowsThroughManagerPolicy() {
        let manager = TextCleanupManager(
            localModelPolicy: .fastOnly,
            fastModelAvailabilityOverride: true,
            fullModelAvailabilityOverride: true
        )

        XCTAssertEqual(
            manager.selectedModelKind(wordCount: 3, isQuestion: true),
            .fast
        )
    }

    func testAutomaticPolicyTreatsFastModelAsUsableWhenFullModelIsUnavailable() {
        let manager = TextCleanupManager(
            localModelPolicy: .automatic,
            fastModelAvailabilityOverride: true,
            fullModelAvailabilityOverride: false
        )

        XCTAssertTrue(manager.hasUsableModelForCurrentPolicy)
    }

    func testFullOnlyPolicyRequiresFullModelToBeUsable() {
        let manager = TextCleanupManager(
            localModelPolicy: .fullOnly,
            fastModelAvailabilityOverride: true,
            fullModelAvailabilityOverride: false
        )

        XCTAssertFalse(manager.hasUsableModelForCurrentPolicy)
    }
}
