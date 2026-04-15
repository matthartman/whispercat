import XCTest
import WhisperKit
@testable import GhostPepper

/// Integration tests that verify Whisper language auto-detection behavior.
///
/// These tests require:
/// - The `whisper-small` (multilingual) model downloaded in the app's model cache
/// - A Chinese audio sample in the Transcription Lab store
///
/// They are skipped automatically when the required resources are missing.
@MainActor
final class WhisperLanguageDetectionTests: XCTestCase {

    private static let audioFileID = "D8ADE38D-E0F6-46B8-9DE5-F0C357CE3152"
    private static let modelName = "openai_whisper-small"

    private static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("GhostPepper/whisper-models", isDirectory: true)
    }

    private static var audioFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("GhostPepper/transcription-lab/audio", isDirectory: true)
            .appendingPathComponent("\(audioFileID).wav")
    }

    private func loadAudioBuffer() throws -> [Float] {
        let url = Self.audioFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Chinese audio sample not found at \(url.path)")
        }
        let data = try Data(contentsOf: url)
        return try AudioRecorder.deserializeArchivedAudioBuffer(from: data)
    }

    private func loadWhisperKit() async throws -> WhisperKit {
        let modelDir = Self.modelsDirectory
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(Self.modelName)", isDirectory: true)
        guard FileManager.default.fileExists(atPath: modelDir.path) else {
            throw XCTSkip("Whisper multilingual model not downloaded at \(modelDir.path)")
        }

        let config = WhisperKitConfig(
            model: Self.modelName,
            downloadBase: Self.modelsDirectory,
            modelFolder: modelDir.path,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false
        )
        return try await WhisperKit(config)
    }

    // MARK: - Tests

    /// Demonstrates the bug: passing nil decodeOptions causes Whisper to default
    /// to English, producing pinyin instead of Chinese characters.
    func testNilDecodeOptionsDefaultsToEnglishForChineseAudio() async throws {
        let audioBuffer = try loadAudioBuffer()
        let whisper = try await loadWhisperKit()

        // Current behavior: nil decodeOptions → no language hint → defaults to English
        let results = try await whisper.transcribe(audioArray: audioBuffer, decodeOptions: nil)
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        // The audio says "你好，我是Nick" but Whisper outputs pinyin because it thinks it's English
        let containsChinese = text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
        }

        XCTAssertFalse(
            containsChinese,
            "Expected pinyin/English output (no Chinese characters) with nil decodeOptions, but got: \(text)"
        )
        // Verify it looks like pinyin romanization
        let lowerText = text.lowercased()
        let hasPinyinMarkers = lowerText.contains("ni") || lowerText.contains("hao") || lowerText.contains("nick")
        XCTAssertTrue(hasPinyinMarkers, "Expected pinyin-like output, got: \(text)")
    }

    /// Verifies the fix: setting detectLanguage = true allows Whisper to correctly
    /// identify Chinese and output characters instead of pinyin.
    func testDetectLanguageTrueProducesChineseCharacters() async throws {
        let audioBuffer = try loadAudioBuffer()
        let whisper = try await loadWhisperKit()

        // Fixed behavior: detectLanguage = true → Whisper runs language detection → picks Chinese
        var options = DecodingOptions()
        options.detectLanguage = true

        let results = try await whisper.transcribe(audioArray: audioBuffer, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        let containsChinese = text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
        }

        XCTAssertTrue(
            containsChinese,
            "Expected Chinese characters with detectLanguage=true, but got: \(text)"
        )
    }

    /// Verifies that explicitly setting language to "zh" also produces Chinese characters.
    func testExplicitChineseLanguageProducesChineseCharacters() async throws {
        let audioBuffer = try loadAudioBuffer()
        let whisper = try await loadWhisperKit()

        var options = DecodingOptions()
        options.language = "zh"

        let results = try await whisper.transcribe(audioArray: audioBuffer, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        let containsChinese = text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
        }

        XCTAssertTrue(
            containsChinese,
            "Expected Chinese characters with language='zh', but got: \(text)"
        )
    }
}
