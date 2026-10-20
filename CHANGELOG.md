# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project adheres to Semantic Versioning.

## [Unreleased]
- Add a separately selectable Whisper Turbo 20240930 export, preserving the legacy and Compacto models; support repeated local PT-BR benchmark runs.
- Replace the shared AppKit global key-down observer with a passive, session-level Core Graphics listener after physical typing duplication recurred; preserve local event handling and legitimate repeats without replaying or swallowing keys.
- Add a downloaded, language-compatible model picker to meeting setup, with explicit experimental fast PT-BR and higher-fidelity choices, separate from dictation preferences; keep the chosen model pinned in saved meetings.
- Use short, validated local-summary source indices instead of model-copied UUIDs; normalize absent metadata and repeated citations without relaxing source validation. Add real Apple Intelligence regression checks for Portuguese microphone tests.
- Share one native global key-down observer between Fn cancellation and recorder Escape handling; make recorder observer registration idempotent instead of adding overlapping global observers.
- Use login-session auto-paste events with an explicit Command release instead of posting into hardware keyboard input; add event-sequence regression tests without sending real keystrokes.
- Fix meeting audio conversion packet sizing; publish speech at pause boundaries instead of fixed 15-second blocks, omit dictation vocabulary prompts and suppress music-only transcript artifacts.
- Simplify meetings into Transcript/Summary tabs with readable controls, microphone levels, explicit processing progress, saved-audio playback and full reprocessing.
- Keep meeting models reserved until capture and decoding drain after failures; prevent playback during microphone capture or dictation.
- Add manual in-person/online meetings with local Whisper transcription, durable audio segments, interruption recovery, PT-BR screens and Markdown export.
- Add optional local Apple Intelligence summaries and explicitly confirmed text-only OpenAI summaries with a separate Keychain credential and configurable model.
- Fix: missing Accessibility permission now shows actionable auto-paste instructions after dictation in all builds, keeping the transcript available for manual paste.
- Optional Fn double-tap locks hands-free recording in Hold mode; press Fn again to finish or Esc to cancel. Includes Brazilian Portuguese settings text.
- Models are now warmed up as soon as they finish downloading (and when you pick one), so the first dictation no longer stalls on "warming up".
- Fix: the recorder's warming-up message was clipped mid-word, and pressing esc left it wedged on screen. It now shows the real loading stage, elapsed time, and settles back to idle.
- Fix: the recommended model on the AI Models screen now shows download progress, a cancel button, and the actual reason a download failed (with a retry) instead of a Download button that appeared to do nothing.
- Fix: a half-finished Parakeet download is no longer reported as installed.

## [1.3.0] - 2026-07-10
- 

## [1.2.3] - 2026-07-03
- 

## [1.2.2] - 2026-07-03
- 

## [1.2.1] - 2026-07-03
- 

## [1.2.0] - 2026-07-03
- 

## [1.1.0] - 2026-06-28
- 

## [1.0.29] - 2026-03-24
- 

## [1.0.28] - 2026-03-22
- 

## [1.0.27] - 2026-03-22
- 

## [1.0.25] - 2026-03-21
- 

## [1.0.24] - 2026-03-12
- 

## [1.0.23] - 2026-02-27
- 

## [1.0.22] - 2026-02-27
- 

## [1.0.21] - 2026-02-17
- 

## [1.0.20] - 2026-02-17
- 

## [1.0.19] - 2026-02-16
- 

## [1.0.18] - 2026-02-16
- 

## [1.0.17] - 2026-02-16
- 

## [1.0.16] - 2026-02-15
- 

## [1.0.15] - 2026-02-15
- 

## [1.0.14] - 2026-02-15
- 

## [1.0.13] - 2026-02-15
- 

## [1.0.12] - 2026-02-15
- 

## [1.0.11] - 2026-02-15
- 

## [1.0.10] - 2026-02-14
- 

## [1.0.7] - 2026-02-03
- 

## [1.0.6] - 2026-02-03
- 

## [1.0.5] - 2026-01-27
- 
