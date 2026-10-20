# Modo Reunião Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Entregar captura manual de reuniões presenciais e online, transcrição local durável em português e resumos locais ou remotos sob escolha explícita.

**Architecture:** Criar domínio, armazenamento, captura e coordenação de reuniões separados do fluxo de ditado; compartilhar somente o roteador de ASR após serializar o acesso ao modelo. Uma fila limitada transcreve segmentos fechados persistidos no disco; provedores independentes geram resumos e a interface apresenta lista, sessão ativa, detalhe e exportação sem usar clipboard.

**Tech Stack:** Swift, SwiftUI, AVFoundation, ScreenCaptureKit, Foundation, FoundationModels (opcional no macOS 26+), URLSession, Keychain e XCTest.

**Spec:** `docs/superpowers/specs/2026-10-20-meeting-mode-design.md`

**Execution status (2026-10-20):** Implementado e revisado independentemente. Suíte completa: 268 testes, 2 pulados, 0 falhas. Validações manuais de captura real, qualidade dos resumos PT-BR e sessão de 60 minutos continuam pendentes; nenhuma chamada de resumo remoto real foi feita. As etapas abaixo preservam o roteiro original e seus critérios de aceite.

## Global Constraints

- Deployment target permanece macOS 14.0.
- Gravação/transcrição local é o caminho padrão; nenhum fallback remoto silencioso.
- Transcrição remota e upload de áudio não fazem parte da primeira versão.
- Resumo na nuvem envia somente texto após confirmação explícita por reunião.
- Áudio só é removido por ação explícita do usuário; armazenamento usa manifesto versionado e gravação atômica.
- Reunião nunca aciona colagem automática nem altera o fluxo de ditado/Fn.
- Exibir fontes e falhas; não declarar captura online completa se uma fonte tiver lacuna.
- Primeiro adaptador remoto: OpenAI Responses API, modelo configurável com `gpt-4.1-mini` como padrão inicial; credencial opcional no Keychain, nunca em `UserDefaults` ou logs.
- FoundationModels é opcional, condicionado a macOS 26+, disponibilidade do sistema e suporte ao idioma escolhido.

## Review Focus

- Encerramento abrupto com gravação em andamento deve recuperar apenas segmentos fechados e não recomeçar a captura; cobrir em `MeetingStoreTests.testRecoveryMarksOpenMeetingInterruptedAndKeepsClosedSegments`.
- Disco cheio/indisponível não pode perder silêncio de forma invisível nem manter gravação ativa; cobrir em `MeetingCoordinatorTests.testSegmentWriteFailureStopsCaptureAndPersistsFailure`.
- Queda de uma fonte online deve marcar lacuna e manter a outra fonte utilizável; cobrir em `MeetingCoordinatorTests.testSourceFailureMarksGapWithoutClaimingCompleteCapture`.
- Conteúdo da reunião não pode ir à nuvem sem confirmação explícita; cobrir em `MeetingSummaryServiceTests.testCloudProviderIsNotCalledBeforeConsent`.
- Resposta do modelo pode conter estrutura inválida ou referências inexistentes; cobrir em `MeetingSummaryServiceTests.testRejectsInvalidSummaryAndUnknownSegmentReferences`.

---

## File Map

