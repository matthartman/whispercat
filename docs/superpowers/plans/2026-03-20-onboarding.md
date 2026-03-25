# Onboarding Flow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a first-run onboarding wizard that walks users through permissions, model download, and a live try-it step before they use GhostPepper.

**Architecture:** Single new file `OnboardingWindow.swift` contains the window controller and all 4 step views. `GhostPepperApp.swift` is modified to check `@AppStorage("onboardingCompleted")` and show onboarding before initializing AppState. The onboarding view creates its own HotkeyMonitor and AudioRecorder instances for the try-it step, keeping it decoupled from AppState.

**Tech Stack:** SwiftUI views hosted in NSWindow, existing PermissionChecker/ModelManager/HotkeyMonitor/AudioRecorder/WhisperTranscriber classes.

**Spec:** `docs/superpowers/specs/2026-03-20-onboarding-design.md`

---

### Task 1: Create OnboardingWindowController

**Files:**
- Create: `GhostPepper/UI/OnboardingWindow.swift`

- [ ] **Step 1: Create the window controller class**

```swift
// GhostPepper/UI/OnboardingWindow.swift
import SwiftUI
import AppKit
import AVFoundation

class OnboardingWindowController {
    private var window: NSWindow?

    func show(appState: AppState, onComplete: @escaping () -> Void) {
        dismiss()

        let onboardingView = OnboardingView(appState: appState, onComplete: { [weak self] in
            self?.dismiss()
            onComplete()
        })

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Ghost Pepper"
        window.contentView = NSHostingView(rootView: onboardingView)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    func dismiss() {
        window?.close()
        window = nil
    }
}
```

- [ ] **Step 2: Create the placeholder OnboardingView with step navigation**

Add below the controller in the same file:

```swift
struct OnboardingView: View {
    @ObservedObject var appState: AppState
    let onComplete: () -> Void
    @State private var currentStep = 1

    var body: some View {
        VStack {
            switch currentStep {
            case 1:
                WelcomeStep(onContinue: { currentStep = 2 })
            case 2:
                SetupStep(appState: appState, modelManager: appState.modelManager, onContinue: { currentStep = 3 })
            case 3:
                TryItStep(appState: appState, onContinue: { currentStep = 4 })
            case 4:
                DoneStep(onComplete: {
                    UserDefaults.standard.set(true, forKey: "onboardingCompleted")
                    onComplete()
                })
            default:
                EmptyView()
            }
        }
        .frame(width: 480, height: 520)
    }
}
```

- [ ] **Step 3: Verify the file compiles**

Run: `xcodegen generate && xcodebuild -project GhostPepper.xcodeproj -scheme GhostPepper -configuration Debug build -skipMacroValidation 2>&1 | grep -E "error:|BUILD"`

Note: this will fail until steps are defined — that's expected. Just verify no syntax errors in the controller/view scaffold.

- [ ] **Step 4: Commit**

```bash
git add GhostPepper/UI/OnboardingWindow.swift
git commit -m "feat: scaffold onboarding window controller and view"
```

---

### Task 2: Implement WelcomeStep (Step 1)

**Files:**
- Modify: `GhostPepper/UI/OnboardingWindow.swift`

- [ ] **Step 1: Add WelcomeStep view**

Add to `OnboardingWindow.swift`:

```swift
struct WelcomeStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .cornerRadius(24)

            Text("Ghost Pepper")
                .font(.system(size: 28, weight: .bold))

            Text("Hold-to-talk speech-to-text\nfor your Mac")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.green)
                Text("100% Private — Everything runs locally on your Mac.\nNo cloud, no accounts, no data ever leaves your machine.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.green.opacity(0.08))
                    .strokeBorder(Color.green.opacity(0.2))
            )
            .padding(.horizontal, 24)

            Spacer()

            Button(action: onContinue) {
                Text("Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .padding(.horizontal, 40)
            .padding(.bottom, 24)
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `xcodebuild -project GhostPepper.xcodeproj -scheme GhostPepper -configuration Debug build -skipMacroValidation 2>&1 | grep -E "error:|BUILD"`

Note: The `Image("AppIcon")` may need adjustment — asset catalog app icons are accessed differently. If it doesn't resolve, use `NSImage(named: NSImage.applicationIconName)` wrapped in an `Image(nsImage:)` instead.

- [ ] **Step 3: Commit**

```bash
git add GhostPepper/UI/OnboardingWindow.swift
git commit -m "feat: add welcome step with branding and privacy message"
```

---

### Task 3: Implement SetupStep (Step 2)

**Files:**
- Modify: `GhostPepper/UI/OnboardingWindow.swift`

- [ ] **Step 1: Add SetupStep view**

This view manages three items: mic permission, accessibility permission, and model download. Add to `OnboardingWindow.swift`:

```swift
struct SetupStep: View {
    @ObservedObject var appState: AppState
    @ObservedObject var modelManager: ModelManager
    let onContinue: () -> Void

