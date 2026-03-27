import XCTest
@testable import GhostPepper

private final class HistoryFeatureHotkeyMonitor: HotkeyMonitoring {
    var onRecordingStart: (() -> Void)?
    var onRecordingStop: (() -> Void)?
    var onRecordingRestart: (() -> Void)?
    var onPushToTalkStart: (() -> Void)?
    var onPushToTalkStop: (() -> Void)?
    var onToggleToTalkStart: (() -> Void)?
    var onToggleToTalkStop: (() -> Void)?

    func start() -> Bool { true }
    func stop() {}
    func updateBindings(_ bindings: [ChordAction: KeyChord]) {}
    func setSuspended(_ suspended: Bool) {}
}

@MainActor
final class HistoryFeatureTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "historyEnabled")
        UserDefaults.standard.removeObject(forKey: "historySaveRecordings")
        UserDefaults.standard.removeObject(forKey: "historyMaxEntries")
        super.tearDown()
    }

    func testHistoryEntryCodableRoundTripPreservesEquality() throws {
        let entry = makeEntry(
            rawTranscription: "raw text",
            cleanedText: "clean text",
            cleanupBackend: "localModels",
            cleanupModelName: "Qwen 3 1.7B (fast cleanup)",
            cleanupAttempted: true,
            audioFileURL: "audio/sample.wav"
        )

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(HistoryEntry.self, from: data)

        XCTAssertEqual(decoded, entry)
    }

    func testHistoryStorePersistsEntriesAcrossInstances() async throws {
        let urls = try makeHistoryURLs()

        do {
            let store = HistoryStore(
                maxEntries: 10,
                storageURL: urls.storageURL,
                audioDirectoryURL: urls.audioDirectoryURL
            )
            let entry = makeEntry(rawTranscription: "session complete")
            store.addEntry(entry)
            await store.flushPendingWrites()
        }

        let reloadedStore = HistoryStore(
            maxEntries: 10,
            storageURL: urls.storageURL,
            audioDirectoryURL: urls.audioDirectoryURL
        )

        XCTAssertEqual(reloadedStore.entries.map(\.rawTranscription), ["session complete"])
    }

    func testHistoryStoreDeleteEntryRemovesSavedAudio() async throws {
        let urls = try makeHistoryURLs()
        let store = HistoryStore(
            maxEntries: 10,
            storageURL: urls.storageURL,
            audioDirectoryURL: urls.audioDirectoryURL
        )
        let entry = makeEntry(audioFileURL: "clip.wav")

        store.addEntry(entry, audioSamples: [0.25, -0.25, 0.5] as [Float], sampleRate: 16_000)
        await store.flushPendingWrites()

        let audioURL = urls.audioDirectoryURL.appendingPathComponent("clip.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))

        store.deleteEntry(id: entry.id)
        await store.flushPendingWrites()

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
    }

    func testHistoryStoreDeleteAllClearsEntriesAndPersistedData() async throws {
        let urls = try makeHistoryURLs()
        let store = HistoryStore(
            maxEntries: 10,
            storageURL: urls.storageURL,
            audioDirectoryURL: urls.audioDirectoryURL
        )

        store.addEntry(makeEntry(rawTranscription: "one", audioFileURL: "one.wav"), audioSamples: [0.1, 0.2] as [Float])
        store.addEntry(makeEntry(rawTranscription: "two"))
        await store.flushPendingWrites()

        store.deleteAllEntries()
        await store.flushPendingWrites()

        let reloadedStore = HistoryStore(
            maxEntries: 10,
            storageURL: urls.storageURL,
            audioDirectoryURL: urls.audioDirectoryURL
        )

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(reloadedStore.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls.audioDirectoryURL.appendingPathComponent("one.wav").path))
    }

    func testHistoryStorePrunesImmediatelyWhenMaxEntriesChanges() async throws {
        let urls = try makeHistoryURLs()
        let store = HistoryStore(
            maxEntries: 5,
            storageURL: urls.storageURL,
            audioDirectoryURL: urls.audioDirectoryURL
        )

        store.addEntry(makeEntry(rawTranscription: "first"))
        store.addEntry(makeEntry(rawTranscription: "second"))
        store.addEntry(makeEntry(rawTranscription: "third"))
        await store.flushPendingWrites()

        store.maxEntries = 2
        await store.flushPendingWrites()

        XCTAssertEqual(store.entries.map(\.rawTranscription), ["third", "second"])
    }

    func testHistoryStoreDiskUsageIncludesJSONAndAudioFiles() async throws {
        let urls = try makeHistoryURLs()
        let store = HistoryStore(
            maxEntries: 10,
            storageURL: urls.storageURL,
            audioDirectoryURL: urls.audioDirectoryURL
        )
        let entry = makeEntry(audioFileURL: "usage.wav")

        store.addEntry(entry, audioSamples: [0.1, -0.1, 0.2, -0.2] as [Float], sampleRate: 16_000)
        await store.flushPendingWrites()
        // Allow the async disk usage refresh to land on MainActor
        try await Task.sleep(nanoseconds: 100_000_000)

        let jsonSize = try fileSize(at: urls.storageURL)
        let audioSize = try fileSize(at: urls.audioDirectoryURL.appendingPathComponent("usage.wav"))

        XCTAssertEqual(store.diskUsageBytes, jsonSize + audioSize)
        XCTAssertGreaterThan(store.diskUsageBytes, 44)
    }

    func testWAVEncoderWritesExpectedPCMHeaderAndPayloadSize() throws {
        let data = WAVEncoder.encode(samples: [1.0, 0.0, -1.0], sampleRate: 16_000)

        XCTAssertEqual(string(at: 0, length: 4, in: data), "RIFF")
        XCTAssertEqual(string(at: 8, length: 4, in: data), "WAVE")
        XCTAssertEqual(string(at: 12, length: 4, in: data), "fmt ")
        XCTAssertEqual(readUInt32(at: 16, in: data), 16)
        XCTAssertEqual(readUInt16(at: 20, in: data), 1)
        XCTAssertEqual(readUInt16(at: 22, in: data), 1)
        XCTAssertEqual(readUInt32(at: 24, in: data), 16_000)
        XCTAssertEqual(readUInt32(at: 28, in: data), 32_000)
        XCTAssertEqual(readUInt16(at: 32, in: data), 2)
        XCTAssertEqual(readUInt16(at: 34, in: data), 16)
        XCTAssertEqual(string(at: 36, length: 4, in: data), "data")
        XCTAssertEqual(readUInt32(at: 40, in: data), 6)
        XCTAssertEqual(data.count, 50)
    }

    func testAppStateCreatesHistoryEntryWhenHistoryEnabled() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let historyStore = try makeHistoryStore(maxEntries: 10)
        let appState = AppState(
            hotkeyMonitor: HistoryFeatureHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults,
            historyStore: historyStore
        )
        appState.historyEnabled = true
        appState.historySaveRecordings = true
        let completedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let entry = appState.makeHistoryEntryIfEnabled(
            rawTranscription: "raw",
            finalText: "clean",
            attemptedCleanup: true,
            completedAt: completedAt,
            capturedAudioBuffer: [0.1, -0.1] as [Float]
        )

        XCTAssertEqual(entry?.rawTranscription, "raw")
        XCTAssertEqual(entry?.cleanedText, "clean")
        XCTAssertEqual(entry?.cleanupBackend, CleanupBackendOption.localModels.rawValue)
        XCTAssertEqual(entry?.cleanupModelName, appState.textCleanupManager.localModelPolicy.title)
        XCTAssertEqual(entry?.completedAt, completedAt)
        XCTAssertEqual(entry?.audioFileURL?.hasSuffix(".wav"), true)
    }

    func testAppStateSkipsHistoryEntryWhenHistoryDisabled() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: HistoryFeatureHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults,
            historyStore: try makeHistoryStore(maxEntries: 10)
        )
        appState.historyEnabled = false

        let entry = appState.makeHistoryEntryIfEnabled(
            rawTranscription: "raw",
            finalText: "clean",
            attemptedCleanup: true,
            completedAt: Date(),
            capturedAudioBuffer: [0.1] as [Float]
        )

        XCTAssertNil(entry)
    }

    func testAppStateHistoryMaxEntriesUpdatesStoreAndPrunesImmediately() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let historyStore = try makeHistoryStore(maxEntries: 10)
        let appState = AppState(
            hotkeyMonitor: HistoryFeatureHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults,
            historyStore: historyStore
        )

        historyStore.addEntry(makeEntry(rawTranscription: "first"))
        historyStore.addEntry(makeEntry(rawTranscription: "second"))
        historyStore.addEntry(makeEntry(rawTranscription: "third"))
        appState.historyMaxEntries = 2

        XCTAssertEqual(appState.historyStore.maxEntries, 2)
        XCTAssertEqual(appState.historyStore.entries.map(\.rawTranscription), ["third", "second"])
    }

    private func makeHistoryStore(maxEntries: Int) throws -> HistoryStore {
        let urls = try makeHistoryURLs()
        return HistoryStore(
            maxEntries: maxEntries,
            storageURL: urls.storageURL,
            audioDirectoryURL: urls.audioDirectoryURL
        )
    }

    private func makeHistoryURLs() throws -> (storageURL: URL, audioDirectoryURL: URL) {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let storageURL = rootDirectory.appendingPathComponent("history.json")
        let audioDirectoryURL = rootDirectory.appendingPathComponent("history-audio", isDirectory: true)
        return (storageURL, audioDirectoryURL)
    }

    private func makeEntry(
        id: UUID = UUID(),
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        completedAt: Date = Date(timeIntervalSince1970: 1_700_000_003),
        rawTranscription: String = "raw text",
        cleanedText: String? = nil,
        cleanupBackend: String? = nil,
        cleanupModelName: String? = nil,
        cleanupAttempted: Bool = false,
        audioFileURL: String? = nil
    ) -> HistoryEntry {
        HistoryEntry(
            id: id,
            createdAt: createdAt,
            completedAt: completedAt,
            rawTranscription: rawTranscription,
            cleanedText: cleanedText,
            speechModelID: "openai_whisper-large-v3-turbo",
            cleanupBackend: cleanupBackend,
            cleanupModelName: cleanupModelName,
            cleanupAttempted: cleanupAttempted,
            durationSeconds: completedAt.timeIntervalSince(createdAt),
            audioFileURL: audioFileURL
        )
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = try XCTUnwrap(attributes[.size] as? NSNumber)
        return size.int64Value
    }

    private func string(at offset: Int, length: Int, in data: Data) -> String {
        let range = offset..<(offset + length)
        return String(decoding: data[range], as: UTF8.self)
    }

    private func readUInt16(at offset: Int, in data: Data) -> UInt16 {
        let lowerByte = UInt16(data[offset])
        let upperByte = UInt16(data[offset + 1]) << 8
        return lowerByte | upperByte
    }

    private func readUInt32(at offset: Int, in data: Data) -> UInt32 {
        let byte0 = UInt32(data[offset])
        let byte1 = UInt32(data[offset + 1]) << 8
        let byte2 = UInt32(data[offset + 2]) << 16
        let byte3 = UInt32(data[offset + 3]) << 24
        return byte0 | byte1 | byte2 | byte3
    }
}