- Create `speaktype/Models/Meeting.swift`: sessão, fonte de áudio, segmento, estados e tipos de resumo `Codable`.
- Create `speaktype/Services/Meetings/MeetingStore.swift`: diretório por reunião, manifesto JSON versionado, operações atômicas, segmentos e recuperação.
- Create `speaktype/Services/Meetings/MeetingAudioCapture.swift`: protocolo de captura, fonte de microfone AVFoundation e fonte do sistema ScreenCaptureKit.
- Create `speaktype/Services/Meetings/MeetingTranscriptionQueue.swift`: fila limitada e serializada para ASR local por segmento.
- Create `speaktype/Services/Meetings/MeetingCoordinator.swift`: máquina de estados da sessão, relógio comum, início/parada e erros das fontes.
- Create `speaktype/Services/TranscriptionWorkGate.swift`: acesso exclusivo às cargas/inferências compartilhadas do roteador, evitando corrida entre ditado e reunião.
- Create `speaktype/Services/Meetings/MeetingSummaryService.swift`: interface de provedores, geração por blocos, consentimento e validação de referências.
- Create `speaktype/Services/Meetings/LocalMeetingSummaryProvider.swift`: backend FoundationModels condicional.
- Create `speaktype/Services/Meetings/OpenAISummaryProvider.swift`: adaptador Responses API com `URLSession`.
- Modify `speaktype/Services/KeychainHelper.swift`: guardar/ler/remover chave de resumo em conta/serviço próprios, sem afetar licença.
- Create `speaktype/Views/Screens/Meetings/MeetingListView.swift`, `MeetingLiveView.swift` e `MeetingDetailView.swift`: lista local, captura visível, detalhe/transcrição, estados, resumo e exportação Markdown.
- Modify `speaktype/Views/SidebarView.swift` and `speaktype/Views/MainView.swift`: item e roteamento da área Reuniões.
- Modify `speaktype/Views/Screens/Settings/SettingsView.swift`: configuração opcional de provedor/modelo e chave remota.
- Modify `speaktype/Resources/Info.plist` only if required usage descriptions are needed by the selected capture APIs; keep permission prompts actionable and accurate.
- Add `speaktypeTests/MeetingStoreTests.swift`, `MeetingCoordinatorTests.swift`, `MeetingTranscriptionQueueTests.swift`, `TranscriptionWorkGateTests.swift` and `MeetingSummaryServiceTests.swift`.
- Add all user-visible strings to `speaktype/Resources/pt-BR.lproj/Localizable.strings`.

## Interfaces

- `MeetingStore.create(title: String, language: String, mode: MeetingCaptureMode) throws -> MeetingManifest`
- `MeetingStore.update(_ manifest: MeetingManifest) throws`, `appendSegment(_ segment: MeetingAudioSegment, for meetingID: UUID) throws`, `loadAll() throws -> [MeetingManifest]`, `recoverInterruptedMeetings() throws -> [MeetingManifest]`, and `deleteMeeting(_ id: UUID) throws`; deletion is invoked only after UI confirmation.
- `MeetingAudioCapture.start(mode: MeetingCaptureMode, onSegment: @escaping (CapturedMeetingSegment) -> Void, onSourceState: @escaping (MeetingAudioSource, MeetingSourceState) -> Void) async throws`; `stop() async throws` drains and closes segments before returning.
- `CapturedMeetingSegment` carries temporary file URL, source, relative start/end offsets, and whether the segment is complete; the coordinator moves completed files into `MeetingStore` before enqueueing them.
- `MeetingTranscriptionQueue.enqueue(_ segment: MeetingAudioSegment, meetingID: UUID) async`; queue concurrency is one ASR operation at a time, preserves segment order, and retains durable files on failure.
- `TranscriptionWorkGate.acquire() async` / `release()`: FIFO exclusive permit around shared model loading and inference; release occurs with `defer` on success, error, and cancellation.
- `MeetingCoordinator.start(title: String, mode: MeetingCaptureMode, language: String) async throws`, `stop() async throws`, and observable `manifest`/`liveTranscript`/`pendingSegmentCount`.
- `MeetingSummaryProvider.summarize(_ request: MeetingSummaryRequest) async throws -> MeetingSummary`; `MeetingSummaryService.generate(meetingID: UUID, provider: MeetingSummaryProvider, consent: MeetingCloudConsent?) async throws -> MeetingSummary` validates and persists the independent summary state/result through `MeetingStore`.

### Task 1: Persisted Meeting Domain and Recovery

**Files:**
- Create: `speaktype/Models/Meeting.swift`
- Create: `speaktype/Services/Meetings/MeetingStore.swift`
- Test: `speaktypeTests/MeetingStoreTests.swift`

**Interfaces:** Implements the `MeetingStore` interface above. Persist manifests under `Application Support/SpeakType/Meetings/<UUID>/manifest.json`; store audio as closed per-source segment files with relative start/end offsets and stable UUIDs.

