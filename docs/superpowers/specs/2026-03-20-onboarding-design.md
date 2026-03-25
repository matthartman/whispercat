# Onboarding Flow Design

## Overview

First-run onboarding wizard for GhostPepper. Shows once on first launch, walks the user through permissions, model download, and a live "try it" step. Persists completion to UserDefaults so it never shows again.

## Flow

### Step 1: Welcome

- App icon (from asset catalog) displayed prominently for branding
- "Ghost Pepper" title + "Hold-to-talk speech-to-text for your Mac" tagline
- Privacy callout: "100% Private — Everything runs locally on your Mac. No cloud, no accounts, no data ever leaves your machine."
- "Get Started" button advances to step 2

### Step 2: Setup (Permissions + Model Download)

Three items, each with status indicator:

1. **Microphone** — "To hear your voice". Grant button triggers `AVCaptureDevice.requestAccess(for: .audio)`. Shows checkmark when granted. If previously denied, show "Open System Settings" button that calls `PermissionChecker.openMicrophoneSettings()`.
2. **Accessibility** — "For the Control key hotkey & pasting". Grant button calls `PermissionChecker.promptAccessibility()` and opens System Settings. Polls `PermissionChecker.checkAccessibility()` every 2 seconds to detect when granted. Stops polling once granted or when leaving step 2.
3. **Speech Model** — indeterminate progress indicator (spinner + "Downloading speech model...") since `ModelManager` does not expose download progress. Starts automatically when step 2 appears via `modelManager.loadModel()`. Shows checkmark when `modelManager.state == .ready`. Shows error with retry button if download fails.

"Continue" button appears only when all three are complete (mic granted, accessibility granted, model loaded).

### Step 3: Try It

- "Hold the **Control** key and say something"
- Visual showing a keyboard with the Control key highlighted
- Text area shows the transcription result
- On success: "It works! Your words will be pasted wherever your cursor is."
- Continue button always visible; auto-advances 2 seconds after successful transcription
- Skip button for users who want to move on without testing

**HotkeyMonitor ownership:** The onboarding view creates its own `HotkeyMonitor` instance with callbacks routed to a local handler that records audio via `AudioRecorder` and transcribes via `WhisperTranscriber.transcribe()`. This is separate from `AppState`'s monitor. The onboarding monitor is stopped and released when leaving step 3.

**Transcription contract for try-it:** Call `AudioRecorder.startRecording()` / `stopRecording()` directly, then `WhisperTranscriber.transcribe(audioBuffer:)`. Display the returned text in the onboarding window. No sound effects, no overlay, no cleanup, no paste, no logging. This avoids modifying `AppState`.

**HotkeyMonitor start retry:** If `HotkeyMonitor.start()` returns false (accessibility not yet applied by system), retry every 2 seconds up to 5 times, then show a message asking the user to go back to step 2 and verify accessibility is granted.

### Step 4: Done

- "You're All Set!"
- Menu bar mockup showing where the ghost pepper icon lives
- List of what's available in the menu bar: switch mic, toggle cleanup, edit prompt, check for updates
- "Start Using Ghost Pepper" button closes the onboarding window and marks onboarding complete

## Technical Design

### New Files

- `GhostPepper/UI/OnboardingWindow.swift` — SwiftUI view for the onboarding wizard, all 4 steps in a single view with step state management. Also contains an `OnboardingWindowController` (NSWindowController subclass) for presenting the window, following the pattern used in `PromptEditorWindow.swift`.

### Modified Files

- `GhostPepper/GhostPepperApp.swift` — check `@AppStorage("onboardingCompleted")` on launch; if false, show onboarding window and defer `appState.initialize()` until onboarding completes

### State Management

- `@AppStorage("onboardingCompleted")` Bool, default false — set to true when user clicks "Start Using Ghost Pepper" in step 4
- Step state is local to the onboarding view (`@State private var currentStep: Int`)
- Permission states polled/observed within the onboarding view
- Model download state observed from existing `ModelManager` (shared instance from `AppState`)

### Window Presentation

- NSWindow centered on screen, ~480px wide, fixed size, not resizable
- Style mask without `.closable` — user must complete or quit the app. This avoids ambiguity between closing the window and quitting mid-onboarding
- Call `NSApp.activate(ignoringOtherApps: true)` when presenting to ensure the window appears in front (required for LSUIElement apps)
- App stays as LSUIElement (no dock icon)
- After onboarding completes, the window closes and `appState.initialize()` is called

### Post-Onboarding Initialization

After onboarding completes, `appState.initialize()` is called normally. Because:
- `modelManager.loadModel()` guards against re-loading when already in `.ready` state — the model step is a no-op
- The mic permission check will pass since it was granted in onboarding
- Only the hotkey monitor start, audio prewarm, and optional cleanup model load are new work at that point

### Edge Cases

- **User quits during onboarding:** Onboarding shows again on next launch (not marked complete until step 4 button clicked)
- **User has already granted permissions** from a previous install: Items show as already complete with checkmarks, user clicks through quickly
- **Model download fails:** Show error with retry button on step 2
- **Accessibility denied repeatedly:** Show "Open System Settings" button with manual instructions
- **Mic previously denied:** Show "Open System Settings" button calling `PermissionChecker.openMicrophoneSettings()`
- **User skips try-it step:** Still proceeds to step 4 and can complete onboarding
- **Accessibility lag after granting:** HotkeyMonitor retries up to 5 times on step 3, with fallback message