    @State private var micGranted = false
    @State private var micDenied = false
    @State private var accessibilityGranted = false
    @State private var accessibilityTimer: Timer?
    @State private var modelLoadStarted = false

    private var allComplete: Bool {
        micGranted && accessibilityGranted && modelManager.isReady
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Setup")
                .font(.system(size: 24, weight: .bold))
                .padding(.top, 24)

            Text("Grant permissions and download the speech model")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                // Microphone
                SetupRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    subtitle: "To hear your voice",
                    isComplete: micGranted
                ) {
                    if micDenied {
                        Button("Open Settings") {
                            PermissionChecker.openMicrophoneSettings()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.small)
                    } else if !micGranted {
                        Button("Grant") {
                            Task {
                                let granted = await PermissionChecker.checkMicrophone()
                                micGranted = granted
                                if !granted {
                                    micDenied = true
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.small)
                    }
                }

                // Accessibility
                SetupRow(
                    icon: "keyboard.fill",
                    title: "Accessibility",
                    subtitle: "For the Control key hotkey & pasting",
                    isComplete: accessibilityGranted
                ) {
                    if !accessibilityGranted {
                        Button("Grant") {
                            PermissionChecker.promptAccessibility()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.small)
                    }
                }

                // Model download
                SetupRow(
                    icon: "brain",
                    title: "Speech Model",
                    subtitle: modelManager.state == .error
                        ? "Download failed"
                        : modelManager.isReady
                            ? "Ready"
                            : "Downloading...",
                    isComplete: modelManager.isReady
                ) {
                    if modelManager.state == .loading {
                        ProgressView()
                            .controlSize(.small)
                    } else if modelManager.state == .error {
                        Button("Retry") {
                            Task { await modelManager.loadModel() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.small)
                    }
                }
            }
            .padding(.horizontal, 24)

            Spacer()

            if allComplete {
                Button(action: {
                    stopAccessibilityPolling()
                    onContinue()
                }) {
                    Text("Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .padding(.horizontal, 40)
                .padding(.bottom, 24)
            } else {
                Text("Complete all items above to continue")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 24)
            }
        }
        .onAppear {
            // Check initial permission states
            micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            micDenied = AVCaptureDevice.authorizationStatus(for: .audio) == .denied
            accessibilityGranted = PermissionChecker.checkAccessibility()

            // Start model download
            if !modelLoadStarted && !modelManager.isReady {
                modelLoadStarted = true
                Task { await modelManager.loadModel() }
            }

            // Poll for accessibility
            startAccessibilityPolling()
        }
        .onDisappear {
            stopAccessibilityPolling()
        }
    }

    private func startAccessibilityPolling() {
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            let granted = PermissionChecker.checkAccessibility()
            if granted {
                accessibilityGranted = true
                stopAccessibilityPolling()
            }
        }
    }

    private func stopAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
    }
}
```

- [ ] **Step 2: Add the SetupRow helper view**

```swift
struct SetupRow<Actions: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    let isComplete: Bool
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 32)
                .foregroundStyle(isComplete ? .green : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
            } else {
                actions()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}
