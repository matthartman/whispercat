# FluidAudio Diarization Design

## Goal

Add a first-pass `Ignore other speakers` feature that works only on the `FluidAudio` speech path, uses diarization to follow the first substantial speaker in a recording, and improves stop-and-paste dictation without exposing live transcript UI.

## Why

Ghost Pepper is still a stop-and-paste app, but the longer-term platform direction is broader:

- multi-speaker continuous conversation transcripts
- online analysis over a live session
- richer speaker-aware transcript tooling

The first product need is narrower:

- reduce contamination from other people speaking in the room
- keep the final transcript focused on Jesse’s voice in the common push-to-talk case

This feature should therefore do two things at once:

- ship a practical stop-and-paste improvement now
- avoid baking more one-shot assumptions into the recording pipeline

## Scope

In scope:

- add a Recording-pane toggle: `Ignore other speakers`
- show that toggle at all times
- enable it only when the selected speech model uses `FluidAudio`
- keep it disabled, with no note, for `WhisperKit` models
- run diarization only on the `FluidAudio` path
- identify the first substantial speaker in the recording and keep that speaker’s later spans
- transcribe only the kept spans
- run cleanup as normal after the final speaker-filtered transcript is produced
- preserve just enough chunk-oriented session structure to avoid an offline-only dead end
- expose diarization visualization only in the Transcription Lab

Out of scope for V1:

- diarization for `WhisperKit`
- live transcript UI
- speaker enrollment or saved speaker profiles
- overlap-aware source separation
- multi-speaker final transcripts
- speaker labels in pasted output

## Product Behavior

### Recording Settings

Add one new setting in the `Recording` pane:

- `Ignore other speakers`

Behavior:

- if the selected speech model is `FluidAudio`, the user can enable or disable it
- if the selected speech model is `WhisperKit`, the toggle remains visible but disabled
- there is no explanatory note under the disabled toggle

### Live Dictation Behavior

When `Ignore other speakers` is off:

- Ghost Pepper behaves exactly as it does today

When `Ignore other speakers` is on and the selected speech model uses `FluidAudio`:

1. record audio normally
2. process diarization incrementally while recording is in progress
3. track the first substantial speaker for that session
4. on stop, finalize that speaker’s kept spans
5. transcribe only the kept spans with the selected `FluidAudio` speech model
6. run cleanup normally on the finalized transcript
7. paste the final cleaned result

The user still only sees one final transcript after stop.

There is no live partial transcript UI in this feature.

## First-Speaker Heuristic

V1 intentionally uses a simple rule:

- the first substantial speaker detected in the recording becomes the target speaker

“Substantial” means:

- not a tiny fragment or incidental noise
- at least `0.5s` of cumulative voiced speech

The cumulative duration may be made up of multiple spans from the same speaker.

Target selection rule:

- diarization may revise provisional speaker spans while recording is in progress
- Ghost Pepper does not permanently lock the target speaker during recording
- on stop, Ghost Pepper uses the finalized diarization output and selects the earliest speaker in time order whose cumulative voiced speech reaches `0.5s`
- if no speaker reaches that threshold, the feature falls back to the normal full-audio transcript path

Known failure case Jesse explicitly accepts:

- if somebody else speaks first, Ghost Pepper may follow the wrong speaker for that recording

This is acceptable for V1.

## Why `Sortformer`

Use `FluidAudio`’s `Sortformer` diarization path for V1.

Reasons:

- it is a better fit for streaming-capable processing than a purely batch-only design
- its likely failure mode is missing quieter speech rather than aggressively misassigning speakers
- that is a better tradeoff for `Ignore other speakers`, where false inclusions are usually worse than a few missed words
- it aligns better with the future platform direction than building around a one-off offline-only diarizer

This design does not require exposing streaming transcript UI, but it does benefit from a streaming-capable diarization engine internally.

## Architecture

### Design Principle

Keep V1 architecture intentionally small:

- internal diarization work may run incrementally during recording
- the user only sees the final result after stop
- do not introduce more abstractions than this feature needs right now

This avoids painting the app into an offline-only corner while still keeping the implementation proportional to one toggle.

### Core Components

#### RecordingSessionCoordinator

Owns one active dictation session only when `Ignore other speakers` is enabled on a `FluidAudio` model.

Responsibilities:

- receive audio chunks from the recorder
- append those chunks to an in-memory session buffer
- feed those chunks into the active `FluidAudio` diarization/transcription helper
- own session lifecycle
- finalize diarization metadata and filtered audio when recording stops

