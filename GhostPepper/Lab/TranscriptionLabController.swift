import Foundation

@MainActor
final class TranscriptionLabController: ObservableObject {
    typealias StageTimingsLoader = () throws -> [UUID: TranscriptionLabStageTimings]
    typealias EntryLoader = () throws -> [TranscriptionLabEntry]
    typealias AudioURLProvider = (TranscriptionLabEntry) -> URL
    typealias TranscriptionRunner = (
        _ entry: TranscriptionLabEntry,
        _ speechModelID: String
    ) async throws -> String
    typealias CleanupRunner = (
        _ entry: TranscriptionLabEntry,
        _ rawTranscription: String,
        _ cleanupModelKind: LocalCleanupModelKind,
        _ prompt: String,
        _ includeWindowContext: Bool
    ) async throws -> TranscriptionLabCleanupResult

    enum RunningStage {
        case transcription
        case cleanup
    }

    @Published private(set) var entries: [TranscriptionLabEntry] = []
    @Published var selectedEntryID: UUID?
    @Published var selectedSpeechModelID: String
    @Published var selectedCleanupModelKind: LocalCleanupModelKind
    @Published var usesCapturedOCR = true
    @Published private(set) var experimentRawTranscription: String = ""
    @Published private(set) var experimentCorrectedTranscription: String = ""
    @Published private(set) var experimentTranscriptionDuration: TimeInterval?
    @Published private(set) var experimentCleanupDuration: TimeInterval?
    @Published private(set) var latestCleanupTranscript: TranscriptionLabCleanupTranscript?
    @Published private(set) var runningStage: RunningStage?
    @Published private(set) var errorMessage: String?

    private let loadStageTimings: StageTimingsLoader
    private let loadEntries: EntryLoader
    private let audioURLForEntry: AudioURLProvider
    private let runTranscription: TranscriptionRunner
    private let runCleanup: CleanupRunner
    private var originalStageTimingsByEntryID: [UUID: TranscriptionLabStageTimings] = [:]

    init(
        defaultSpeechModelID: String,
        defaultCleanupModelKind: LocalCleanupModelKind = .full,
        loadStageTimings: @escaping StageTimingsLoader = { [:] },
        loadEntries: @escaping EntryLoader,
        audioURLForEntry: @escaping AudioURLProvider,
        runTranscription: @escaping TranscriptionRunner,
        runCleanup: @escaping CleanupRunner
    ) {
        self.selectedSpeechModelID = defaultSpeechModelID
        self.selectedCleanupModelKind = defaultCleanupModelKind
        self.loadStageTimings = loadStageTimings
        self.loadEntries = loadEntries
        self.audioURLForEntry = audioURLForEntry
        self.runTranscription = runTranscription
        self.runCleanup = runCleanup
    }

    var selectedEntry: TranscriptionLabEntry? {
        guard let selectedEntryID else {
            return nil
        }

        return entries.first { $0.id == selectedEntryID }
    }

    var isRunningTranscription: Bool {
        runningStage == .transcription
    }

    var isRunningCleanup: Bool {
        runningStage == .cleanup
    }

    var activeRawTranscriptionForCleanup: String {
        if !experimentRawTranscription.isEmpty {
            return experimentRawTranscription
        }

        return selectedEntry?.rawTranscription ?? ""
    }

    var displayedExperimentRawTranscription: String {
        if !experimentRawTranscription.isEmpty {
            return experimentRawTranscription
        }

        return selectedEntry?.rawTranscription ?? ""
    }

    var displayedExperimentCorrectedTranscription: String {
        if !experimentCorrectedTranscription.isEmpty {
            return experimentCorrectedTranscription
        }

        return selectedEntry?.correctedTranscription ?? ""
    }

    var originalTranscriptionDuration: TimeInterval? {
        guard let selectedEntryID else {
            return nil
        }

        return originalStageTimingsByEntryID[selectedEntryID]?.transcriptionDuration
    }

