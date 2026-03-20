import Foundation
import LLM

enum CleanupModelState: Equatable {
    case idle
    case loading
    case ready
    case error
}

@MainActor
final class TextCleanupManager: ObservableObject {
    @Published private(set) var state: CleanupModelState = .idle
    @Published private(set) var errorMessage: String?

    private(set) var llm: LLM?

    private static let modelFileName = "Qwen2.5-1.5B-Instruct-Q4_K_M.gguf"
    private static let modelURL = "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf"

    var isReady: Bool { state == .ready }

    private var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("GhostPepper/models", isDirectory: true)
    }

    private var modelPath: URL {
        modelsDirectory.appendingPathComponent(Self.modelFileName)
    }

    func loadModel() async {
        guard state == .idle || state == .error else { return }

        state = .loading
        errorMessage = nil

        // Ensure models directory exists
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        // Download model if not cached
        if !FileManager.default.fileExists(atPath: modelPath.path) {
            do {
                try await downloadModel()
            } catch {
                self.errorMessage = "Failed to download cleanup model: \(error.localizedDescription)"
                self.state = .error
                return
            }
        }

        // Load the model with ChatML template and system prompt
        let template = Template.chatML(TextCleaner.defaultPrompt)
        guard let model = LLM(from: modelPath, template: template, maxTokenCount: 4096) else {
            self.errorMessage = "Failed to load cleanup model"
            self.state = .error
            return
        }

        model.temp = 0.1
        model.update = { (_: String?) in }
        model.postprocess = { (_: String) in }

        self.llm = model
        self.state = .ready
    }

    func unloadModel() {
        llm = nil
        state = .idle
        errorMessage = nil
    }

    private func downloadModel() async throws {
        guard let url = URL(string: Self.modelURL) else {
            throw URLError(.badURL)
        }

        print("TextCleanupManager: downloading \(Self.modelFileName)...")
        let (tempURL, _) = try await URLSession.shared.download(from: url)
        try FileManager.default.moveItem(at: tempURL, to: modelPath)
        print("TextCleanupManager: model saved to \(modelPath.path)")
    }
}