V1 does not need a general-purpose transcript timeline type or a separate chunk-persistence subsystem.

#### FluidAudioSpeechSession

Wraps the `FluidAudio`-specific work for one active recording.

Responsibilities:

- own the active Sortformer diarizer
- accept 16 kHz mono Float32 chunks
- maintain provisional speaker spans
- finalize kept spans at stop
- merge nearby kept spans with a small gap tolerance
- extract filtered audio for transcription
- run `FluidAudio` ASR on the filtered audio

This keeps backend-specific behavior out of `AppState` without forcing `ModelManager` to become a much larger abstraction than it is today.

#### DiarizationSummary

Represents the final speaker-attribution result for one completed recording.

Responsibilities:

- store finalized diarized spans
- mark which spans were kept
- record target-speaker coverage and whether fallback occurred

This is the data model the lab and archive system consume. V1 does not need to persist provisional revisions.

## Data Flow

### Recording Start

1. `AudioRecorder` starts capturing as it does today
2. if the selected speech model is `FluidAudio` and `Ignore other speakers` is enabled:
   - `RecordingSessionCoordinator` opens a new session
   - audio chunks are appended to the active session buffer
   - feed chunks into `FluidAudioSpeechSession`
3. if the setting is off, or the model is `WhisperKit`, skip session creation and use the existing path unchanged

### Recording Stop

If diarization is inactive:

- use the existing transcription path

If diarization is active:

1. finalize speaker spans
2. select the target speaker using the first-substantial-speaker rule
3. merge the kept spans
4. build filtered audio from those spans
5. transcribe the filtered audio with the active `FluidAudio` speech model
6. run cleanup normally
7. paste normally

## Fallback Rules

The feature should fail soft.

If any of the following happens:

- diarization initialization fails
- diarization returns no usable speaker spans
- no speaker reaches the `0.5s` cumulative voiced-speech threshold
- merged kept spans total less than `0.75s` of audio
- filtered audio extraction fails
- filtered-audio ASR returns `nil` or an empty transcript

then Ghost Pepper should fall back to the normal full-audio transcript path for that recording.

This avoids losing dictation completely when the speaker filter is uncertain or broken.

V1 should not attempt a semantic “degraded transcript” detector beyond these measurable fallback rules.

## Recorder Contract

`AudioRecorder` currently exposes a final 16 kHz mono Float32 buffer at stop.

V1 needs one additional seam:

- a chunk callback from the same converted 16 kHz mono Float32 capture path Ghost Pepper already uses for final transcription

Required contract:

- sample format: 16 kHz mono Float32
- chunk source: the existing converted recorder path, not a second parallel capture path
- chunk timing: monotonic chunk order plus sample-count-derived offsets, not wall-clock timestamps
- chunk delivery: aggregate logical diarization chunks from the converted sample stream instead of forcing the recorder to emit a new fixed hardware chunk size

The full final buffer should still be assembled exactly as it is today so the app can fall back to the normal path without special reconstruction logic.

## Model-Manager Seam

`ModelManager` should remain responsible for:

- speech model identity
- model loading and readiness
- whole-buffer transcription on the existing path

V1 should not force `ModelManager` to absorb diarization session orchestration.

Instead:

- `ModelManager` exposes enough `FluidAudio` access for a `FluidAudioSpeechSession` to use the already-loaded backend safely
- `WhisperKit` continues using the existing one-shot path unchanged

This keeps the current backend split explicit instead of making `ModelManager` a vague catch-all service.

## Archive Schema For Lab Visualization

For recordings created while `Ignore other speakers` is enabled on a `FluidAudio` model, archive one final diarization summary alongside the existing lab entry.

Persist:

- whether speaker filtering was enabled
- whether speaker filtering actually ran
- whether the session fell back to full-audio transcription
- finalized diarized spans:
  - start time
  - end time
  - speaker id
  - kept vs discarded
- target speaker id, if one was selected
- total kept-audio duration

Do not persist:

- provisional diarization revisions
- intermediate target-speaker guesses
- a second stored unfiltered transcript for the same live run

The archive write happens when the live recording finishes, at the same time Ghost Pepper stores the original raw and cleaned transcript data for the lab.

## Lab Behavior

The Transcription Lab is the only place where diarization is visualized.

For archived `FluidAudio` recordings created with `Ignore other speakers` enabled, show:

- diarized speaker spans across the clip
- which spans were kept
- which spans were discarded
- the original filtered transcript result

If the user wants a filtered-vs-unfiltered comparison, the lab can produce that comparison by rerunning the selected recording with the setting toggled on and off. V1 does not need to archive two transcripts for every live run.