- [ ] Write tests for create/load round trip, schema version, atomic manifest replacement, unreadable manifest isolation, explicit deletion, and the Review Focus abrupt-recovery case.
- [ ] Implement `MeetingManifest`, `MeetingAudioSegment`, `MeetingCaptureMode`, source/session/summary enums, and a versioned Codable manifest.
- [ ] Implement atomic manifest writes using a temporary sibling file and replace/move; write completed audio segments before persisting references to them.
- [ ] Implement recovery that marks previously recording/finalizing meetings interrupted, validates referenced segment files, and retains only closed readable segments.
- [ ] Verify the focused store tests pass and that deletion removes only the selected meeting directory.

### Task 2: Capture Sources and Durable Session Coordination

**Files:**
- Create: `speaktype/Services/Meetings/MeetingAudioCapture.swift`
- Create: `speaktype/Services/Meetings/MeetingCoordinator.swift`
- Test: `speaktypeTests/MeetingCoordinatorTests.swift`

**Interfaces:** Uses `MeetingStore` and `CapturedMeetingSegment`; coordinator exposes observable manifest, live transcript, and pending count. Capture mode `.inPerson` opens microphone only; `.online` opens microphone and system audio with separate source IDs and a shared monotonic session clock. Segment events are marked provisional for the live view until stop finalizes the session.

- [ ] Add injectable capture/store protocols and tests for state transitions, source startup failure, segment timestamps/order, source loss, disk failure and stop draining.
- [ ] Implement microphone capture with AVFoundation and close bounded-duration audio segments on disk without retaining the full meeting in RAM.
- [ ] Implement system-audio capture with ScreenCaptureKit, availability/permission errors, and exclusion of SpeakType process audio where supported; report source loss as a gap.
- [ ] Implement coordinator states `preparing`, `recording`, `finalizing`, `transcribing`, `completed`, `interrupted`, and `failed`; stop capture on required persistence failure and never auto-resume after recovery.
- [ ] Verify the Review Focus disk and source-failure cases pass with fake capture sources.

### Task 3: Ordered Local Transcription Queue

**Files:**
- Create: `speaktype/Services/Meetings/MeetingTranscriptionQueue.swift`
- Modify: `speaktype/Services/Transcription/TranscriptionManager.swift` only for an explicit serialized meeting transcription entry point if needed.
- Test: `speaktypeTests/MeetingTranscriptionQueueTests.swift`

**Interfaces:** Queue consumes closed `MeetingAudioSegment` references and writes transcript text, language, engine/model, timing and errors back to that segment through `MeetingStore`; it never deletes source audio after success. All `TranscriptionManager` model loads and inference paths use the shared FIFO `TranscriptionWorkGate`, including dictation and meeting jobs.

- [ ] Write tests for ordered processing, one-at-a-time ASR access, restart/resume of pending segments, model unavailable/change, empty result, retryable failure and delayed queue growth.
- [ ] Implement and test `TranscriptionWorkGate` FIFO acquisition/release on success, thrown errors and cancellation; route existing model-load/transcribe entry points through the gate without changing public dictation behavior.
- [ ] Add a meeting transcription entry point that pins the selected downloaded multilingual model for the session and refuses an in-session model switch.
- [ ] Implement a bounded queue that loads at most one segment for decode, persists each result independently and leaves failed/pending segment files intact.
- [ ] Feed finalized local transcript segments and processing status into `MeetingCoordinator` without invoking `HistoryService`, clipboard or dictation formatting.
- [ ] Verify queue tests prove order and durable recovery after a simulated process restart.

### Task 4: Meeting Navigation, Live View, Detail, and Export

**Files:**
- Create: `speaktype/Views/Screens/Meetings/MeetingListView.swift`
- Create: `speaktype/Views/Screens/Meetings/MeetingLiveView.swift`
- Create: `speaktype/Views/Screens/Meetings/MeetingDetailView.swift`
- Modify: `speaktype/Views/MainView.swift`, `speaktype/Views/SidebarView.swift`, `speaktype/Resources/pt-BR.lproj/Localizable.strings`