```

- [ ] **Step 3: Verify it compiles**

Run: `xcodebuild -project GhostPepper.xcodeproj -scheme GhostPepper -configuration Debug build -skipMacroValidation 2>&1 | grep -E "error:|BUILD"`

- [ ] **Step 4: Commit**

```bash
git add GhostPepper/UI/OnboardingWindow.swift
git commit -m "feat: add setup step with permissions and model download"
```

---

### Task 4: Implement TryItStep (Step 3)

**Files:**
- Modify: `GhostPepper/UI/OnboardingWindow.swift`

- [ ] **Step 1: Add TryItStep view**

This creates its own HotkeyMonitor and AudioRecorder via a `@StateObject` controller to keep decoupled from AppState and avoid storing reference types in `@State`:

```swift
@MainActor
class TryItController: ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var transcribedText: String?
    @Published var monitorStartFailed = false

    private var hotkeyMonitor: HotkeyMonitor?
    private var audioRecorder: AudioRecorder?
    private var hasAdvanced = false
    private var retryCount = 0
    private let maxRetries = 5
    private let transcriber: WhisperTranscriber

    init(transcriber: WhisperTranscriber) {
        self.transcriber = transcriber
    }

    func start(onAdvance: @escaping () -> Void) {
        let recorder = AudioRecorder()
        recorder.prewarm()
        self.audioRecorder = recorder

        let monitor = HotkeyMonitor()
        monitor.onRecordingStart = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isRecording = true
                try? recorder.startRecording()
            }
        }
        monitor.onRecordingStop = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isRecording = false
                self.isTranscribing = true
                let buffer = await recorder.stopRecording()
                let text = await self.transcriber.transcribe(audioBuffer: buffer)
                self.isTranscribing = false
                if let text {
                    self.transcribedText = text
                    // Auto-advance after 2 seconds (guarded)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        self?.advance(onAdvance: onAdvance)
                    }
                }
            }
        }

        if monitor.start() {
            self.hotkeyMonitor = monitor
        } else {
            retryStartMonitor(monitor: monitor)
        }
    }

    func advance(onAdvance: () -> Void) {
        guard !hasAdvanced else { return }
        hasAdvanced = true
        cleanup()
        onAdvance()
    }

    func cleanup() {
        hotkeyMonitor?.stop()
        hotkeyMonitor = nil
        audioRecorder = nil
    }

    private func retryStartMonitor(monitor: HotkeyMonitor) {
        guard retryCount < maxRetries else {
            monitorStartFailed = true
            return
        }
        retryCount += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            if monitor.start() {
                self?.hotkeyMonitor = monitor
            } else {
                self?.retryStartMonitor(monitor: monitor)
            }
        }
    }
}

struct TryItStep: View {
    @ObservedObject var appState: AppState
    let onContinue: () -> Void
    @StateObject private var controller: TryItController

    init(appState: AppState, onContinue: @escaping () -> Void) {
        self.appState = appState
        self.onContinue = onContinue
        self._controller = StateObject(wrappedValue: TryItController(transcriber: appState.transcriber))
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Try It")
                .font(.system(size: 24, weight: .bold))
                .padding(.top, 24)

            Text("Hold the **Control** key and say something")
                .font(.callout)
                .foregroundStyle(.secondary)

            // Keyboard visual
            HStack(spacing: 6) {
                KeyCap(label: "fn", highlighted: false)
                KeyCap(label: "⌃ control", highlighted: true, isActive: controller.isRecording)
                KeyCap(label: "⌥", highlighted: false)
                KeyCap(label: "⌘", highlighted: false)
            }
            .padding(.vertical, 8)

            // Status area
            VStack(spacing: 12) {
                if controller.isRecording {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(.red)
                            .frame(width: 10, height: 10)
                        Text("Recording...")
                            .foregroundStyle(.secondary)
                    }
                } else if controller.isTranscribing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Transcribing...")
                            .foregroundStyle(.secondary)
                    }
                } else if let text = controller.transcribedText {
                    VStack(spacing: 8) {
                        Text("\"\(text)\"")
                            .font(.body)
                            .italic()
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                            .padding(.horizontal, 24)

                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("It works! Your words will be pasted wherever your cursor is.")
                                .font(.callout)
                                .foregroundStyle(.green)
                        }
                    }
                } else if controller.monitorStartFailed {
                    Text("Could not start hotkey monitor.\nPlease verify Accessibility is enabled in System Settings.")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                } else {
                    Text("Waiting for you to hold Control...")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 100)

            Spacer()

            HStack {
                Button("Skip") {
                    controller.advance(onAdvance: onContinue)
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(action: {
                    controller.advance(onAdvance: onContinue)
                }) {
                    Text("Continue")
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 24)
        }
        .onAppear { controller.start(onAdvance: onContinue) }
        .onDisappear { controller.cleanup() }
    }
}
```

- [ ] **Step 2: Add the KeyCap helper view**

```swift
struct KeyCap: View {
    let label: String
    let highlighted: Bool
    var isActive: Bool = false

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: highlighted ? .semibold : .regular))
            .foregroundStyle(highlighted ? .white : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(highlighted
                        ? (isActive ? Color.red : Color.orange)
                        : Color(nsColor: .controlBackgroundColor))
            )
            .animation(.easeInOut(duration: 0.2), value: isActive)
    }
}
```

- [ ] **Step 3: Verify it compiles**

Run: `xcodebuild -project GhostPepper.xcodeproj -scheme GhostPepper -configuration Debug build -skipMacroValidation 2>&1 | grep -E "error:|BUILD"`

- [ ] **Step 4: Commit**

```bash
git add GhostPepper/UI/OnboardingWindow.swift
git commit -m "feat: add try-it step with live recording and transcription"
```

---

### Task 5: Implement DoneStep (Step 4)

**Files:**
- Modify: `GhostPepper/UI/OnboardingWindow.swift`

- [ ] **Step 1: Add DoneStep view**

```swift
struct DoneStep: View {
    let onComplete: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("You're All Set!")
                .font(.system(size: 28, weight: .bold))

