import Foundation

struct HistoryEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let createdAt: Date
    /// Captures transcription-pipeline completion, not paste completion.
    let completedAt: Date
    let rawTranscription: String
    let cleanedText: String?
    let speechModelID: String
    let cleanupBackend: String?
    let cleanupModelName: String?
    let cleanupAttempted: Bool
    let durationSeconds: TimeInterval
    let audioFileURL: String?

    init(
        id: UUID = UUID(),
        createdAt: Date,
        completedAt: Date,
        rawTranscription: String,
        cleanedText: String?,
        speechModelID: String,
        cleanupBackend: String?,
        cleanupModelName: String?,
        cleanupAttempted: Bool,
        durationSeconds: TimeInterval,
        audioFileURL: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.rawTranscription = rawTranscription
        self.cleanedText = cleanedText
        self.speechModelID = speechModelID
        self.cleanupBackend = cleanupBackend
        self.cleanupModelName = cleanupModelName
        self.cleanupAttempted = cleanupAttempted
        self.durationSeconds = durationSeconds
        self.audioFileURL = audioFileURL
    }
}