**Interfaces:** Add `SidebarItem.meetings` and route it to the meeting list. List opens a manual setup flow for title, Portuguese language, and in-person/online mode; live view binds to `MeetingCoordinator`; detail loads persisted transcript segments in stable timestamp order and exposes the summary action.

- [ ] Add navigation and localized labels/statuses for meeting list, mode selection, active sources, recording warning, pending transcription and recovery.
- [ ] Implement create/start/stop flow with visible recording status, duration, source health, provisional transcript label and participant notice.
- [ ] Implement list/detail for completed and interrupted meetings; show transcript timestamps, source, processing gaps and recovery action; never auto-paste.
- [ ] Implement Markdown export for transcript plus available summary with stable relative timestamps; omit absent summary fields rather than fabricate them.
- [ ] Verify state bindings update for new segment, source loss, stop and recovered meeting.

### Task 5: Local and Explicit Cloud Summaries

**Files:**
- Create: `speaktype/Services/Meetings/MeetingSummaryService.swift`
- Create: `speaktype/Services/Meetings/LocalMeetingSummaryProvider.swift`
- Create: `speaktype/Services/Meetings/OpenAISummaryProvider.swift`
- Modify: `speaktype/Services/KeychainHelper.swift`, `speaktype/Views/Screens/Settings/SettingsView.swift`
- Test: `speaktypeTests/MeetingSummaryServiceTests.swift`

**Interfaces:** Use provider-neutral request/result types with overview, topics, decisions, pending items/tasks, optional owner/deadline and segment UUID citations. Local provider returns an explicit unavailable result below macOS 26 or when system model/language capability is unavailable. Cloud consent is a typed, per-meeting confirmation and is required before provider invocation.

- [ ] Write tests for source-segment references, chunk consolidation, cancellation, local unavailability, the Review Focus consent gate, malformed/unknown cloud citations, text-only cloud payloads and no invented owners/deadlines.
- [ ] Implement schema validation and strict citation-ID allowlisting; keep transcript content as untrusted data and never accept model-generated instructions.
- [ ] Implement chunked summarize-then-consolidate with bounded context, cancellation and summary state independent of transcription state.
- [ ] Implement local FoundationModels behind `#if canImport(FoundationModels)` and macOS 26 availability/capability checks; do not use the punctuation formatter.
- [ ] Add a separate Keychain service/account for the optional OpenAI API key and provider/model settings; avoid logging request/response bodies or secrets.
- [ ] Implement Responses API calls with configurable model default `gpt-4.1-mini`, ephemeral URLSession configuration, structured response parsing and surfaced network/API errors.
- [ ] Add a confirmation sheet naming OpenAI and explaining that transcript text leaves the Mac; do not start a remote request until the user confirms each meeting.
- [ ] Verify that local unavailability never falls back to cloud and no cloud request occurs without explicit consent.

### Task 6: End-to-End Wiring, Privacy, and Release Readiness

**Files:**
- Modify: `speaktype/App/speaktypeApp.swift` only if app-lifetime recovery injection is needed.
- Modify: `speaktype/Resources/Info.plist` only for verified capture permission descriptions.
- Modify: `README.md` and `CHANGELOG.md`.
- Test: existing relevant `speaktypeTests` plus the new meeting tests.

- [ ] Wire meeting storage/recovery at app startup and surface interrupted sessions without starting capture automatically.
- [ ] Review all logs/errors/UI paths for transcript, audio path, API-key or request-body disclosure; keep diagnostic metadata only.
- [ ] Document capture consent, system-audio permissions, offline behavior, cloud transmission, data retention/deletion and known echo/source limitations in PT-BR.
- [ ] Run focused meeting tests, the complete existing test suite, `git diff --check`, and a Debug build; report any pre-existing failures separately.
- [ ] Manually validate in-person, online with headphones, denied permissions and interruption recovery; measure memory and queue latency during a 60-minute capture before claiming long-meeting readiness.
- [ ] Install the verified local Debug build reversibly for the user to try; do not change signing/TCC permissions or delete existing app data.
