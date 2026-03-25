import Foundation

enum CleanupModelProbeMain {
    @MainActor
    static func run() async -> Int32 {
        do {
            let command = try CleanupModelProbeCLI.parse(arguments: Array(CommandLine.arguments.dropFirst()))
            let manager = TextCleanupManager()
            await manager.loadModel()

            let runner = CleanupModelProbeRunner { input, prompt, modelKind, thinkingMode in
                try await manager.probe(
                    text: input,
                    prompt: prompt,
                    modelKind: modelKind,
                    thinkingMode: thinkingMode
                )
            }

            if let input = command.input {
                try await runOneShot(command: command, runner: runner, input: input)
            } else {
                try await runInteractive(command: command, runner: runner)
            }

            return EXIT_SUCCESS
        } catch let error as CleanupModelProbeCLIError {
            fputs("\(error.localizedDescription)\n\n\(CleanupModelProbeCLI.usage)\n", stderr)
            return EXIT_FAILURE
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return EXIT_FAILURE
        }
    }

    @MainActor
    private static func runOneShot(
        command: CleanupModelProbeCommand,
        runner: CleanupModelProbeRunner,
        input: String
    ) async throws {
        let transcript = try await runProbe(command: command, runner: runner, input: input)
        print(CleanupModelProbeCLI.format(transcript))
    }

    @MainActor
    private static func runInteractive(
        command: CleanupModelProbeCommand,
        runner: CleanupModelProbeRunner
    ) async throws {
        print("Loaded \(label(for: command.modelKind)). Enter text to probe, or :quit to exit.")

        while true {
            print("cleanup-probe> ", terminator: "")
            fflush(stdout)

            let nextInput = readLine()
            if CleanupModelProbeCLI.shouldExitInteractive(input: nextInput) {
                return
            }

            guard let nextInput else {
                return
            }

            if nextInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }

            let transcript = try await runProbe(command: command, runner: runner, input: nextInput)
            print(CleanupModelProbeCLI.format(transcript))
            print("")
        }
    }

    @MainActor
    private static func runProbe(
        command: CleanupModelProbeCommand,
        runner: CleanupModelProbeRunner,
        input: String
    ) async throws -> CleanupModelProbeTranscript {
        try await runner.run(
            input: input,
            modelKind: command.modelKind,
            thinkingMode: command.thinkingMode,
            prompt: command.prompt,
            windowContext: command.windowContext.map { OCRContext(windowContents: $0) }
        )
    }

    private static func label(for modelKind: LocalCleanupModelKind) -> String {
        switch modelKind {
        case .fast:
            return TextCleanupManager.fastModel.displayName
        case .full:
            return TextCleanupManager.fullModel.displayName
        }
    }
}

Task {
    let exitCode = await CleanupModelProbeMain.run()
    exit(exitCode)
}

RunLoop.main.run()
