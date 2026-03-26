import SwiftUI
import AppKit
import CoreAudio
import ServiceManagement

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(appState: AppState) {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(appState: appState)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Ghost Pepper Settings"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 680)
        window.contentViewController = NSHostingController(rootView: view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

@MainActor
final class SettingsDictationTestController: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var transcript: String?
    @Published private(set) var lastError: String?

    private var recorder: AudioRecorder?
    private let transcriber: SpeechTranscriber

    init(transcriber: SpeechTranscriber) {
        self.transcriber = transcriber
    }

    func start() {
        guard !isRecording else { return }
        let recorder = AudioRecorder()
        recorder.prewarm()

        do {
            try recorder.startRecording()
            self.recorder = recorder
            transcript = nil
            lastError = nil
            isRecording = true
        } catch {
            lastError = "Could not start recording."
        }
    }

    func stop() {
        guard isRecording, let recorder else { return }
        isRecording = false
        isTranscribing = true
        self.recorder = nil

        Task { @MainActor in
            let buffer = await recorder.stopRecording()
            let text = await transcriber.transcribe(audioBuffer: buffer)
            self.transcript = text
            self.lastError = text == nil ? "Ghost Pepper could not transcribe that sample." : nil
            self.isTranscribing = false
        }
    }
}

// MARK: - Settings View

private enum SettingsSection: String, CaseIterable, Identifiable {
    case recording
    case cleanup
    case corrections
    case models
    case transcriptionLab
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recording: "Recording"
        case .cleanup: "Cleanup"
        case .corrections: "Corrections"
        case .models: "Models"
        case .transcriptionLab: "Transcription Lab"
        case .general: "General"
        }
    }

    var subtitle: String {
        switch self {
        case .recording: "Shortcuts, microphone input, dictation testing, and sound feedback."
        case .cleanup: "Prompt cleanup, OCR context, and learning behavior."
        case .corrections: "Words and replacements Ghost Pepper should preserve."
        case .models: "Speech and cleanup model downloads and runtime status."
        case .transcriptionLab: "Replay saved recordings with different speech models, cleanup models, and prompts."
        case .general: "Startup behavior and app-wide preferences."
        }
    }

    var systemImageName: String {
        switch self {
        case .recording: "waveform.and.mic"
        case .cleanup: "sparkles"
        case .corrections: "text.badge.checkmark"
        case .models: "brain"
        case .transcriptionLab: "waveform.badge.magnifyingglass"
        case .general: "gearshape"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var selectedDeviceID: AudioDeviceID = 0
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var hasScreenRecordingPermission = PermissionChecker.hasScreenRecordingPermission()
    @State private var selectedSection: SettingsSection = .recording
    @StateObject private var dictationTestController: SettingsDictationTestController
    @StateObject private var transcriptionLabController: TranscriptionLabController

    init(appState: AppState) {
        self.appState = appState
        _dictationTestController = StateObject(
            wrappedValue: SettingsDictationTestController(transcriber: appState.transcriber)
        )
        _transcriptionLabController = StateObject(
            wrappedValue: TranscriptionLabController(
                defaultSpeechModelID: appState.speechModel,
                defaultCleanupModelKind: appState.textCleanupManager.localModelPolicy == .fastOnly ? .fast : .full,
                loadEntries: {
                    try appState.loadTranscriptionLabEntries()
                },
                runExperiment: { entry, speechModelID, cleanupModelKind, prompt in
                    try await appState.rerunTranscriptionLabEntry(
                        entry,
                        speechModelID: speechModelID,
                        cleanupModelKind: cleanupModelKind,
                        prompt: prompt
                    )
                }
            )
        )
    }

    private var modelRows: [RuntimeModelRow] {
        RuntimeModelInventory.rows(
            selectedSpeechModelName: appState.speechModel,
            activeSpeechModelName: appState.modelManager.modelName,
            speechModelState: appState.modelManager.state,
            cachedSpeechModelNames: appState.modelManager.cachedModelNames,
            cleanupState: appState.textCleanupManager.state,
            loadedCleanupKinds: appState.textCleanupManager.loadedModelKinds
        )
    }

    private var hasMissingModels: Bool {
        RuntimeModelInventory.hasMissingModels(rows: modelRows)
    }

    private var modelsAreDownloading: Bool {
        RuntimeModelInventory.activeDownloadText(rows: modelRows) != nil
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(SettingsSection.allCases) { section in
                    Button {
                        selectedSection = section
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: section.systemImageName)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(section.title)
                                    .font(.body.weight(.medium))
                                Text(section.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(selectedSection == section ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.22) : .clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(
                                    selectedSection == section
                                        ? Color(nsColor: .separatorColor)
                                        : Color.clear,
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                Spacer(minLength: 0)
            }
            .frame(minWidth: 250, idealWidth: 270, maxWidth: 270, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
            }

            ScrollView {
                detailContent
                    .padding(.horizontal, 40)
                    .padding(.vertical, 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 900, minHeight: 680)
        .onAppear {
            inputDevices = AudioDeviceManager.listInputDevices()
            selectedDeviceID = AudioDeviceManager.defaultInputDeviceID() ?? 0
            refreshScreenRecordingPermission()
            transcriptionLabController.reloadEntries()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshScreenRecordingPermission()
        }
        .onChange(of: selectedSection) { _, newSection in
            if newSection == .transcriptionLab {
                transcriptionLabController.reloadEntries()
            }
        }
        .onDisappear {
            if dictationTestController.isRecording {
                dictationTestController.stop()
            }
        }
    }

    private func refreshScreenRecordingPermission() {
        hasScreenRecordingPermission = PermissionChecker.hasScreenRecordingPermission()
    }

    private func downloadMissingModels() async {
        let selectedSpeechModelName = appState.speechModel
        let missingSpeechModels = ModelManager.availableModels
            .map(\.name)
            .filter { !appState.modelManager.cachedModelNames.contains($0) }

        for modelName in missingSpeechModels {
            await appState.modelManager.loadModel(name: modelName)
        }

        if appState.modelManager.modelName != selectedSpeechModelName || !appState.modelManager.isReady {
            await appState.modelManager.loadModel(name: selectedSpeechModelName)
        }

        if appState.textCleanupManager.loadedModelKinds.count < TextCleanupManager.cleanupModels.count {
            await appState.textCleanupManager.loadModel()
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text(selectedSection.title)
                    .font(.system(size: 28, weight: .semibold))
                Text(selectedSection.subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch selectedSection {
            case .recording:
                recordingSection
            case .cleanup:
                cleanupSection
            case .corrections:
                correctionsSection
            case .models:
                modelsSection
            case .transcriptionLab:
                transcriptionLabSection
            case .general:
                generalSection
            }

            Spacer(minLength: 0)
        }
    }

    private var recordingSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsCard("Shortcuts") {
                VStack(alignment: .leading, spacing: 16) {
                    ShortcutRecorderView(
                        title: "Hold to Record",
                        chord: appState.pushToTalkChord,
                        onRecordingStateChange: appState.setShortcutCaptureActive
                    ) { chord in
                        appState.updateShortcut(chord, for: .pushToTalk)
                    }

                    ShortcutRecorderView(
                        title: "Toggle Recording",
                        chord: appState.toggleToTalkChord,
                        onRecordingStateChange: appState.setShortcutCaptureActive
                    ) { chord in
                        appState.updateShortcut(chord, for: .toggleToTalk)
                    }

                    if let shortcutErrorMessage = appState.shortcutErrorMessage {
                        Text(shortcutErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Text("Push to talk records while the hold chord stays down. Toggle recording starts and stops when you press the full toggle chord.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            SettingsCard("Input") {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsField("Microphone") {
                        Picker("Microphone", selection: $selectedDeviceID) {
                            ForEach(inputDevices) { device in
                                Text(device.name).tag(device.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 320, alignment: .leading)
                        .onChange(of: selectedDeviceID) { _, newValue in
                            _ = AudioDeviceManager.setDefaultInputDevice(newValue)
                        }
                    }

                    Toggle(
                        "Play sounds",
                        isOn: Binding(
                            get: { appState.playSounds },
                            set: { appState.playSounds = $0 }
                        )
                    )
                }
            }

            SettingsCard("Test dictation") {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Record a short sample with your current microphone and speech model without leaving Settings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 12) {
                        Button(dictationTestController.isRecording ? "Stop test dictation" : "Start test dictation") {
                            if dictationTestController.isRecording {
                                dictationTestController.stop()
                            } else {
                                dictationTestController.start()
                            }
                        }
                        .buttonStyle(.borderedProminent)

                        if dictationTestController.isRecording {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 10, height: 10)
                                Text("Recording…")
                                    .foregroundStyle(.secondary)
                            }
                        } else if dictationTestController.isTranscribing {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Transcribing…")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let transcript = dictationTestController.transcript {
                        Text(transcript)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                    } else if let lastError = dictationTestController.lastError {
                        Text(lastError)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private var cleanupSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsCard("Cleanup") {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle(
                        "Enable cleanup",
                        isOn: Binding(
                            get: { appState.cleanupEnabled },
                            set: { appState.setCleanupEnabled($0) }
                        )
                    )

                    if appState.cleanupEnabled {
                        if appState.textCleanupManager.state == .error {
                            Text(appState.textCleanupManager.errorMessage ?? "Error loading model")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    Text("When enabled, Ghost Pepper runs local cleanup with the selected cleanup model from the Models section.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            SettingsCard("Cleanup prompt") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Ghost Pepper uses this prompt before adding OCR context and correction hints.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    BorderedTextEditor(text: $appState.cleanupPrompt, minHeight: 220)

                    HStack {
                        Spacer()

                        Button("Reset to Default") {
                            appState.cleanupPrompt = TextCleaner.defaultPrompt
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            SettingsCard("Context") {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle(
                        "Use frontmost window OCR context",
                        isOn: Binding(
                            get: { appState.frontmostWindowContextEnabled },
                            set: { appState.frontmostWindowContextEnabled = $0 }
                        )
                    )

                    if appState.frontmostWindowContextEnabled && !hasScreenRecordingPermission {
                        ScreenRecordingRecoveryView {
                            _ = PermissionChecker.requestScreenRecordingPermission()
                            PermissionChecker.openScreenRecordingSettings()
                            refreshScreenRecordingPermission()
                        }
                    }

                    Toggle(
                        "Learn from manual corrections after paste",
                        isOn: Binding(
                            get: { appState.postPasteLearningEnabled },
                            set: { appState.postPasteLearningEnabled = $0 }
                        )
                    )

                    if appState.postPasteLearningEnabled && !hasScreenRecordingPermission {
                        ScreenRecordingRecoveryView {
                            _ = PermissionChecker.requestScreenRecordingPermission()
                            PermissionChecker.openScreenRecordingSettings()
                            refreshScreenRecordingPermission()
                        }
                    }

                    Text("Ghost Pepper uses high-quality OCR on the frontmost window and adds the result to the cleanup prompt. When learning is enabled, Ghost Pepper does a high-quality OCR check about 15 seconds after paste and only keeps narrow, high-confidence corrections.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var correctionsSection: some View {
        SettingsCard("Corrections") {
            VStack(alignment: .leading, spacing: 20) {
                CorrectionsEditor(
                    title: "Preferred transcriptions",
                    text: Binding(
                        get: { appState.correctionStore.preferredTranscriptionsText },
                        set: { appState.correctionStore.preferredTranscriptionsText = $0 }
                    ),
                    prompt: "One preferred word or phrase per line"
                )

                Divider()

                CorrectionsEditor(
                    title: "Commonly misheard",
                    text: Binding(
                        get: { appState.correctionStore.commonlyMisheardText },
                        set: { appState.correctionStore.commonlyMisheardText = $0 }
                    ),
                    prompt: "One replacement per line using probably wrong -> probably right"
                )

                Text("Preferred transcriptions are preserved in cleanup and forwarded into OCR custom words. Commonly misheard replacements run deterministically before cleanup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsCard("Speech model") {
                SettingsField("Active speech model") {
                    Picker("Speech Model", selection: $appState.speechModel) {
                        ForEach(ModelManager.availableModels) { model in
                            Text(model.pickerLabel).tag(model.name)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320, alignment: .leading)
                    .onChange(of: appState.speechModel) { _, newModel in
                        Task {
                            await appState.modelManager.loadModel(name: newModel)
                        }
                    }
                }

                Text("Ghost Pepper uses this model for speech recognition everywhere in the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsCard("Cleanup model") {
                SettingsField("Active cleanup model") {
                    Picker(
                        "Cleanup model",
                        selection: Binding(
                            get: { appState.textCleanupManager.localModelPolicy },
                            set: { appState.textCleanupManager.localModelPolicy = $0 }
                        )
                    ) {
                        ForEach(LocalCleanupModelPolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 360, alignment: .leading)
                }

                Text("Use Qwen 3 1.7B for faster cleanup or Qwen 3.5 4B for the highest-quality cleanup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsCard("Runtime models") {
                VStack(alignment: .leading, spacing: 16) {
                    ModelInventoryCard(rows: modelRows)

                    if let activeDownloadText = RuntimeModelInventory.activeDownloadText(rows: modelRows) {
                        Text(activeDownloadText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if hasMissingModels {
                        Button {
                            Task {
                                await downloadMissingModels()
                            }
                        } label: {
                            HStack {
                                if modelsAreDownloading {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.down.circle")
                                }
                                Text(modelsAreDownloading ? "Downloading Models..." : "Download Missing Models")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .disabled(modelsAreDownloading)
                    }
                }
            }
        }
    }

    private var transcriptionLabSection: some View {
        HSplitView {
            SettingsCard("Saved recordings") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Ghost Pepper keeps the 50 most recent completed recordings with audio for reruns and comparisons.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 12)

                        Button("Refresh") {
                            transcriptionLabController.reloadEntries()
                        }
                        .buttonStyle(.bordered)
                    }

                    if transcriptionLabController.entries.isEmpty {
                        ContentUnavailableView(
                            "No Saved Recordings",
                            systemImage: "waveform",
                            description: Text("Make a few dictations in Ghost Pepper and they will appear here.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 320)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(transcriptionLabController.entries) { entry in
                                    Button {
                                        transcriptionLabController.selectEntry(entry.id)
                                    } label: {
                                        TranscriptionLabEntryRow(
                                            entry: entry,
                                            isSelected: transcriptionLabController.selectedEntryID == entry.id
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 340, maxHeight: .infinity, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 24) {
                if let selectedEntry = transcriptionLabController.selectedEntry {
                    SettingsCard("Original") {
                        TranscriptionLabResultStack(
                            rawTitle: "Raw transcription",
                            rawText: selectedEntry.rawTranscription ?? "No transcription was captured for this recording.",
                            correctedTitle: "Corrected transcription",
                            correctedText: selectedEntry.correctedTranscription ?? "No corrected output was captured for this recording."
                        ) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Original run")
                                    .font(.subheadline.weight(.medium))
                                TranscriptionLabMetadataRow(
                                    label: "When",
                                    value: selectedEntry.createdAt.formatted(date: .abbreviated, time: .shortened)
                                )
                                TranscriptionLabMetadataRow(
                                    label: "Audio length",
                                    value: String(format: "%.1fs", selectedEntry.audioDuration)
                                )
                                TranscriptionLabMetadataRow(
                                    label: "Speech model",
                                    value: SpeechModelCatalog.model(named: selectedEntry.speechModelID)?.statusName ?? selectedEntry.speechModelID
                                )
                                TranscriptionLabMetadataRow(
                                    label: "Cleanup model",
                                    value: selectedEntry.cleanupModelName
                                )
                                if let windowContents = selectedEntry.windowContext?.windowContents,
                                   !windowContents.isEmpty {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Captured OCR context")
                                            .font(.subheadline.weight(.medium))
                                        ReadOnlyTextPane(text: windowContents, minHeight: 96, monospaced: true)
                                    }
                                }
                            }
                        }
                    }

                    SettingsCard("Experiment") {
                        VStack(alignment: .leading, spacing: 18) {
                            SettingsField("Speech model") {
                                Picker("Speech Model", selection: $transcriptionLabController.selectedSpeechModelID) {
                                    ForEach(ModelManager.availableModels) { model in
                                        Text(model.pickerLabel).tag(model.name)
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 420, alignment: .leading)
                            }

                            SettingsField("Cleanup model") {
                                Picker("Cleanup model", selection: $transcriptionLabController.selectedCleanupModelKind) {
                                    Text(TextCleanupManager.fastModel.displayName).tag(LocalCleanupModelKind.fast)
                                    Text(TextCleanupManager.fullModel.displayName).tag(LocalCleanupModelKind.full)
                                }
                                .labelsHidden()
                                .frame(maxWidth: 420, alignment: .leading)
                            }

                            SettingsField("Cleanup prompt") {
                                BorderedTextEditor(text: $appState.cleanupPrompt, minHeight: 180)
                            }

                            HStack(spacing: 12) {
                                Button {
                                    Task {
                                        await transcriptionLabController.rerun(prompt: appState.cleanupPrompt)
                                    }
                                } label: {
                                    HStack {
                                        if transcriptionLabController.isRunning {
                                            ProgressView()
                                                .controlSize(.small)
                                        } else {
                                            Image(systemName: "arrow.trianglehead.clockwise")
                                        }
                                        Text(transcriptionLabController.isRunning ? "Rerunning..." : "Rerun Recording")
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(transcriptionLabController.isRunning)

                                Button("Reset Prompt to Default") {
                                    appState.cleanupPrompt = TextCleaner.defaultPrompt
                                }
                                .buttonStyle(.bordered)
                                .disabled(transcriptionLabController.isRunning)
                            }

                            if let errorMessage = transcriptionLabController.errorMessage {
                                Text(errorMessage)
                                    .font(.callout)
                                    .foregroundStyle(.red)
                            }

                            Text("The lab reuses the original audio and OCR context, never pastes into another app, and temporarily owns Ghost Pepper's transcription pipeline while it reruns.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            TranscriptionLabResultStack(
                                rawTitle: "Experiment raw transcription",
                                rawText: transcriptionLabController.experimentRawTranscription.isEmpty
                                    ? "Run the selected recording through a speech model to see the raw transcript here."
                                    : transcriptionLabController.experimentRawTranscription,
                                correctedTitle: "Experiment corrected transcription",
                                correctedText: transcriptionLabController.experimentCorrectedTranscription.isEmpty
                                    ? "The cleanup result will appear here after the rerun finishes."
                                    : transcriptionLabController.experimentCorrectedTranscription
                            )
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "Choose a Saved Recording",
                        systemImage: "waveform.badge.magnifyingglass",
                        description: Text("Pick a recording on the left to compare its original transcription with new speech and cleanup runs.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var generalSection: some View {
        SettingsCard("General") {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = !enabled
                    }
                }
        }
    }
}

private struct ScreenRecordingRecoveryView: View {
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ghost Pepper needs Screen Recording access. Grant it in System Settings, then return to Ghost Pepper.")
                .font(.caption)
                .foregroundStyle(.red)

            Button("Open Screen Recording Settings", action: onOpenSettings)
            .controlSize(.small)
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.title3.weight(.semibold))

            content
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}

private struct SettingsField<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
            content
        }
    }
}

private struct CorrectionsEditor: View {
    let title: String
    let text: Binding<String>
    let prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))

            BorderedTextEditor(text: text, minHeight: 96)

            Text(prompt)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct TranscriptionLabEntryRow: View {
    let entry: TranscriptionLabEntry
    let isSelected: Bool

    private var titleText: String {
        if let corrected = entry.correctedTranscription, !corrected.isEmpty {
            return corrected
        }

        if let raw = entry.rawTranscription, !raw.isEmpty {
            return raw
        }

        return "Recording without transcription"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.createdAt, style: .time)
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                Text(String(format: "%.1fs", entry.audioDuration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(titleText)
                .font(.callout)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(SpeechModelCatalog.model(named: entry.speechModelID)?.statusName ?? entry.speechModelID)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isSelected ? Color.accentColor.opacity(0.35) : Color(nsColor: .separatorColor),
                    lineWidth: 1
                )
        )
    }
}

private struct TranscriptionLabResultStack<SupplementaryContent: View>: View {
    let rawTitle: String
    let rawText: String
    let correctedTitle: String
    let correctedText: String
    let supplementaryContent: SupplementaryContent?

    init(
        rawTitle: String,
        rawText: String,
        correctedTitle: String,
        correctedText: String,
        @ViewBuilder supplementaryContent: () -> SupplementaryContent
    ) {
        self.rawTitle = rawTitle
        self.rawText = rawText
        self.correctedTitle = correctedTitle
        self.correctedText = correctedText
        self.supplementaryContent = supplementaryContent()
    }

    init(
        rawTitle: String,
        rawText: String,
        correctedTitle: String,
        correctedText: String
    ) where SupplementaryContent == EmptyView {
        self.rawTitle = rawTitle
        self.rawText = rawText
        self.correctedTitle = correctedTitle
        self.correctedText = correctedText
        self.supplementaryContent = nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let supplementaryContent {
                supplementaryContent
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(rawTitle)
                    .font(.subheadline.weight(.medium))
                ReadOnlyTextPane(text: rawText, minHeight: 96, monospaced: false)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(correctedTitle)
                    .font(.subheadline.weight(.medium))
                ReadOnlyTextPane(text: correctedText, minHeight: 120, monospaced: false)
            }
        }
    }
}

private struct TranscriptionLabMetadataRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(.callout)
        }
    }
}

private struct ReadOnlyTextPane: View {
    let text: String
    let minHeight: CGFloat
    let monospaced: Bool

    var body: some View {
        ScrollView {
            Text(text)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(minHeight: minHeight)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}

private struct BorderedTextEditor: View {
    let text: Binding<String>
    let minHeight: CGFloat

    var body: some View {
        TextEditor(text: text)
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .frame(minHeight: minHeight)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
    }
}
