import XCTest
@testable import GhostPepper

@MainActor
final class TranscriptionLabControllerTests: XCTestCase {
    func testReloadEntriesSelectsNewestEntryAndSeedsExperimentDefaults() {
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
            runExperiment: { _, _, _, _ in
                XCTFail("should not rerun during reload")
                return TranscriptionLabRunResult(
                    rawTranscription: "",
                    correctedTranscription: "",
                    cleanupUsedFallback: false
                )
            }
        )

        controller.reloadEntries()

        XCTAssertEqual(controller.entries.map(\.id), [newerEntry.id, olderEntry.id])
        XCTAssertEqual(controller.selectedEntryID, newerEntry.id)
        XCTAssertEqual(controller.selectedSpeechModelID, "fluid_parakeet-v3")
        XCTAssertEqual(controller.selectedCleanupModelKind, .full)
    }

    func testRerunUpdatesExperimentOutputs() async {
        let entry = makeEntry(
            createdAt: Date(),
            speechModelID: "openai_whisper-small.en",
            cleanupModelName: "Qwen 3 1.7B (fast cleanup)"
        )
        var executedPrompt: String?
        var executedSpeechModelID: String?
        var executedCleanupModelKind: LocalCleanupModelKind?
        let controller = TranscriptionLabController(
            defaultSpeechModelID: SpeechModelCatalog.defaultModelID,
            loadEntries: { [entry] },
            runExperiment: { rerunEntry, speechModelID, cleanupModelKind, prompt in
                XCTAssertEqual(rerunEntry.id, entry.id)
                executedPrompt = prompt
                executedSpeechModelID = speechModelID
                executedCleanupModelKind = cleanupModelKind
                return TranscriptionLabRunResult(
                    rawTranscription: "raw rerun",
                    correctedTranscription: "clean rerun",
                    cleanupUsedFallback: false
                )
            }
        )
        controller.reloadEntries()
        controller.selectedSpeechModelID = "fluid_parakeet-v3"
        controller.selectedCleanupModelKind = .full

        await controller.rerun(prompt: "custom prompt")

        XCTAssertEqual(executedPrompt, "custom prompt")
        XCTAssertEqual(executedSpeechModelID, "fluid_parakeet-v3")
        XCTAssertEqual(executedCleanupModelKind, .full)
        XCTAssertEqual(controller.experimentRawTranscription, "raw rerun")
        XCTAssertEqual(controller.experimentCorrectedTranscription, "clean rerun")
        XCTAssertNil(controller.errorMessage)
        XCTAssertFalse(controller.isRunning)
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
