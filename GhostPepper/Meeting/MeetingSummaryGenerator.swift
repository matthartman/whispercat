import Foundation

/// Generates meeting summaries using the local LLM via chunked summarization.
///
/// Strategy: The transcript is split into chunks that fit the model's context window.
/// Each chunk is summarized into bullet points. Then the bullet points are combined
/// into a final summary with key topics, action items, and a TL;DR.
@MainActor
final class MeetingSummaryGenerator {
    private let cleanupManager: TextCleanupManager

    /// Maximum characters per chunk sent to the LLM (~1500 tokens ≈ 6000 chars).
    private let chunkCharLimit = 5000

    static let defaultPrompt = """
    Summarize the following meeting transcript excerpt. Output a concise bulleted list of key points discussed. \
    Include any action items mentioned. Be brief — one line per point.
    """

    static let finalSummaryPrompt = """
    You are summarizing a meeting transcript. Produce a well-organized summary in this exact format:

    ## Key Decisions
    - List any decisions that were made during the meeting

    ## Action Items
    - [ ] Task description — Owner (if mentioned)
    - [ ] Use checkbox format so these can be tracked

    ## Key Discussion Points
    - Summarize the main topics discussed, one bullet per topic
    - Include relevant details, names, numbers, or dates mentioned
    - Note any disagreements or open questions

    ## TL;DR
    Write 2-3 sentences capturing the essence of the meeting. What was it about, what was decided, what happens next?
    """

    init(cleanupManager: TextCleanupManager) {
        self.cleanupManager = cleanupManager
    }

    /// Generate a full summary for a completed meeting transcript.
    /// Returns the summary as markdown text, or nil if generation fails.
    func generateSummary(
        transcript: MeetingTranscript,
        chunkPrompt: String = MeetingSummaryGenerator.defaultPrompt,
        finalPrompt: String = MeetingSummaryGenerator.finalSummaryPrompt
    ) async -> String? {
        let segments = transcript.segments
        guard !segments.isEmpty else { return nil }

        // Build the full transcript text
        let fullText = segments.map { segment in
            "[\(segment.formattedTimestamp)] \(segment.speaker.displayName): \(segment.text)"
        }.joined(separator: "\n")

        // Split into chunks
        let chunks = splitIntoChunks(fullText)

        if chunks.count == 1 {
            // Short meeting — summarize directly with the final prompt
            let input = "Meeting transcript:\n\n\(chunks[0])"
            return await runLLM(text: input, prompt: finalPrompt)
        }

        // Multi-chunk: summarize each chunk, then combine
        var chunkSummaries: [String] = []
        for (i, chunk) in chunks.enumerated() {
            let input = "Meeting transcript (part \(i + 1) of \(chunks.count)):\n\n\(chunk)"
            if let summary = await runLLM(text: input, prompt: chunkPrompt) {
                chunkSummaries.append(summary)
            }
        }

        guard !chunkSummaries.isEmpty else { return nil }

        // Combine chunk summaries into final summary
        let combined = chunkSummaries.enumerated().map { i, s in
            "Part \(i + 1):\n\(s)"
        }.joined(separator: "\n\n")

        let finalInput = "Combined meeting notes:\n\n\(combined)"
        return await runLLM(text: finalInput, prompt: finalPrompt)
    }

    // MARK: - Private

    private func splitIntoChunks(_ text: String) -> [String] {
        guard text.count > chunkCharLimit else { return [text] }

        var chunks: [String] = []
        let lines = text.components(separatedBy: "\n")
        var current = ""

        for line in lines {
            if current.count + line.count + 1 > chunkCharLimit && !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }

        if !current.isEmpty {
            chunks.append(current)
        }

        return chunks
    }

    private func runLLM(text: String, prompt: String) async -> String? {
        do {
            let fullPrompt = "\(prompt)\n\n\(text)"
            let result = try await cleanupManager.clean(text: fullPrompt, prompt: nil)
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            print("MeetingSummaryGenerator: LLM failed — \(error.localizedDescription)")
            return nil
        }
    }
}
