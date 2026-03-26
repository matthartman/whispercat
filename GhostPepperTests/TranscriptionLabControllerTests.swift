import XCTest
@testable import GhostPepper

@MainActor
final class TranscriptionLabControllerTests: XCTestCase {
    func testReloadEntriesSortsEntriesButStartsInBrowserMode() {
        let olderEntry = makeEntry(
            createdAt: Date(timeIntervalSince1970: 10),
            speechModelID: "openai_whisper-small.en",
            cleanupModelName: "Qwen 3 1.7B (fast cleanup)"
        )
        let newerEntry = makeEntry(
            createdAt: Date(timeIntervalSince1970: 20),
            speechModelID: "fluid_parakeet-v3",
            cleanupModelName: "Qwen 3.5 4B (full cleanup)"
        )

        let controller = TranscriptionLabController(
            defaultSpeechModelID: SpeechModelCatalog.defaultModelID,
            loadEntries: { [olderEntry, newerEntry] },
            audioURLForEntry: { _ in URL(fileURLWithPath: "/tmp/sample.bin") },
            runTranscription: { _, _ in
                XCTFail("should not rerun during reload")
                return ""
            },
            runCleanup: { _, _, _, _ in
                XCTFail("should not rerun during reload")
                return TranscriptionLabCleanupResult(correctedTranscription: "", cleanupUsedFallback: false)
            }
        )

        controller.reloadEntries()

        XCTAssertEqual(controller.entries.map(\.id), [newerEntry.id, olderEntry.id])
        XCTAssertNil(controller.selectedEntryID)
        XCTAssertEqual(controller.selectedSpeechModelID, SpeechModelCatalog.defaultModelID)
        XCTAssertEqual(controller.selectedCleanupModelKind, .full)
    }

    func testStageRerunsUpdateExperimentOutputs() async {
        let entry = makeEntry(
            createdAt: Date(),
            speechModelID: "openai_whisper-small.en",
            cleanupModelName: "Qwen 3 1.7B (fast cleanup)"
        )
        var executedCleanupPrompt: String?
        var executedSpeechModelID: String?
        var executedCleanupModelKind: LocalCleanupModelKind?
        var cleanupInputText: String?
        let controller = TranscriptionLabController(
            defaultSpeechModelID: SpeechModelCatalog.defaultModelID,
            loadEntries: { [entry] },
            audioURLForEntry: { _ in URL(fileURLWithPath: "/tmp/sample.bin") },
            runTranscription: { rerunEntry, speechModelID in
                XCTAssertEqual(rerunEntry.id, entry.id)
                executedSpeechModelID = speechModelID
                return "raw rerun"
            },
            runCleanup: { rerunEntry, rawText, cleanupModelKind, prompt in
                XCTAssertEqual(rerunEntry.id, entry.id)
                cleanupInputText = rawText
                executedCleanupPrompt = prompt
                executedCleanupModelKind = cleanupModelKind
                return TranscriptionLabCleanupResult(correctedTranscription: "clean rerun", cleanupUsedFallback: false)
            }
        )
        controller.reloadEntries()
        controller.selectEntry(entry.id)
        controller.selectedSpeechModelID = "fluid_parakeet-v3"
        controller.selectedCleanupModelKind = .full

        await controller.rerunTranscription()
        await controller.rerunCleanup(prompt: "custom prompt")

        XCTAssertEqual(executedSpeechModelID, "fluid_parakeet-v3")
        XCTAssertEqual(cleanupInputText, "raw rerun")
        XCTAssertEqual(executedCleanupPrompt, "custom prompt")
        XCTAssertEqual(executedCleanupModelKind, .full)
        XCTAssertEqual(controller.experimentRawTranscription, "raw rerun")
        XCTAssertEqual(controller.experimentCorrectedTranscription, "clean rerun")
        XCTAssertNil(controller.errorMessage)
        XCTAssertNil(controller.runningStage)
    }

    func testDisplayedExperimentOutputsDefaultToOriginalOutputs() {
        let entry = makeEntry(
            createdAt: Date(),
            speechModelID: "openai_whisper-small.en",
            cleanupModelName: "Qwen 3 1.7B (fast cleanup)"
        )
        let controller = TranscriptionLabController(
            defaultSpeechModelID: SpeechModelCatalog.defaultModelID,
            loadEntries: { [entry] },
            audioURLForEntry: { _ in URL(fileURLWithPath: "/tmp/sample.bin") },
            runTranscription: { _, _ in "" },
            runCleanup: { _, _, _, _ in
                TranscriptionLabCleanupResult(correctedTranscription: "", cleanupUsedFallback: false)
            }
        )

        controller.reloadEntries()
        controller.selectEntry(entry.id)

        XCTAssertEqual(controller.displayedExperimentRawTranscription, "raw")
        XCTAssertEqual(controller.displayedExperimentCorrectedTranscription, "corrected")
    }

    func testTranscriptionLabTextDiffMarksInsertedAndRemovedRuns() {
        let diff = TranscriptionLabTextDiff.segments(
            from: "the quick brown fox",
            to: "the slower brown fox"
        )

        XCTAssertEqual(
            diff,
            [
                .init(kind: .unchanged, text: "the"),
                .init(kind: .removed, text: "quick"),
                .init(kind: .inserted, text: "slower"),
                .init(kind: .unchanged, text: "brown fox")
            ]
        )
    }

    private func makeEntry(
        createdAt: Date,
        speechModelID: String,
        cleanupModelName: String
    ) -> TranscriptionLabEntry {
        TranscriptionLabEntry(
            id: UUID(),
            createdAt: createdAt,
            audioFileName: "sample.bin",
            audioDuration: 1.25,
            windowContext: OCRContext(windowContents: "Qwen 3.5 4B"),
            rawTranscription: "raw",
            correctedTranscription: "corrected",
            speechModelID: speechModelID,
            cleanupModelName: cleanupModelName,
            cleanupUsedFallback: false
        )
    }
}