    var originalCleanupDuration: TimeInterval? {
        guard let selectedEntryID else {
            return nil
        }

        return originalStageTimingsByEntryID[selectedEntryID]?.cleanupDuration
    }

    func audioURL(for entry: TranscriptionLabEntry) -> URL {
        audioURLForEntry(entry)
    }

    func reloadEntries() {
        do {
            let loadedEntries = try loadEntries().sorted { $0.createdAt > $1.createdAt }
            originalStageTimingsByEntryID = try loadStageTimings()
            entries = loadedEntries

            if let selectedEntryID,
               loadedEntries.contains(where: { $0.id == selectedEntryID }) {
                return
            }

            selectedEntryID = nil
            usesCapturedOCR = true
            experimentRawTranscription = ""
            experimentCorrectedTranscription = ""
            experimentTranscriptionDuration = nil
            experimentCleanupDuration = nil
            latestCleanupTranscript = nil
            errorMessage = nil
        } catch {
            entries = []
            selectedEntryID = nil
            usesCapturedOCR = true
            experimentRawTranscription = ""
            experimentCorrectedTranscription = ""
            experimentTranscriptionDuration = nil
            experimentCleanupDuration = nil
            latestCleanupTranscript = nil
            originalStageTimingsByEntryID = [:]
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
        usesCapturedOCR = entry.windowContext != nil
        experimentRawTranscription = ""
        experimentCorrectedTranscription = ""
        experimentTranscriptionDuration = nil
        experimentCleanupDuration = nil
        latestCleanupTranscript = nil
        errorMessage = nil
    }

    func closeDetail() {
        selectedEntryID = nil
        usesCapturedOCR = true
        experimentRawTranscription = ""
        experimentCorrectedTranscription = ""
        experimentTranscriptionDuration = nil
        experimentCleanupDuration = nil
        latestCleanupTranscript = nil
        errorMessage = nil
    }

    func rerunTranscription() async {
        guard let entry = selectedEntry else {
            errorMessage = "Choose a saved recording first."
            return
        }

        runningStage = .transcription
        errorMessage = nil
        experimentTranscriptionDuration = nil
        latestCleanupTranscript = nil
        let start = Date()

        do {
            experimentRawTranscription = try await runTranscription(entry, selectedSpeechModelID)
            experimentCorrectedTranscription = ""
            experimentTranscriptionDuration = Date().timeIntervalSince(start)
            experimentCleanupDuration = nil
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

        runningStage = nil
    }

    func rerunCleanup(prompt: String) async {
        guard let entry = selectedEntry else {
            errorMessage = "Choose a saved recording first."
            return
        }

        let rawTranscription = activeRawTranscriptionForCleanup
        guard !rawTranscription.isEmpty else {
            errorMessage = "Run transcription first or choose a recording with a raw transcription."
            return
        }

        runningStage = .cleanup
        errorMessage = nil
        experimentCleanupDuration = nil
        latestCleanupTranscript = nil
        let start = Date()

        do {
            let result = try await runCleanup(
                entry,
                rawTranscription,
                selectedCleanupModelKind,
                prompt,
                usesCapturedOCR
            )
            experimentCorrectedTranscription = result.correctedTranscription
            experimentCleanupDuration = Date().timeIntervalSince(start)
            latestCleanupTranscript = result.transcript
        } catch let error as TranscriptionLabRunnerError {
            switch error {
            case .pipelineBusy:
                errorMessage = "Ghost Pepper is busy with another recording or lab run."
            case .missingAudio:
                errorMessage = "This saved recording no longer has playable audio."
            case .transcriptionFailed:
                errorMessage = "Ghost Pepper could not produce input for cleanup."
            }
        } catch {
            errorMessage = "The cleanup rerun failed."
        }

        runningStage = nil
    }

    private static func cleanupModelKind(for entry: TranscriptionLabEntry) -> LocalCleanupModelKind {
        if entry.cleanupModelName.contains("1.7B") {
            return .fast
        }

        return .full
    }
}
