import Foundation
import WhisperKit

/// Manages WhisperKit model lifecycle: download, load, and readiness state.
@MainActor
final class ModelManager: ObservableObject {
    /// The underlying WhisperKit instance, nil until successfully loaded.
    private(set) var whisperKit: WhisperKit?

    /// Current state of the model.
    @Published private(set) var state: ModelManagerState = .idle

    /// The model variant to use for transcription.
    private(set) var modelName: String

    /// Any error encountered during model setup.
    @Published private(set) var error: Error?

    var debugLogger: ((DebugLogCategory, String) -> Void)?

    /// Whether the model is loaded and ready for transcription.
    var isReady: Bool {
        state == .ready
    }

    init(modelName: String = "openai_whisper-small.en") {
        self.modelName = modelName
    }

    /// Loads the WhisperKit model. Downloads from Hugging Face if not cached.
    /// Pass a different name to switch models.
    func loadModel(name: String? = nil) async {
        let requestedName = name ?? modelName

        // If switching models, reset first
        if requestedName != modelName && state == .ready {
            whisperKit = nil
            state = .idle
            modelName = requestedName
        } else if state == .ready {
            return
        }
        modelName = requestedName

        guard state == .idle || state == .error else { return }

        state = .loading
        error = nil
        debugLogger?(.model, "Loading Whisper model \(modelName).")

        do {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let modelsDir = appSupport.appendingPathComponent("GhostPepper/whisper-models", isDirectory: true)
            try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

            let config = WhisperKitConfig(
                model: modelName,
                downloadBase: modelsDir,
                verbose: false,
                logLevel: .error,
                prewarm: false,
                load: true,
                download: true
            )
            let kit = try await WhisperKit(config)
            self.whisperKit = kit
            self.state = .ready
            debugLogger?(.model, "Whisper model \(modelName) loaded successfully.")
        } catch {
            self.error = error
            self.state = .error
            debugLogger?(.model, "Whisper model \(modelName) failed to load: \(error.localizedDescription)")
        }
    }
}

/// Possible states for ModelManager.
enum ModelManagerState: Equatable {
    case idle
    case loading
    case ready
    case error
}
