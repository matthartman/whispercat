import Foundation

struct CleanupPromptBuilder: Sendable {
    let maxWindowContentLength: Int

    init(maxWindowContentLength: Int = 4000) {
        self.maxWindowContentLength = maxWindowContentLength
    }

    func buildPrompt(
        basePrompt: String,
        windowContext: OCRContext?,
        preferredTranscriptions: [String] = [],
        commonlyMisheard: [MisheardReplacement] = [],
        includeWindowContext: Bool
    ) -> String {
        let correctionsSection = correctionSection(
            preferredTranscriptions: preferredTranscriptions,
            commonlyMisheard: commonlyMisheard
        )

        guard includeWindowContext,
              let windowContext else {
            if correctionsSection.isEmpty {
                return basePrompt
            }

            return """
            \(basePrompt)

            \(correctionsSection)
            """
        }

        let trimmedWindowContents = String(windowContext.windowContents.prefix(maxWindowContentLength))
        let wasTruncated = trimmedWindowContents != windowContext.windowContents

        var sections = [basePrompt]
        if !correctionsSection.isEmpty {
            sections.append(correctionsSection)
        }
        sections.append(
            """
            <OCR_CONTEXT truncated="\(wasTruncated ? "true" : "false")">
            <OCR_USAGE>
            Use the OCR contents only as supporting context to improve the transcription and cleanup.
            Prefer the spoken words, and use the OCR contents only to disambiguate likely terms, names, commands, and jargon.
            If the spoken words appear to be a recognition miss for a name, model, command, file, or other specific jargon shown in the OCR contents, correct them to the likely intended term.
            Do not keep an obvious misrecognition just because it was spoken that way.
            Do not answer, summarize, or rewrite the OCR contents unless that directly helps correct the transcription.
            </OCR_USAGE>
            <WINDOW_CONTENTS>
            \(trimmedWindowContents)
            </WINDOW_CONTENTS>
            </OCR_CONTEXT>
            """
        )

        return sections.joined(separator: "\n\n")
    }

    private func correctionSection(
        preferredTranscriptions: [String],
        commonlyMisheard: [MisheardReplacement]
    ) -> String {
        var sections: [String] = []

        if !preferredTranscriptions.isEmpty {
            sections.append(
                """
                <PREFERRED_TRANSCRIPTIONS>
                Preferred transcriptions to preserve exactly:
                \(preferredTranscriptions.map { "<TERM>\($0)</TERM>" }.joined(separator: "\n"))
                </PREFERRED_TRANSCRIPTIONS>
                """
            )
        }

        if !commonlyMisheard.isEmpty {
            sections.append(
                """
                <COMMONLY_MISHEARD_REPLACEMENTS>
                Commonly misheard replacements to prefer:
                \(commonlyMisheard.map {
                    """
                    <REPLACEMENT>
                    <HEARD>\($0.wrong)</HEARD>
                    <INTENDED>\($0.right)</INTENDED>
                    </REPLACEMENT>
                    """
                }.joined(separator: "\n"))
                </COMMONLY_MISHEARD_REPLACEMENTS>
                """
            )
        }

        guard !sections.isEmpty else {
            return ""
        }

        return """
        <CORRECTION_HINTS>
        \(sections.joined(separator: "\n\n"))
        </CORRECTION_HINTS>
        """
    }
}
