import Foundation

struct TranscriptionLabStageTimings: Codable, Equatable {
    let transcriptionDuration: TimeInterval?
    let cleanupDuration: TimeInterval?
}

final class TranscriptionLabStore {
    private let directoryURL: URL
    private let maxEntries: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        directoryURL: URL? = nil,
        maxEntries: Int = 50
    ) {
        self.directoryURL = directoryURL ?? Self.defaultDirectoryURL
        self.maxEntries = maxEntries
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    func loadEntries() throws -> [TranscriptionLabEntry] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: indexURL)
            let entries = try decoder.decode([TranscriptionLabEntry].self, from: data)
            return entries.sorted { $0.createdAt > $1.createdAt }
        } catch {
            resetStoredArchive()
            return []
        }
    }

    func loadStageTimings() throws -> [UUID: TranscriptionLabStageTimings] {
        guard FileManager.default.fileExists(atPath: timingsURL.path) else {
            return [:]
        }

        do {
            let data = try Data(contentsOf: timingsURL)
            let encodedTimings = try decoder.decode([String: TranscriptionLabStageTimings].self, from: data)
            return Dictionary(uniqueKeysWithValues: encodedTimings.compactMap { key, value in
                guard let entryID = UUID(uuidString: key) else {
                    return nil
                }

                return (entryID, value)
            })
        } catch {
            resetStoredArchive()
            return [:]
        }
    }

    func insert(
        _ entry: TranscriptionLabEntry,
        audioData: Data,
        stageTimings: TranscriptionLabStageTimings
    ) throws {
        try FileManager.default.createDirectory(at: audioDirectoryURL, withIntermediateDirectories: true)
        try audioData.write(to: audioURL(for: entry.audioFileName), options: .atomic)

        var entries = try loadEntries()
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        entries.sort { $0.createdAt > $1.createdAt }
        var timings = try loadStageTimings()
        timings[entry.id] = stageTimings

        let prunedEntries = Array(entries.prefix(maxEntries))
        let prunedEntryIDs = Set(entries.dropFirst(maxEntries).map(\.id))
        let prunedFileNames = Set(entries.dropFirst(maxEntries).map(\.audioFileName))
        for fileName in prunedFileNames {
            try? FileManager.default.removeItem(at: audioURL(for: fileName))
        }
        for entryID in prunedEntryIDs {
            timings.removeValue(forKey: entryID)
        }

        let data = try encoder.encode(prunedEntries)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try data.write(to: indexURL, options: .atomic)

        let encodedTimings = Dictionary(uniqueKeysWithValues: timings.map { key, value in
            (key.uuidString, value)
        })
        let timingsData = try encoder.encode(encodedTimings)
        try timingsData.write(to: timingsURL, options: .atomic)
    }

    func deleteEntry(id: UUID) throws {
        var entries = try loadEntries()
        guard let entry = entries.first(where: { $0.id == id }) else { return }

        try? FileManager.default.removeItem(at: audioURL(for: entry.audioFileName))
        entries.removeAll { $0.id == id }

        var timings = try loadStageTimings()
        timings.removeValue(forKey: id)

        let data = try encoder.encode(entries)
        try data.write(to: indexURL, options: .atomic)

        let encodedTimings = Dictionary(uniqueKeysWithValues: timings.map { ($0.key.uuidString, $0.value) })
        let timingsData = try encoder.encode(encodedTimings)
        try timingsData.write(to: timingsURL, options: .atomic)
    }

    func deleteAllEntries() {
        resetStoredArchive()
    }

    func audioURL(for audioFileName: String) -> URL {
        audioDirectoryURL.appendingPathComponent(audioFileName)
    }

    private var indexURL: URL {
        directoryURL.appendingPathComponent("transcription-lab-index.json")
    }

    private var audioDirectoryURL: URL {
        directoryURL.appendingPathComponent("audio", isDirectory: true)
    }

    private var timingsURL: URL {
        directoryURL.appendingPathComponent("transcription-lab-timings.json")
    }

    private func resetStoredArchive() {
        try? FileManager.default.removeItem(at: indexURL)
        try? FileManager.default.removeItem(at: timingsURL)
        try? FileManager.default.removeItem(at: audioDirectoryURL)
    }

    private static var defaultDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("GhostPepper", isDirectory: true)
            .appendingPathComponent("transcription-lab", isDirectory: true)
    }
}
