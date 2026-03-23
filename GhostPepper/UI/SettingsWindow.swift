import SwiftUI
import AppKit
import CoreAudio
import ServiceManagement
import AVFoundation

class SettingsWindowController {
    private var window: NSWindow?

    func show(appState: AppState) {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(appState: appState)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 580),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Ghost Pepper Settings"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }
}

// MARK: - Mic Level Monitor for Settings

@MainActor
class SettingsMicMonitor: ObservableObject {
    @Published var level: Float = 0
    private var engine: AVAudioEngine?
    private var isRunning = false

    func start() {
        guard !isRunning else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frames {
                let sample = channelData[0][i]
                sum += sample * sample
            }
            let rms = sqrtf(sum / Float(max(frames, 1)))
            let normalized = min(rms * 10, 1.0)
            Task { @MainActor [weak self] in
                self?.level = normalized
            }
        }

        do {
            try engine.start()
            self.engine = engine
            isRunning = true
        } catch {}
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRunning = false
        level = 0
    }

    func restart() {
        stop()
        start()
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var selectedDeviceID: AudioDeviceID = 0
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @StateObject private var micMonitor = SettingsMicMonitor()
    private let promptEditor = PromptEditorController()

    var body: some View {
        Form {
            Section("Input") {
                Picker("Microphone", selection: $selectedDeviceID) {
                    ForEach(inputDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .onChange(of: selectedDeviceID) { _, newValue in
                    AudioDeviceManager.setDefaultInputDevice(newValue)
                    micMonitor.restart()
                }

                // Mic level meter
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(nsColor: .controlBackgroundColor))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(micMonitor.level > 0.7 ? .red : micMonitor.level > 0.3 ? .orange : .green)
                                .frame(width: geo.size.width * CGFloat(micMonitor.level))
                                .animation(.easeOut(duration: 0.08), value: micMonitor.level)
                        }
                    }
                    .frame(height: 8)

                    Text("Level")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Enable cleanup", isOn: $appState.cleanupEnabled)
                    .onChange(of: appState.cleanupEnabled) { _, enabled in
                        Task {
                            if enabled {
                                await appState.textCleanupManager.loadModel()
                            } else {
                                appState.textCleanupManager.unloadModel()
                            }
                        }
                    }

                if appState.cleanupEnabled {
                    Button("Edit Cleanup Prompt...") {
                        promptEditor.show(appState: appState)
                    }

                    if appState.textCleanupManager.state == .error {
                        Text(appState.textCleanupManager.errorMessage ?? "Error loading model")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            } header: {
                Text("Cleanup")
            } footer: {
                Text("When enabled, a local AI model cleans up your transcriptions — removing filler words like \"um\" and \"uh\", and handling self-corrections.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
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

            Section {
                ModelStatusRow(
                    name: "WhisperKit (speech-to-text)",
                    isLoaded: appState.modelManager.isReady
                )
                ModelStatusRow(
                    name: "Qwen3 1.7B (fast cleanup)",
                    isLoaded: appState.textCleanupManager.fastLLM != nil
                )
                ModelStatusRow(
                    name: "Qwen3.5 4B (full cleanup)",
                    isLoaded: appState.textCleanupManager.fullLLM != nil
                )
            } header: {
                Text("Models")
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 420, height: 580)
        .onAppear {
            inputDevices = AudioDeviceManager.listInputDevices()
            selectedDeviceID = AudioDeviceManager.defaultInputDeviceID() ?? 0
            micMonitor.start()
        }
        .onDisappear {
            micMonitor.stop()
        }
    }
}

struct ModelStatusRow: View {
    let name: String
    let isLoaded: Bool

    var body: some View {
        HStack {
            Text(name)
                .font(.callout)
            Spacer()
            if isLoaded {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text("Loaded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "circle")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Text("Not loaded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
