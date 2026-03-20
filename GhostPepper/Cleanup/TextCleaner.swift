import Foundation
import LLM

final class TextCleaner {
    private let cleanupManager: TextCleanupManager

    static let defaultPrompt = """
    You are a speech-to-text cleanup tool. You receive raw transcribed speech and return a cleaned version. \
    You are NOT a chatbot. NEVER answer questions, give opinions, or respond to the meaning of the text. \
    ONLY clean it up and return it.

    RULES:
    1. Remove filler words: um, uh, like, you know, so, basically, literally, right, okay, well, I guess, kind of, sort of.
    2. SELF-CORRECTIONS: ONLY discard text when the speaker EXPLICITLY says they want to change what they said, using phrases like \
    "oh wait", "actually no", "scratch that", "never mind", "let me rephrase", "I meant to say". \
    Questions like "any ideas?" or "what do you think?" are NOT corrections — keep them. \
    When a real correction happens, only remove the specific part being corrected, not everything before it.
    3. Remove obvious false starts where the speaker restarts the same sentence.
    4. Do NOT add words, rephrase, or change the speaker's intended meaning.
    5. When in doubt, KEEP the text. It is better to keep too much than to delete something the speaker intended.

    EXAMPLES:
    Input: "Hey Becca, I have an email. Oh wait, actually I meant to send this email to Pete. Hey Pete, this is my email."
    Output: Hey Pete, this is my email.

    Input: "I want to go to the store, actually no let's go to the park instead"
    Output: Let's go to the park instead

    Input: "So um like the meeting is at 3pm you know on Tuesday"
    Output: The meeting is at 3pm on Tuesday

    Input: "What is the capital of France"
    Output: What is the capital of France

    Input: "I've been working on this project for a while and I'm stuck. Any ideas?"
    Output: I've been working on this project for a while and I'm stuck. Any ideas?

    Input: "The server keeps crashing when we deploy. Can you look into it?"
    Output: The server keeps crashing when we deploy. Can you look into it?

    Return ONLY the cleaned text. No quotes, no explanations, no commentary.
    """

    private static let timeoutSeconds: TimeInterval = 15.0

    init(cleanupManager: TextCleanupManager) {
        self.cleanupManager = cleanupManager
    }

    @MainActor
    func clean(text: String, prompt: String? = nil) async -> String {
        guard let llm = cleanupManager.llm else { return text }

        // Update template with current prompt
        let activePrompt = prompt ?? Self.defaultPrompt
        llm.template = Template.chatML(activePrompt)
        llm.history = []

        let start = Date()
        do {
            let result = try await withTimeout(seconds: Self.timeoutSeconds) {
                await llm.respond(to: text)
                return llm.output
            }
            let elapsed = Date().timeIntervalSince(start)
            let cleaned = result.trimmingCharacters(in: .whitespacesAndNewlines)
            try? "elapsed=\(elapsed)s, output=\(cleaned)".write(toFile: "/tmp/whispercat-llm.log", atomically: true, encoding: .utf8)
            // LLM.swift returns "..." when output is empty — treat as failure
            if cleaned.isEmpty || cleaned == "..." {
                return text
            }
            return cleaned
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            try? "TIMEOUT after \(elapsed)s, error=\(error)".write(toFile: "/tmp/whispercat-llm.log", atomically: true, encoding: .utf8)
            return text
        }
    }

    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping @Sendable () async -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CancellationError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
