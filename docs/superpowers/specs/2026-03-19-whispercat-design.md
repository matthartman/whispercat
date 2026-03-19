# WhisperCat — Design Spec

**Date:** 2026-03-19
**Platform:** macOS (Apple Silicon, M1+)
**Language:** Swift
**Status:** Draft

## Overview

WhisperCat is a macOS menu bar app that provides system-wide hold-to-talk speech-to-text. Hold the Control key to record, release to transcribe and paste into the focused text field. Runs 100% locally using whisper.cpp — no external APIs.

## V1 Scope

### In
- Hold Control to record, release to transcribe + paste
- Local-only transcription via whisper.cpp with `small.en` model
- Menu bar-only app (no dock icon)
- Floating recording indicator pill at bottom of screen
- Sound effects on start/stop recording
- Menu bar icon changes while recording
- Clipboard save/restore around paste

### Out (future)
- Filler word removal ("um", "uh", etc.)
- Configurable model selection
- Configurable hotkey
- Punctuation/formatting options
- Multiple language support
- Launch at login (via SMAppService)
- Maximum recording duration cap

## Architecture

Pure Swift app using whisper.cpp via C interop. No external runtime dependencies.

### Project Structure

```
WhisperCat/
├── WhisperCatApp.swift          # App entry point, menu bar setup
├── Audio/
│   ├── AudioRecorder.swift      # AVFoundation mic capture → PCM buffer
│   └── SoundEffects.swift       # Play start/stop audio cues
├── Transcription/
│   ├── WhisperTranscriber.swift # whisper.cpp wrapper, runs inference
│   └── ModelManager.swift       # Loads/manages the .bin model file
├── Input/
│   ├── HotkeyMonitor.swift      # CGEvent tap for Control key down/up
│   └── TextPaster.swift         # Clipboard save → copy text → Cmd+V → clipboard restore
├── UI/
│   ├── MenuBarView.swift        # Menu bar icon + dropdown menu
│   └── RecordingOverlay.swift   # Floating pill at bottom of screen
└── Resources/
    ├── start.aiff               # Recording start sound
    └── stop.aiff                # Recording stop sound
```

### Dependencies

- **whisper.cpp** — vendored C source with a bridging header, added as a local Swift package. This gives full control over the build and avoids relying on third-party SPM wrappers that may lag behind upstream.
- **Model file** — `ggml-small.en.bin` (~466 MB). Downloaded separately (not checked into git) and placed in `Resources/` before building. A setup script (`scripts/download-model.sh`) fetches it from the official Hugging Face repo. The model is bundled into the app bundle at build time. Note: this makes the app ~500 MB.

## Data Flow

```
Control Key Down
  → HotkeyMonitor detects keyDown via CGEvent tap (.flagsChanged)
  → AudioRecorder.startRecording() — captures mic to in-memory PCM float buffer
  → SoundEffects.playStart()
  → RecordingOverlay appears (floating pill at bottom of screen)
  → Menu bar icon switches to recording state

Control Key Up
  → HotkeyMonitor detects keyUp
  → AudioRecorder.stopRecording() — returns PCM buffer
  → SoundEffects.playStop()
  → RecordingOverlay dismisses
  → Menu bar icon switches to idle
  → WhisperTranscriber.transcribe(buffer) — runs inference on background thread
  → On completion, dispatches back to main thread for paste
  → TextPaster pastes result (must run on main thread for NSPasteboard/CGEvent):
      1. Read and save current NSPasteboard contents
      2. Write transcribed text to NSPasteboard
      3. Simulate Cmd+V via CGEvent (50ms delay after clipboard write)
      4. Restore original clipboard contents (100ms delay after paste)
```

**Audio format:** 16kHz mono Float32 PCM — what whisper.cpp expects natively. Captured directly in this format via AVAudioEngine to avoid conversion overhead.

**Transcription is post-recording, not streaming.** On M1 with `small.en`, a 10-second clip transcribes in under a second.

## Component Details

### HotkeyMonitor
- Uses `CGEvent.tapCreate()` with `.flagsChanged` event mask
- Monitors for Control flag specifically
- **Only triggers when Control is pressed alone** — if another key is pressed simultaneously (Ctrl+C, Ctrl+A), recording does not start
- **Minimum hold duration: ~0.3 seconds** — shorter presses are ignored to avoid accidental triggers from normal Control key usage
- Requires **Accessibility permission**

### AudioRecorder
- Uses `AVAudioEngine` with input node tap
- Configures for 16kHz sample rate, mono channel, Float32 format
- Appends audio frames to an in-memory `[Float]` buffer during recording
- No file I/O during recording — everything in memory
- Requires **Microphone permission**

### WhisperTranscriber
- Loads model once at app startup, keeps it resident in memory
- Accepts PCM `[Float]` buffer, calls `whisper_full()` via C interop
- Runs on a dedicated background `DispatchQueue`
- Returns transcribed `String`
- Serial queue — if user records again while previous transcription is processing, the new one queues behind it

### TextPaster
- `NSPasteboard.general` for clipboard read/write
- `CGEvent` to simulate Cmd+V keystroke
- Timing: 50ms delay between clipboard write and paste, 100ms delay before clipboard restore. These are tunable constants — may need adjustment based on system load
- Requires **Accessibility permission** (same as HotkeyMonitor)

### RecordingOverlay
- Borderless, transparent `NSPanel` with `.floating` level
- Positioned at bottom center of screen
- SwiftUI content: small pill shape with pulsing red dot + "Recording..." text
- Appears/dismisses with animation
- Non-interactive (clicks pass through)

### MenuBarView
- SwiftUI-based menu bar extra
- Idle state: cat icon (SF Symbol `cat.fill` or custom asset)
- Recording state: red-tinted icon
- Dropdown menu items:
  - Status line ("Ready" / "Recording..." / "Transcribing...")
  - "Quit WhisperCat"

### SoundEffects
- Two bundled .aiff files for start/stop
- Played via `NSSound` or `AVAudioPlayer`
- Short, subtle sounds

## Permissions

| Permission | Used By | Purpose |
|-----------|---------|---------|
| Accessibility | HotkeyMonitor, TextPaster | Global event tap, keystroke simulation |
| Microphone | AudioRecorder | Audio capture |

Both are prompted automatically by macOS on first use. The app detects missing permissions and shows guidance in the menu bar dropdown with a button to open the relevant System Settings pane.

## Error Handling

| Scenario | Behavior |
|----------|----------|
| Permissions denied | Menu bar dropdown shows status + button to open System Settings |
| Short press (<0.3s) | Ignored, treated as normal Control keypress |
| Empty transcription | Skip paste, no-op |
| Control + other key | Don't trigger recording |
| No focused text field | Cmd+V goes nowhere, no error needed |
| Model fails to load | Error in menu bar dropdown, recording disabled |
| Record during transcription | Queue it, process serially |

## Build & Distribution

- **Xcode project** with Swift Package Manager for whisper.cpp dependency
- **Minimum deployment target:** macOS 14.0 (Sonoma) — supports Sequoia 15.5
- **App Sandbox:** Disabled (required for CGEvent tap and global accessibility)
- **Hardened Runtime:** Enabled with entitlements for accessibility and microphone
- **Distribution for v1:** Direct build from Xcode, no App Store