This is a debugging and trust-building surface, not a production interaction model.

The normal live dictation UI should not gain new speaker visuals.

## Current Codebase Reality

This design follows the existing seams in the current branch:

- `SpeechModelCatalog` already distinguishes `WhisperKit` vs `FluidAudio`
- `ModelManager` already branches loading and transcription by backend
- `SettingsWindow` already owns the `Recording` pane and Transcription Lab UI
- `AppState` already coordinates recording, transcription, cleanup, and performance logging

That means V1 can be added by extending the current app structure instead of rewriting the speech stack.

## File Responsibilities

### Existing files likely to change

- `GhostPepper/AppState.swift`
  - own the new setting and route live recordings through diarization when applicable
- `GhostPepper/Transcription/ModelManager.swift`
  - expose enough backend capability to support `FluidAudioSpeechSession`
- `GhostPepper/Transcription/SpeechModelCatalog.swift`
  - expose whether a speech model supports speaker filtering
- `GhostPepper/UI/SettingsWindow.swift`
  - add the visible-but-disabled `Ignore other speakers` toggle in Recording
  - add diarization visualization in the lab
- `GhostPepper/Audio/AudioRecorder.swift`
  - expose audio chunk data cleanly if the current API is too buffer-oriented

### New files likely to be added

- `GhostPepper/Transcription/RecordingSessionCoordinator.swift`
- `GhostPepper/Transcription/FluidAudioSpeechSession.swift`
- `GhostPepper/Transcription/DiarizationSummary.swift`

These names describe domain responsibilities, not implementation history.

## Error Handling

The feature should not create a new user-facing error mode for ordinary dictation.

User-facing rule:

- if speaker filtering cannot be completed safely, return the normal full-audio transcript

Debug visibility:

- log whether diarization was active
- log whether it selected a target speaker
- log whether it fell back to the full-audio path
- log kept-span coverage for the session
- log whether filtered-audio ASR returned an empty result

This gives enough information for tuning without scaring the user with new failures.

## Performance

Without overlap, diarization would add noticeable post-stop latency.

V1 should therefore overlap diarization work with recording:

- feed diarization incrementally during the recording
- keep most diarization cost off the post-stop critical path

At stop, the app should only need to:

- finalize spans
- extract kept audio
- run ASR
- run cleanup

This is a major reason to use a streaming-capable diarization core even though the user never sees partial text.

## Testing

### Unit tests

- first-substantial-speaker selection
- cumulative-threshold target selection across multiple spans
- kept/discarded span decisions
- span merging and gap tolerance
- fallback to full-audio transcription when diarization yields no safe result
- fallback to full-audio transcription when filtered ASR returns an empty result
- `Ignore other speakers` is disabled for `WhisperKit` models and enabled for `FluidAudio`

### Integration tests

- `FluidAudio` dictation with speaker filtering enabled routes through diarization and filtered transcription
- `WhisperKit` dictation ignores the setting and uses the existing path
- cleanup still runs on the final transcript exactly once
- transcription lab can render kept vs discarded spans for archived runs that recorded diarization metadata

### Performance verification

- compare stop-to-paste latency with and without speaker filtering on representative clips
- verify that overlapping diarization work during recording keeps post-stop overhead acceptable

## Risks

### Wrong first speaker

If someone else speaks first, V1 will follow the wrong person.

This is accepted for the first version.

### Overlapping speech

Diarization is not source separation.

If multiple people talk over each other, V1 may still include contamination or miss words. This is a product limitation, not an implementation bug.

### Backend split

`WhisperKit` remains in the app without diarization support.

This keeps product risk down now, but the speech stack remains more complex than a future FluidAudio-only architecture.

## Recommended Implementation Order

1. add the new setting and speech-model capability plumbing
2. add chunk delivery from the existing recorder path
3. add `FluidAudioSpeechSession` and `DiarizationSummary`
4. integrate `FluidAudio` diarization behind the new setting
5. archive finalized diarization metadata for lab use
6. add lab visualization
7. add performance logging and fallback diagnostics

## Success Criteria

This feature is successful when:

- Ghost Pepper can ignore side speakers in common push-to-talk recordings on `FluidAudio`
- the setting is visible in Recording and disabled cleanly for `WhisperKit`
- ordinary dictation still returns a transcript even when diarization cannot produce a safe result
- the lab makes diarization decisions inspectable without adding new complexity to the live product
- the internal session architecture is a credible base for future speaker-aware streaming features
