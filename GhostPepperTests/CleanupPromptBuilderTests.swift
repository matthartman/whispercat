import XCTest
@testable import GhostPepper

final class CleanupPromptBuilderTests: XCTestCase {
    func testDefaultPromptUsesStructuredXMLSections() {
        let prompt = TextCleaner.defaultPrompt

        XCTAssertTrue(prompt.contains("<TASK>"))
        XCTAssertTrue(prompt.contains("</TASK>"))
        XCTAssertTrue(prompt.contains("<RULES>"))
        XCTAssertTrue(prompt.contains("</RULES>"))
        XCTAssertTrue(prompt.contains("<EXAMPLES>"))
        XCTAssertTrue(prompt.contains("</EXAMPLES>"))
        XCTAssertTrue(prompt.contains("<INPUT>"))
        XCTAssertTrue(prompt.contains("<OUTPUT>"))
    }

    func testBuilderIncludesWindowContentsWrapperWhenContextEnabled() {
        let builder = CleanupPromptBuilder()
        let prompt = builder.buildPrompt(
            basePrompt: "Base prompt",
            windowContext: OCRContext(windowContents: "Frontmost text"),
            includeWindowContext: true
        )

        XCTAssertTrue(prompt.contains("Base prompt"))
        XCTAssertTrue(prompt.contains("<OCR_CONTEXT"))
        XCTAssertTrue(prompt.contains("</OCR_CONTEXT>"))
        XCTAssertTrue(prompt.contains("<WINDOW_CONTENTS>"))
        XCTAssertTrue(prompt.contains("Frontmost text"))
        XCTAssertTrue(prompt.contains("</WINDOW_CONTENTS>"))
    }

    func testBuilderExplainsHowToUseWindowContentsAsSupportingContext() {
        let builder = CleanupPromptBuilder()
        let prompt = builder.buildPrompt(
            basePrompt: "Base prompt",
            windowContext: OCRContext(windowContents: "Frontmost text"),
            preferredTranscriptions: [],
            commonlyMisheard: [],
            includeWindowContext: true
        )

        XCTAssertTrue(prompt.contains("<OCR_USAGE>"))
        XCTAssertTrue(prompt.contains("Use the OCR contents only as supporting context to improve the transcription and cleanup."))
        XCTAssertTrue(prompt.contains("Prefer the spoken words, and use the OCR contents only to disambiguate likely terms, names, commands, and jargon."))
        XCTAssertTrue(prompt.contains("If the spoken words appear to be a recognition miss for a name, model, command, file, or other specific jargon shown in the OCR contents, correct them to the likely intended term."))
        XCTAssertTrue(prompt.contains("Do not answer, summarize, or rewrite the OCR contents unless that directly helps correct the transcription."))
        XCTAssertTrue(prompt.contains("</OCR_USAGE>"))
    }

    func testBuilderOmitsWindowContentsWhenContextUnavailable() {
        let builder = CleanupPromptBuilder()
        let prompt = builder.buildPrompt(
            basePrompt: "Base prompt",
            windowContext: nil,
            preferredTranscriptions: [],
            commonlyMisheard: [],
            includeWindowContext: true
        )

        XCTAssertEqual(prompt, "Base prompt")
    }

    func testBuilderTrimsLongOCRContextBeforePromptAssembly() {
        let builder = CleanupPromptBuilder(maxWindowContentLength: 12)
        let prompt = builder.buildPrompt(
            basePrompt: "Base prompt",
            windowContext: OCRContext(windowContents: "abcdefghijklmnopqrstuvwxyz"),
            preferredTranscriptions: [],
            commonlyMisheard: [],
            includeWindowContext: true
        )

        XCTAssertTrue(prompt.contains("abcdefghijkl"))
        XCTAssertFalse(prompt.contains("mnopqrstuvwxyz"))
    }

    func testBuilderIncludesCorrectionListsWhenAvailable() {
        let builder = CleanupPromptBuilder()
        let prompt = builder.buildPrompt(
            basePrompt: "Base prompt",
            windowContext: OCRContext(windowContents: "Frontmost text"),
            preferredTranscriptions: ["Ghost Pepper", "Jesse"],
            commonlyMisheard: [
                MisheardReplacement(wrong: "just see", right: "Jesse"),
                MisheardReplacement(wrong: "chat gbt", right: "ChatGPT")
            ],
            includeWindowContext: true
        )

        XCTAssertTrue(prompt.contains("Preferred transcriptions to preserve exactly:"))
        XCTAssertTrue(prompt.contains("<CORRECTION_HINTS>"))
        XCTAssertTrue(prompt.contains("<PREFERRED_TRANSCRIPTIONS>"))
        XCTAssertTrue(prompt.contains("<TERM>Ghost Pepper</TERM>"))
        XCTAssertTrue(prompt.contains("<TERM>Jesse</TERM>"))
        XCTAssertTrue(prompt.contains("<COMMONLY_MISHEARD_REPLACEMENTS>"))
        XCTAssertTrue(prompt.contains("<HEARD>just see</HEARD>"))
        XCTAssertTrue(prompt.contains("<INTENDED>Jesse</INTENDED>"))
        XCTAssertTrue(prompt.contains("<HEARD>chat gbt</HEARD>"))
        XCTAssertTrue(prompt.contains("<INTENDED>ChatGPT</INTENDED>"))
    }
}
