import Foundation

@MainActor
final class TranscriptionLabController: ObservableObject {
    typealias EntryLoader = () throws -> [TranscriptionLabEntry]
    typealias ExperimentRunner = (
        _ entry: TranscriptionLabEntry,
        _ speechModelID: String,
        _ cleanupModelKind: LocalCleanupModelKind,
        _ prompt: String
    ) async throws -> TranscriptionLabRunResult

    @Published private(set) var entries: [TranscriptionLabEntry] = []
    @Published var selectedEntryID: UUID?
    @Published var selectedSpeechModelID: String
    @Published var selectedCleanupModelKind: LocalCleanupModelKind
    @Published private(set) var experimentRawTranscription: String = ""
    @Published private(set) var experimentCorrectedTranscription: String = ""
    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?

    private let loadEntries: EntryLoader
    private let runExperiment: ExperimentRunner

    init(
        defaultSpeechModelID: String,
        defaultCleanupModelKind: LocalCleanupModelKind = .full,
        loadEntries: @escaping EntryLoader,
        runExperiment: @escaping ExperimentRunner
    ) {
        self.selectedSpeechModelID = defaultSpeechModelID
        self.selectedCleanupModelKind = defaultCleanupModelKind
        self.loadEntries = loadEntries
        self.runExperiment = runExperiment
    }

    var selectedEntry: TranscriptionLabEntry? {
        guard let selectedEntryID else {
            return nil
        }

        return entries.first { $0.id == selectedEntryID }
    }

    func reloadEntries() {
        do {
            let loadedEntries = try loadEntries().sorted { $0.createdAt > $1.createdAt }
            entries = loadedEntries

            if let selectedEntryID,
               loadedEntries.contains(where: { $0.id == selectedEntryID }) {
                return
            }

            if let newestEntry = loadedEntries.first {
                selectEntry(newestEntry.id)
            } else {
                selectedEntryID = nil
                experimentRawTranscription = ""
                experimentCorrectedTranscription = ""
                errorMessage = nil
            }
        } catch {
            entries = []
            selectedEntryID = nil
            experimentRawTranscription = ""
            experimentCorrectedTranscription = ""
            errorMessage = "Could not load saved recordings."
        }
    }

    func selectEntry(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else {
            return
        }

        selectedEntryID = id
        selectedSpeechModelID = SpeechModelCatalog.model(named: entry.speechModelID)?.name ?? selectedSpeechModelID
        selectedCleanupModelKind = Self.cleanupModelKind(for: entry)
        experimentRawTranscription = ""
        experimentCorrectedTranscription = ""
        errorMessage = nil
    }

    func rerun(prompt: String) async {
        guard let entry = selectedEntry else {
            errorMessage = "Choose a saved recording first."
            return
        }

        isRunning = true
        errorMessage = nil

        do {
            let result = try await runExperiment(
                entry,
                selectedSpeechModelID,
                selectedCleanupModelKind,
                prompt
            )
            experimentRawTranscription = result.rawTranscription
            experimentCorrectedTranscription = result.correctedTranscription
        } catch let error as TranscriptionLabRunnerError {
            switch error {
            case .pipelineBusy:
                errorMessage = "Ghost Pepper is busy with another recording or lab run."
            case .missingAudio:
                errorMessage = "This saved recording no longer has playable audio."
            case .transcriptionFailed:
                errorMessage = "That model could not produce a transcription for this recording."
            }
        } catch {
            errorMessage = "The lab rerun failed."
        }

        isRunning = false
    }

    private static func cleanupModelKind(for entry: TranscriptionLabEntry) -> LocalCleanupModelKind {
        if entry.cleanupModelName.contains("1.7B") {
            return .fast
        }

        return .full
    }
}