            Text("Ghost Pepper lives in your menu bar")
                .font(.callout)
                .foregroundStyle(.secondary)

            // Menu bar mockup
            HStack(spacing: 12) {
                Spacer()
                Text("Wi-Fi")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image("MenuBarIcon")
                    .renderingMode(.template)
                    .foregroundStyle(.primary)
                Text("3:42 PM")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .padding(.horizontal, 60)

            VStack(alignment: .leading, spacing: 8) {
                Text("From the menu bar you can:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                BulletPoint("Switch your microphone")
                BulletPoint("Toggle text cleanup on/off")
                BulletPoint("Edit the cleanup prompt")
                BulletPoint("Check for updates")
            }
            .padding(.horizontal, 40)

            Spacer()

            Button(action: onComplete) {
                Text("Start Using Ghost Pepper")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .padding(.horizontal, 40)
            .padding(.bottom, 24)
        }
    }
}

struct BulletPoint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `xcodebuild -project GhostPepper.xcodeproj -scheme GhostPepper -configuration Debug build -skipMacroValidation 2>&1 | grep -E "error:|BUILD"`

- [ ] **Step 3: Commit**

```bash
git add GhostPepper/UI/OnboardingWindow.swift
git commit -m "feat: add done step with menu bar guide"
```

---

### Task 6: Wire onboarding into GhostPepperApp

**Files:**
- Modify: `GhostPepper/GhostPepperApp.swift`

- [ ] **Step 1: Add onboarding check to app entry point**

Modify `GhostPepperApp.swift` to check `onboardingCompleted` and show the onboarding window if false. Key changes:

1. Add `@AppStorage("onboardingCompleted") private var onboardingCompleted = false`
2. Add `private let onboardingController = OnboardingWindowController()`
3. In `.onAppear`, check `onboardingCompleted`:
   - If false: call `onboardingController.show(appState: appState) { onboardingCompleted = true; Task { await appState.initialize() } }`
   - If true: call `appState.initialize()` as before

The current `.onAppear` block is:
```swift
.onAppear {
    guard !hasInitialized else { return }
    hasInitialized = true
    Task {
        await appState.initialize()
    }
}
```

Replace with:
```swift
.onAppear {
    guard !hasInitialized else { return }
    hasInitialized = true
    if onboardingCompleted {
        Task { await appState.initialize() }
    } else {
        onboardingController.show(appState: appState) {
            Task { await appState.initialize() }
        }
    }
}
```

Add properties:
```swift
@AppStorage("onboardingCompleted") private var onboardingCompleted = false
private let onboardingController = OnboardingWindowController()
```

- [ ] **Step 2: Verify it compiles and builds**

Run: `xcodegen generate && xcodebuild -project GhostPepper.xcodeproj -scheme GhostPepper -configuration Debug build -skipMacroValidation 2>&1 | grep -E "error:|BUILD"`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Manual test — reset onboarding and launch**

```bash
defaults delete com.github.matthartman.ghostpepper onboardingCompleted 2>/dev/null
```

Then build and run. The onboarding window should appear. Walk through all 4 steps. After completing, quit and relaunch — the onboarding should NOT appear again.

- [ ] **Step 4: Commit**

```bash
git add GhostPepper/GhostPepperApp.swift GhostPepper/UI/OnboardingWindow.swift
git commit -m "feat: wire onboarding into app launch flow"
```

---

### Task 7: Polish and edge case handling

**Files:**
- Modify: `GhostPepper/UI/OnboardingWindow.swift`

- [ ] **Step 1: Test edge cases**

1. Reset onboarding: `defaults delete com.github.matthartman.ghostpepper onboardingCompleted`
2. Launch app — verify onboarding shows
3. Grant mic on step 2 — verify checkmark appears
4. Grant accessibility on step 2 — verify polling detects it
5. Wait for model download — verify spinner then checkmark
6. Test try-it step — hold Control, speak, verify text appears
7. Verify step 4 shows menu bar info
8. Click "Start Using Ghost Pepper" — verify window closes and app initializes normally
9. Relaunch — verify onboarding does NOT show

- [ ] **Step 2: Test skip flow**

1. Reset onboarding
2. Launch, go through to step 3
3. Click "Skip" — verify it advances to step 4
4. Complete — verify app works normally

- [ ] **Step 3: Final commit**

```bash
git add -A
git commit -m "feat: polish onboarding flow and handle edge cases"
```
