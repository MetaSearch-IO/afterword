<!-- markdownlint-configure-file {"MD013": {"tables": false}} -->

# Afterword v1 implementation

Updated: 2026-10-01

Status: Capture, processing, recovery, and review are implemented. A real meeting
has a validated transcript and complete notes published in the reopened app.
Transcription-first publication and background worker scheduling are implemented,
tested, built, and installed in the reopened development app. Visual verification
and remaining performance/acceptance gates are open.

## 1. Scope and decisions

[HIGH_LEVEL_DESIGN.md](HIGH_LEVEL_DESIGN.md) defines the product scope. This
document defines the implementation contracts and milestone gates. It refines
three earlier choices: processing can be cancelled, artifacts are revisioned,
and crash recovery is proved with capture rather than deferred until the end.
No concurrent recording/inference, cloud fallback, database, or voice enrollment
is introduced.

Read-only Google Calendar matching is authorized for the October 8 continuation.
Automatic recording remains deferred and requires explicit opt-in. Recording
still starts with **New Recording** or Cmd-N.

Keep Swift responsible for capture, application state, and meeting metadata.
Keep Python responsible for post-stop inference and derived artifacts. Use
SwiftPM for the initial native app and a conventional development app bundle.
An Xcode project can be introduced if signing or debugging needs justify it;
it is not a prerequisite for this personal, locally built v1.

### Development baseline

Observed on this machine:

| Item | Value |
| --- | --- |
| Hardware | Apple M3 Max, 64 GB RAM |
| OS | macOS 26.3.1 (a), arm64 |
| Xcode / Swift | Xcode 26.6 / Swift 6.3.3 |
| App deployment target | macOS 15 |
| Worker interpreter | Python 3.12.11, pinned in `worker/.python-version` |
| Environment manager | uv 0.7.19 installed; dependencies recorded in `worker/uv.lock` |
| Meeting languages | Chinese and English, including mixed-language samples |
| Processing target | 15 minutes per hour of retained audio, including all stages; normal multitasking takes priority |

The current OS is the first validation target. A successful build does not prove
macOS 15 runtime compatibility. The Python inference stack is now locked and
installed; the complete model pipeline still has open M3 acceptance gates.

The user's current priority is keeping other applications responsive during
processing. Accept additional latency when yielding resources helps normal
multitasking; closing other applications is not a requirement. The 15-minute
per-hour throughput goal remains useful, but cannot override this priority.

Full processing now publishes a validated transcript before speaker labeling.
Remote speaker labels and notes follow in a separate final revision. This flow
is implemented and has passed artifact replay and app integration tests.
Visual verification remains pending.

### Commands and files

Prerequisites: full Xcode selected by `xcode-select`, Python 3.12.11, uv, and
`markdownlint`. Native model setup additionally requires Git, CMake, and curl.
From the repository root:

```sh
make setup
make check
make model-setup
make model-inspect
make run
```

- `make setup` creates `worker/.venv` from the lockfile, including the default
  `inference` dependency group. Ordinary setup/check commands retain this group.
- `make check` builds and verifies the app bundle, checks the worker entry point,
  runs Swift and Python suites, and lints both design documents. Individual suites
  are `make swift-test` and `make worker-test`.
- `make model-setup` explicitly builds the pinned native executables and downloads
  about 5.56 GB of public weights. Downloads resume through staged files and must
  pass size/SHA-256 checks before publication. Building the app never downloads
  model weights.
- `make model-inspect` checks runtime paths without downloads. For full local
  file integrity verification, run
  `python3 scripts/setup-models.py inspect --verify-hashes`. An absent gated model
  is reported as missing setup, not as successful processing readiness.
- `make run` opens `.build/Afterword.app`. Use this bundle for permission tests,
  not the bare SwiftPM executable. `Package.swift` can also be opened in Xcode.
- `APP_BUNDLE` selects a separate build/verification destination. The previously
  verified candidate was promoted to `.build/Afterword.app` after idle-state and
  worker-lock checks and a graceful quit. The transcription-first changes passed
  integration tests and are in the rebuilt, signed app. Changes can be checked
  separately:

  ```sh
  make check APP_BUNDLE=.build/Afterword-candidate.app
  ```

  Building that candidate does not update the running app. Do not launch a second
  copy or replace the running bundle while a recording may be active.
- `Sources/AfterwordApp/` contains capture, preparation, worker supervision, and
  review UI; `Sources/AfterwordCore/` contains meeting storage and timeline rules.
  `App/Info.plist` supplies the bundle identifier and microphone purpose string.
- `worker/afterword_worker/` contains processing, native adapters, artifact
  validation, summary generation, and the process protocol. The app supplies
  explicit paths and identifiers when launching it.
- `.build/`, `.cache/`, and virtual environments are ignored by Git. Build
  caches stay in the checkout. Meeting data and models belong under
  `~/Library/Application Support/Afterword/`, never in Git.

The app's language picker offers **Auto (中文 / English)**, **中文**, and **English**
before Record. For a saved Chinese meeting, select **中文** under **Language for
reprocessing**, then choose **Reprocess Audio…** and confirm. **Regenerate Notes**
reuses the existing transcript and cannot fix its recognition language. Selecting
a language alone does not rewrite existing artifacts; the old transcript remains
available until a new transcript succeeds. The reopened app includes these
controls and the meeting display-name editor.

Community-1 requires the user to accept its [model conditions][community] and
configure local Hugging Face access. After acceptance, authenticate interactively
in the local terminal and run its separate provisioning command:

```sh
worker/.venv/bin/hf auth login
worker/.venv/bin/python scripts/setup-models.py gated --terms-already-accepted
```

Do not paste credentials into chat or command arguments. Gated setup downloads
the pinned snapshot and verifies that the pipeline loads locally with Hub access
disabled before publishing its path. Community-1 is now provisioned, and a full
CPU diarization run on the retained real meeting completed successfully.
Runtime configuration is written atomically to
`~/Library/Application Support/Afterword/runtime.json`; it contains absolute
Python, worker, native executable, and model paths plus hashes/provenance.

The bundle uses ad hoc signing by default, without hardened runtime or App
Sandbox. A local `.build/afterword-signing-identity` file can select a
certificate identity for repeatable privacy grants; `AFTERWORD_SIGNING_IDENTITY`
overrides it. Neither local signing mode makes the app distribution-ready.
No initial commit or remote is required by this setup.

SwiftPM requires host execution because its nested sandbox cannot start inside
the agent sandbox. Metal inference and speech synthesis diagnostics also required
host execution. These development-tool restrictions are separate from the app's
microphone and Screen Recording permissions. Current acceptance evidence and
remaining gaps are recorded in section 8.

### Pinned local inference candidates

`config/runtime-manifest.json` records complete file sizes, SHA-256 hashes,
repositories, and revisions. `worker/uv.lock` fixes all Python dependencies.
The native source tags were fetched and peeled to their actual commits; a release
API target that differed from the annotated llama tag was rejected during setup.

| Component | Pin |
| --- | --- |
| whisper.cpp | `v1.9.4`, commit `927cfce34f31707e17f2bff35c349632fb9e2c3a`; `whisper-cli` and `whisper-vad-speech-segments` |
| llama.cpp | `v0.5.0`, commit `7fe450e19305b828c199d602c23a8337aaa1f03b`; `llama-completion` and `llama-tokenize` |
| ASR weights | `ggerganov/whisper.cpp`, revision `5359861c739e955e79d9a303bcbc70fb988958b1`, `ggml-large-v3-turbo-q8_0.bin` |
| Speech detection | `ggml-org/whisper-vad`, revision `9ffd54a1e1ee413ddf265af9913beaf518d1639b`, `ggml-silero-v6.2.0.bin` |
| Summary weights | `Qwen/Qwen2.5-7B-Instruct-GGUF`, revision `bb5d59e06d9551d752d08b292a50eb208b07ab1f`, both `qwen2.5-7b-instruct-q4_k_m` shards |
| Diarization weights | `pyannote/speaker-diarization-community-1`, revision `3533c8cf8e369892e6b79ff1bf80f7b0286a54ee`; installed and exercised on the real meeting |
| Python inference | `pyannote.audio==4.0.7`; locked Torch `2.14.0`, TorchAudio `2.11.0`, TorchCodec `0.16.0` |

Native executables use static project libraries and embedded Metal kernels;
installed binaries link only system libraries/frameworks. Build options and
executable hashes are recorded in `runtime.json`. The installed Python versions
passed actual imports, TorchAudio resampling, and pyannote waveform-tensor input
checks. The worker supplies tensors to pyannote and does not require FFmpeg for
its audio decoding path. These checks do not replace real diarization validation.

An optional guarded encoder-reuse patch is now packaged against the pinned
whisper.cpp base above: `scripts/patches/whisper-v1.9.4-encoder-reuse-v1.patch`,
SHA-256
`01ba7b18aa92feeeaa65cffb3f8017e1f8184500b47ab0c3713200c927e4301f`.
It can reuse Auto language detection's encoder result for the first native MTL
window when the required state/callback guards hold; other paths keep the
original execution behavior. Source, build, and installation variants are
isolated, with base commit, patch hash, expected source tree, and executable
hashes recorded in provenance. Repeat setup now correctly tolerates ignored
generated files such as `package.json` while still rejecting undeclared source
changes. The worker explicitly enables reuse only when runtime metadata opts in;
that metadata also changes the ASR cache fingerprint.

The pinned Chinese/English automatic-language patch,
`scripts/patches/whisper-v1.9.4-auto-en-zh-v1.patch`, is layered on that variant.
Its SHA-256 is
`449c97c0f15106e9e4e87f9e4f493e30d6334d2cb3a2f1d59e74d0f822b20841`.
When runtime metadata enables `auto_language_en_zh`, each Auto utterance selects
the higher existing Whisper probability for English or Chinese. An existing top
English/Chinese selection is unchanged; explicit modes bypass the restriction.
The worker explicitly disables the private environment switch in other cases.
Both patches, their order, and the resulting source tree and binaries are pinned.

At the October 1 experiment checkpoint, the manifest opts into the guarded patch
and the fresh full-pipeline candidate passed production Swift validation. The
permanent variant is installed and enabled in the live runtime; readiness checks
reported no missing assets or integrity failures. The prior runtime was backed
up, and the app was reopened with one running instance. Activation is recorded
in [`.build/encoder-reuse-activation-2026-10-01.json`](.build/encoder-reuse-activation-2026-10-01.json).
Accepted meeting artifacts and notes behavior were not replaced or changed.
Measurements are recorded in section 8.

## 2. Phase 0: documentation discovery

Discovery used official documentation and the installed SDK, not inferred APIs.
Before implementing each adapter, read the linked source and verify it against
the selected SDK or pinned executable's help output.

| Area | Allowed surface / source | Constraint |
| --- | --- | --- |
| Capture | `SCStreamConfiguration.capturesAudio`, `captureMicrophone`, `microphoneCaptureDeviceID`; `.audio` and `.microphone` outputs; [Apple capture sample][capture] | Microphone capture requires macOS 15+. Microphone buffers use the device-native format; system `sampleRate` does not configure both sources. |
| Permissions | `AVCaptureDevice.authorizationStatus(for: .audio)`, microphone authorization; [Apple authorization guide][permissions] | Include `NSMicrophoneUsageDescription`; separately exercise Screen Recording consent for ScreenCaptureKit. |
| Timing | `CMSampleBufferGetPresentationTimeStamp`, optional `SCStream.synchronizationClock`, CoreMedia clock conversion; [CoreMedia clocks][clocks] | Verify clock mapping on the target SDK; never use callback arrival time as audio time. |
| App bundle | SwiftPM executable target and [Apple bundle layout][bundle] | Bundle executable under `Contents/MacOS`, metadata under `Contents/Info.plist`. |
| ASR | `whisper-cli --model --file --language --output-json-full --output-file`; [CLI implementation][whisper-cli] | Output path is a stem; JSON is adapter input, not the app's persistence schema. Word timestamps are experimental. |
| Diarization | `Pipeline.from_pretrained(local_path)`; `output.speaker_diarization`, `output.exclusive_speaker_diarization`; [Community-1 card][community] | Keep both outputs. Runs select available MPS automatically, otherwise CPU; full MPS execution passed on the retained recording, while attribution quality and broader acceptance remain open. |
| Telemetry | `PYANNOTE_METRICS_ENABLED=0`; [pyannote README][pyannote] | Set before imports; audit other dependencies too. |
| Summary | `llama-completion`, local `--model`, `--offline`, `--json-schema-file`; [completion guide][completion] | Verify the chosen build. Current `llama-cli` [documentation][llama-cli] describes server behavior, so do not assume it meets the no-server contract. |
| Structured output | [llama.cpp grammar guide][grammars] | JSON Schema support is partial; schema constraints do not establish factual accuracy. |

The installed SDK's `ScreenCaptureKit.framework/Headers/SCStream.h` confirms
separate microphone output and its native format. `CoreMedia.framework/Headers/`
contains `CMSampleBuffer.h` and `CMSync.h` for timestamp and clock signatures.
These are under the SDK selected by `xcrun --show-sdk-path`.

The manifest and lockfile above provide reproducible pins. Current upstream
documentation is discovery evidence; adapters use the verified pinned source and
the installed executable's help output.

## 3. Application lifecycle contract

Represent capture state separately from processing state and artifact
availability. A summary failure must not hide a valid transcript. Keep one
global exclusive activity: capture/finalization or processing.

| Activity/state | Actions and transitions |
| --- | --- |
| Idle | Record after capture preflight; process a retained meeting after model preflight. |
| Starting | Await both source setup results; failure interrupts the session without claiming successful capture. |
| Recording | Pause establishes a boundary; Stop enters finalizing. |
| Paused | Resume establishes a new interval; Stop enters finalizing without resuming capture. |
| Finalizing | Finish writers once; then automatically process, or retain audio with an actionable setup/finalization error. |
| Processing | Show the early transcript while labels and notes continue; allow cancellation or pause; Record cancels and awaits worker cleanup before capture starts. |
| Cancelling | Stop the worker and all model descendants; do not release the activity slot until termination is confirmed. |
| Cancelled / failed | Retain committed artifacts; allow retry or a new recording. |
| Interrupted | Offer processing of committed audio; never restart capture automatically. |

Recording depends on capture prerequisites, not downloaded models. A missing
model after Stop leaves audio saved and shows the missing setup requirement.
When ASR succeeds but Community-1 is missing, full app processing retains the
early transcript. The user can finish setup and explicitly retry speaker labeling.

Cancellation is cooperative first, with a five-second grace period followed by
termination of owned processes. Target returning the activity slot within ten
seconds on the target Mac; if cleanup fails, show that failure and keep the slot
blocked. Record the measured result in M2/M3.

Use an explicit worker control channel whose closure signals parent death.
The worker supervises model subprocesses and their process groups. Swift tracks
the worker's live process identity and handles worker failure. On normal Quit,
finalize capture or cancel processing before exiting. On app death, the worker
must stop its descendants when the control channel closes. Never kill a process
from a persisted PID alone: PIDs can be reused.

The app launches the worker with `Process.qualityOfService = .background`.
Focused subprocess tests verified inherited background QoS and effective/maximum
scheduler priority 4 through descendants, including a descendant requesting
higher QoS. This is a scheduling policy, not a CPU percentage, thread-count,
RAM, or GPU-memory cap. Responsiveness under normal multitasking still requires
measurement. Register the process termination handler before launch so a fast
exit cannot be missed while awaiting worker completion.

## 4. Capture and timeline contract

### Source and sample ownership

- Register separate `.audio` and `.microphone` outputs. Exclude Afterword's own
  output and never play captured audio during recording.
- Inspect each buffer's actual format. A device format change or loss ends the
  session as interrupted for v1; automatic switching is deferred.
- Serialize lifecycle decisions and writer ownership. Bound pending write data
  to at most two seconds per source; overflow interrupts visibly rather than
  silently dropping samples or growing memory indefinitely.
- Use a shared monotonic timeline. Persist integer microseconds for meeting
  offsets and integer sample positions/counts for prepared audio mappings.
- Request 16 kHz mono system audio. Save both sources as 16-bit PCM in CAF,
  retaining the actual sample rate and channel count in each chunk descriptor.

### Pause, gaps, and conversion

Capture intervals are half-open `[start, end)`. Pause closes the current interval
at a timestamp boundary; Resume opens a new interval. Accept samples by their
media timestamps and interval membership, not the current UI Boolean. Trim
buffers crossing boundaries. Reject delayed samples belonging to a paused or
previous capture generation. Show Paused only after the writer barrier completes.

Every source has an explicit piecewise mapping from prepared sample ranges to
meeting intervals. Different source start times and known delivery gaps must
remain representable. Never treat missing source data as proof of silence.
Forward microphone timestamp gaps split saved chunks and leave a visible warning;
speech in those gaps is unavailable. Backward timestamp overlap, format changes,
and stream failure still interrupt capture.

After a stream failure or Stop, start/pause/resume must not claim an active
recording or open another capture interval. Native errors retain their domain
and code, with source-specific recovery guidance and confirmation that committed
audio is preserved. ScreenCaptureKit source loss still interrupts capture;
automatic restart or a silent microphone-only fallback is not implemented.

Prepare mono 16 kHz input with AVFoundation. Preserve one continuous prepared
source for whole-source diarization while retaining its discontinuity map.
ASR windows must not join across pauses or missing-data gaps. Ordinary storage
chunk boundaries may be joined when sample continuity is verified.

Map model intervals by intersecting every mapping piece. Split model results
at discontinuities before publication; mapping start/end points alone is wrong.
If text cannot be split reliably, retranscribe the retained intervals separately
or flag the result as ambiguous rather than inventing word timing.

VAD introduces another possible time transformation. M3 must prove the pinned
ASR adapter preserves input-relative timestamps or explicitly compose its map.
There must be no transcript interval inside a paused interval.

### Chunk commit and recovery

Proposed capture encoding: uncompressed PCM in CAF, finalized at least every
five seconds of retained audio and at Pause/Stop. The target loss bound for an
app crash is five seconds plus the bounded two-second write queue per source.
This is an acceptance target to measure, not a claim of power-loss durability.

Use an atomic directory commit on the same filesystem:

1. Create `audio/<chunk-id>.partial/` containing audio and a descriptor.
2. Finish the writer. Validate readability, format, frame count, source,
   interval, start offset, and duration; write the final descriptor atomically.
3. Rename the directory to `audio/<chunk-id>/`; this is its commit marker.
4. Add the chunk to Swift-owned `meeting.json` using atomic replacement.

On launch, reconcile committed directories with the manifest. Adopt valid
committed chunks omitted by a crash between steps 3 and 4. Do not automatically
trust partial directories; preserve them for bounded recovery inspection.
Finalized audio is immutable. Test disk-full failures and corrupt descriptors
as well as abrupt app termination. A committed chunk must not require the last
metadata update to be discoverable.

## 5. Persistence and revision contract

Use schema version 1 for application JSON. Unknown versions produce a readable
error and leave files untouched. Validate paths as meeting-relative paths before
reading artifacts. The planned layout refines the HLD's illustrative layout:

```text
meetings/<meeting-id>/
  meeting.json
  audio/<chunk-id>/
    audio.caf
    chunk.json
  revisions/<revision-id>/
    provenance.json
    transcript.json
    summaries/<summary-id>.json
  work/<run-id>/
```

Swift alone owns `meeting.json`: recording state, committed chunk manifest,
processing status, active revision/summary pointers, and revision-scoped speaker
display-name maps. Python publishes derived immutable artifacts and emits events;
it never changes meeting metadata. Working files are disposable; original audio
and published artifacts are not.

Meeting display names are editable in the detail header. Names are trimmed and
must contain 1–200 characters; renaming updates the list and persists across
reloads without changing meeting IDs, audio paths, transcripts, or speaker names.
During recording or pause, name changes use the capture writer queue so chunk
commits and finalization preserve them. Brief capture transitions disable name
editing for that meeting. Processing status updates retain the latest saved name.

| Identifier/data | Rule |
| --- | --- |
| `meeting_id` | Created once; retries keep the meeting. |
| `run_id` | New for every attempt; included in every worker event and staged artifact. |
| `revision_id` | Identifies one accepted transcript plus its speaker assignments. |
| `segment_id`, `speaker_id` | Stable within a revision, never assumed stable across full regeneration. |
| Transcript segment | Source, meeting start/end, text, nullable speaker ID, attribution reason, overlap flag. |
| Summary | Own ID, transcript revision, input name-map revision, structured notes and supporting segment IDs. |
| Provenance | Committed audio fingerprint, preparation/alignment versions, effective options, runtime/build/model hashes, language policy. |

The processing controller validates an artifact before switching active pointers.
Atomic replacement of separate JSON files is not a transaction: publish data
first, then update pointers. A crash may leave an unreferenced complete artifact;
it must never leave a pointer to a partial one. Recover by validating provenance
and contents before adopting an orphaned result.

With transcription-first processing, `revisions/<run-id>/` holds an immutable
early ASR transcript and provenance. It uses the existing version-1 artifact
schemas, with `diarization_mode: deferred` and `diarization_status: pending`.
The requested final revision ID must differ from the run ID. Reject an existing
early-revision destination before ASR; never overwrite it with speaker labels.
The final transcript and notes use the separate final revision directory.
No `Meeting` fields or artifact schema versions were added for this flow.

Accepting a valid new ASR revision clears the active old-summary pointer to avoid
showing citations from another transcript revision. Old transcript, summary, and
audio files remain retained. Failure, cancellation, or restart keeps a validated
early transcript available; recovery validates its provenance before adoption.
The review UI offers **Finish Speaker Labels** for a pending transcript. Its
full-processing retry reuses ASR only when the existing checkpoint compatibility
checks pass; it does not assume that a different language or model is compatible.

Summary-only retry reuses the accepted transcript revision and speaker IDs.
Full ASR/diarization regeneration creates a new revision. Keep the old revision
reviewable until the new one succeeds; do not carry speaker renames across by
cluster number. Reset the new revision to anonymous remote labels and disclose
that behavior in the reprocess action.

A stage checkpoint is reusable only when its schema, inputs, effective options,
and relevant runtime/model fingerprints match. Summary changes need not rerun
ASR. ASR or alignment changes invalidate transcript-dependent summaries. Stale
events from a previous run cannot change the active run's state.

## 6. Worker and inference contract

### Process protocol

The processing command takes absolute meeting, interpreter, executable,
and model paths plus run/revision identifiers. Launch with argument arrays;
no shell expansion, shell PATH lookup, network server, or automatic downloads.
The app uses the environment's explicit Python path and module working directory.
Full app runs pass `--transcript-first`; summary-only runs retain their existing
command path. Legacy callers without the flag and local-only meetings retain
their previous publication behavior.

Worker stdout contains only versioned newline-delimited JSON events:

```json
{"protocol_version":1,"run_id":"example","type":"stage_started","stage":"asr"}
```

Event kinds: `started`, `stage_started`, `stage_completed`, `completed`,
`cancelled`, and `failed`. Stage completion includes artifact-relative paths
and input fingerprints; failure includes a stage, code, and safe explanation.
Bound event lines to 64 KiB and retain at most 256 KiB of diagnostic stderr.
Drain both pipes concurrently. Do not log transcript text, prompts, or raw model
output; route native executable stdout into working artifacts, not worker stdout.

Reject unknown protocol versions, malformed events, and mismatched run IDs.
Exit zero is necessary but insufficient: require a valid terminal event and
validated published artifacts. Serialize launches and use a per-meeting OS lock
to prevent an orphaned worker and a retry from publishing concurrently.
Cancellation checks precede publication; valid results committed before Cancel
remain reusable. A late event cannot override a cancelled job.

After validated ASR and its checkpoint are saved, a flagged run containing remote
speech atomically publishes the early transcript and provenance before any
Community-1 integrity check, loading, or inference. Publication uses the same
staged-directory rename helper as the final revision. Emit `stage_completed`
with `stage: transcript`, `revision_id` equal to the run ID, and these exact
meeting-relative paths in both the named fields and `artifacts`:

- `transcript_path`: `revisions/<run-id>/transcript.json`
- `provenance_path`: `revisions/<run-id>/provenance.json`

The event's `input_fingerprint` matches the published provenance. Existing
`stage_completed/alignment` and terminal events identify the separate final
revision. The app validates each event's expected ID, paths, and artifacts before
accepting it. This adds no ASR or diarization model pass.

### ASR and speaker assignment

Run preparation, ASR, early transcript publication when requested, diarization,
final alignment, and summary sequentially. Release models between stages, using
separate subprocess lifetimes where needed. Pending remote segments have a null
speaker ID and `speaker_labeling_pending` attribution reason, with a visible
warning that speaker labeling and overlap assessment are unfinished. Existing
timing warnings and local attribution remain intact. Final speaker labeling
preserves the early transcript's segment IDs, sources, times, and text.

Use the documented `whisper-cli` full JSON output through a small adapter.
Preserve spoken language. Whole-input automatic language detection failed a
mixed English/Chinese fixture, translating Chinese into English; forcing Chinese
dropped the English content. Instead, use the pinned VAD-only executable to find
speech regions, then detect language independently for each region. Current VAD
settings are 100 ms minimum speech, 400 ms minimum silence, and 100 ms padding.
Its printed timestamps are **centiseconds**, converted to source sample indices.

Automatic detection remains fallible on short, ambiguous speech. A real Chinese
recording exposed this after the synthetic checks: Auto produced English on the
same roughly one-second utterance in two runs, and also on the full 15.3-second
microphone track. Explicit Chinese mode returned Chinese text on the short clip;
the production ASR adapter then replayed the full track with `--language zh`
under network-denied GPU execution and returned three Chinese segments. Exact
recognition remains unconfirmed by the user. This verifies the explicit-language
path, not a universal fix for automatic language detection.

Support an explicit per-meeting language choice: `auto`, `zh`, or `en`. The worker
`process` command accepts `--language auto|zh|en`; the app passes the selected mode
for full transcription. Optional `Meeting.asr_language` defaults to Auto when
absent, preserving older meetings. Auto continues to detect each VAD region for
mixed-language input; the configured runtime restricts candidates to Chinese and
English without forcing one language for the whole meeting. ASR cache policy
version 6 includes the selected mode, padded-timestamp normalization, the
64-utterance batching policy, and retained VAD speech support. It invalidates
earlier ASR checkpoints, and
transcript provenance records
`asr_language`, so changing modes cannot reuse an incompatible ASR checkpoint.

The real long meeting exposed Whisper intervals extending into model padding.
The adapter now retains text while clipping supported intervals to retained
audio, marks ambiguous timing explicitly, and avoids certain speaker attribution
for those segments. Unsupported time units, ordering, or intervals still fail.

Batch up to 64 utterances as repeated `--file`/`--output-file` pairs in one Whisper
invocation to reuse the model load; the pinned runtime resets context and, in Auto
mode, detects language per file. Batches stay inside one VAD window and continuous
audio piece. Disable internal VAD on these already selected
regions. Map each returned offset through its utterance and source timeline.
The pinned internal-VAD JSON token offsets are not remapped to source time, so
they must not be used as source-aligned word evidence.

Handle overlapping ASR windows by time/text deduplication inside a continuous
interval. Never deduplicate across microphone and system-output sources merely
because their words match.

Run Community-1 across the full prepared remote source for consistent clusters.
Retain ordinary diarization to identify overlap and exclusive diarization for
candidate attribution. The initial attribution policy is conservative:

- Microphone speech maps to the revision's `local` speaker, displayed as You.
- Assign a remote ASR segment only when its speech interval supports one speaker
  and no overlap is detected. Alignment version 2 may exclude only padding known
  to have been added by VAD: at most 90 ms per edge, preserving a 10 ms printed
  timestamp rounding margin. Do not trim at a clipped window edge or where VAD
  padding from neighboring regions touches. Keep the original playback interval.
- Any different speaker anywhere in the original interval, including padding,
  prevents this relaxation. Internal gaps, ASR padding overruns, unresolved window
  boundaries, and old checkpoints lacking VAD support remain conservative.
  Merging ASR windows discards the padding exemption. Word-level splitting stays
  deferred until timestamp quality is validated.
- If timing spans a speaker change and cannot support a split, or regular
  diarization marks overlap, use unknown attribution with a reason.
- Missing diarization support is not evidence that a speaker is known. Do not
  invent a calibrated confidence score from timing overlap.

The recovered meeting used Community-1 on CPU. Subsequent jobs use MPS when
available and CPU otherwise, with the effective device recorded in provenance
and revision fingerprints. A separate, network-denied full-source MPS benchmark
now completed through the production adapter; section 8 records its scope and
CPU comparison. The accepted transcript remains unchanged, and this benchmark
does not establish human speaker-attribution accuracy.

Speech detection gates silent input. An empty source does not make the whole
meeting empty; both sources must have no usable speech before suppressing the
summary. Test brief speech surrounded by silence to avoid dropping short turns.

### Summary and review

Use a pinned, verified one-shot llama.cpp executable with local weights. Supply
the selected instruction model's proper prompt template and a supported output
grammar/schema. Independently validate JSON, revision, speaker references, and
all supporting segment IDs. Invalid output leaves the transcript available and
the summary failed; it does not silently publish partial notes.

Use Qwen ChatML with an exact-byte prompt file: `llama-tokenize --file --ids
--no-escape` counts the same bytes passed to `llama-completion --binary-file
--no-escape`. The pinned completion tool appends a literal `[end of text]` trailer;
the adapter accepts only one JSON value followed by whitespace or this exact
trailer, rejecting arbitrary prefixes or additional output.

Summary fields: overview, discussion points, decisions, action items, and open
questions. Every factual item has supporting segment IDs. Action owners and due
dates are nullable and require explicit evidence. Preserve relative due-date
wording initially rather than inventing calendar dates.

For v1, each action must quote one source segment verbatim and cite only that
segment; this preserves distinct named assignments instead of merging them
across languages. A non-null speaker owner additionally requires a recognized
first-person commitment in that quote. Third-person names remain in the quoted
text, with a null speaker owner. After a validation failure, allow at most one
constrained repair attempt with speaker owners forced to null. A second invalid
result fails the summary while retaining the valid transcript.

Summary policy 7 uses source-constrained action selections: the model selects a
segment ID, and the adapter copies its exact quote and evidence references.
Narrative notes cite only 1–4 supporting segments; complete input coverage is
tracked separately instead of expanding every note into a full citation list.

Summary provenance includes every GGUF shard hash, prompt/schema digests, policy
version, context/output limits, template, and repair bound. These controls prevent
specific unsupported claims; they do not establish completeness or factual
accuracy for every generated narrative note.

Budget the full prompt, schema instructions, transcript, and output reserve
against context capacity. For long meetings, extract notes from bounded sections
and recursively reduce bounded groups until the final result fits. Track coverage
of every input segment, retain original references at every level, and reconcile
later corrections or reversals of earlier decisions. A single unbounded reduce
prompt is not an acceptable long-meeting strategy.

Partitioning now budgets the exact repair prompt as well as the initial prompt.
Generation can use the remaining context after prompt tokens and a safety margin,
instead of truncating at the minimum output reserve. Validated extraction groups
can be reused only after checking transcript, names, model fingerprints, prompts,
and complete segment coverage. Recovery reused six such groups and reran only
the final reduction; no ASR or diarization rerun was needed for that last attempt.

The serial extraction helper keeps the existing 8192-token context,
prompts, source grammars, output budgets, and chronological group order. Explicit
`native.summary_batch.enabled: true` selects `llama_summary_batch`; older runtimes
retain one-shot extraction. Each finite cohort contains at most 16 jobs and
shares one loaded model, executing one job at a time. Reduction and each failed
job's single constrained repair still use the existing completion CLI.

Before accepting a cohort, validate its execution settings, exact job identities,
prompt token IDs against the tokenizer, output sizes, generated-token counts,
and terminal reasons. References must remain inside each job's source scope.
Genuine helper/protocol failures stop processing; a prediction-limit result or
invalid model JSON receives at most one repair. Valid siblings remain saved if a
repair fails, but those individual files do not support automatic cross-attempt
resumption. Complete validated extraction checkpoints retain their existing reuse
contract. Helper fingerprints and execution metadata distinguish the new path.

The partition search starts from the previous group's maximum size,
exponentially brackets upward or downward, then binary-searches the exact largest
fitting prefix. Every fit uses the actual tokenizer and both initial and repair
prompts; input splitting and coverage are unchanged. Synthetic oracle tests and
the fresh full-worker gate preserve the six real extraction boundaries:
140, 137, 136, 135, 133, and 83 segments.

Render structured speaker IDs through the current name map. Rename immediately
updates those references; mark generated prose stale when its input name-map
revision changes. Offer summary-only regeneration rather than string replacement.
The speaker editor displays the saved name and labeled-segment count, supports
Save and Return, and confirms successful writes. Reject a rename from an editor
whose transcript revision has since changed. Renaming never assigns a speaker
to an unassigned segment.

Default notes use one mouse-selectable text block: an overview paragraph and
compact discussion, decision, action, and question lists. Evidence timestamp
buttons are hidden until **Show evidence timestamps** is enabled. Transcript
rows place time, speaker, and text alongside each other with compact spacing.
**Details** reveals warnings and readable attribution explanations; internal
reason codes are not displayed in the default view. These are presentation
changes; saved note content, evidence IDs, and attribution policy are unchanged.

Review must support following a note to its transcript evidence and locating the
corresponding retained audio, including its chunk-relative offset.

The approved icon is packaged as `App/Assets/Afterword.icns` and copied into the
bundle's Resources directory. `scripts/build-icon.sh` regenerates its ten
standard macOS representations from the preserved PNG source.

## 7. Milestones and verification gates

### October 8 calendar and recording controls

The user authorized read-only calendar connection, event matching, automatic
meeting titles, and participant display. Their existing Google connection is in
Codex/ChatGPT; this standalone app will use its own Google authorization.
Calendar access is optional and cannot disable or delay recording. Audio and
inference remain local. Calendar descriptions and invitees are not transcript
evidence and must not be injected into grounded note generation.

#### Phase 0: verified interfaces and decisions

- Use Google's [installed-app OAuth flow][google-native-auth]: external system
  browser, a loopback listener bound to `127.0.0.1` on an ephemeral port, PKCE
  S256, and a unique checked state. Import only a Desktop OAuth client JSON.
  Google authorization/token endpoints are pinned, not supplied by the import.
- Request only `calendar.events.readonly` and `calendar.calendarlist.readonly`.
  These are the [documented read-only scopes][google-calendar-scopes]; no Gmail
  or Contacts permission is needed for event invitees.
- Read [CalendarList][google-calendar-list] and [Events][google-events-list]
  through bounded, complete pagination. Expand recurrence at the provider with
  `singleEvents`, request UTC times, and retain occurrence identity. No local
  RRULE expansion or guessed offsetless times.
- The development app is ad-hoc signed. Use login-Keychain generic-password
  storage with the app's normal access controls, respecting the distinction in
  [Apple's Keychain guidance][mac-keychains]. Restore must not trigger a startup
  authentication prompt. Tokens never enter meeting files, logs, or exports.
- EventKit was evaluated. It requires full Calendar permission to read on the
  target OS and depends on accounts configured in macOS. Direct Google OAuth
  preserves the approved read-only permission boundary.

#### Phase 1: auth and calendar data

Implement the auth actor, loopback receiver, Keychain credential envelope,
Google reader, provider-tagged event/invitee models, and event matching in
separate internal app files. Keep existing Meeting and transcript schemas and
public core APIs unchanged. A `calendar-event.json` sidecar holds the linked
event snapshot and meeting ID; it never stores credentials.

Only complete event windows may be matched automatically. Require a unique
ongoing timed event, fresh within five minutes and inside the queried window.
Exclude cancelled, all-day, declined-on-calendar, and non-meeting event types.
Zero or multiple candidates cannot silently choose a meeting. Calendar invitees
may be hidden, omitted, or unnamed and are not proof of actual attendance.

Verification: PKCE/state and callback validation, timeout/cancellation, stale
completion rejection, refresh coalescing, token errors, scoped requests, response
limits, pagination, recurrence/DST, ambiguous/stale matching, and sidecar path,
identity, and original-file preservation. Use synthetic HTTP responses and
isolated temporary stores; live credentials are not test fixtures.

#### Phase 2: user flow and capture integration

Use an app-wide **New Recording** toolbar button. Cmd-N opens the same dedicated
setup sheet; **Start Recording** invokes the capture controller. The selected
meeting's idle view contains review content, while active recording controls sit
above the meeting browser. Offer automatic current
event matching, an explicit event selection, and **No calendar event**. Snapshot
the chosen event before asynchronous capture preflight. Supply its normalized
title when creating the new meeting; a metadata-write failure must not stop
capture. Calendar requests never sit in the recording startup path.

Provide connection/setup, calendar selection, event refresh, and a local
disconnect action. Google Cloud client setup is a one-time prerequisite for this
development build; importing its JSON happens locally. Disconnect clears local
tokens and unlinked calendar state. Do not silently revoke an entire Google
project grant or change another app's connected account.

Saved meetings can explicitly link a matching calendar event. Preserve manual
meeting titles unless the user chooses to adopt the calendar title. Show the
saved event's invited participants and offer their names in the speaker editor;
choosing a name fills a draft and existing Save applies it. Do not assign voices
or action owners from the invitation list.

Verification: recording availability without calendar setup/offline, selection
frozen during permission/preemption waits, calendar failure isolation, title
preservation, historical snapshot identity, stale fetch rejection after account
or calendar changes, setup cancellation, and participant suggestions without
speaker reassignment. Test visible layout and interaction in the real app.

#### Phase 3: integration and release checks

Serialize Swift builds/tests and run the relevant full suites at a stable source
checkpoint. Review auth, data, and UI seams independently. Build/sign a separate
candidate and install only when capture/processing are idle, preserving accepted
meeting data and a backup. Distinguish synthetic verification from Google sign-in
and attendee availability, which require the user's own client and consent.

#### Implemented behavior and live acceptance

The app now has the recording controls, Google setup sheet, read-only reader,
fresh current-event matching, explicit event selection, historical linking, and
invitee name suggestions described above. The current-event title stays visible
when calendar controls are collapsed. Linked details include the organizer,
location, plain-text description, safe meeting links, and available invitees.
Linking or unlinking updates an open speaker editor without replacing its draft.

Review corrections remove the OAuth listener's lifetime connection budget while
retaining concurrent connection and request limits, reject dot-only calendar
identifiers, and clear unavailable calendar state after credential failures.
Background credential reads and writes disable interaction through the legacy
login-Keychain API, with calls serialized and the previous process setting
restored. These supported legacy calls produce SDK deprecation warnings; a
provisioned signing identity is needed before moving to the data-protection
Keychain. A failed revoked-token cleanup also blocks in-memory token reuse.

The final Swift suite passed 143 tests (129 XCTest and 14 Swift Testing), with
unchanged source hashes during the run. It includes fake credential/HTTP tests,
bounded real loopback tests, complete calendar pagination, matching, sidecar
protection, and capture/controller regressions. No live Google account or audio
capture was used for those tests.

The actual-view native fixture passed 30 interaction checks, including recording
startup with denied synthetic microphone permission, setup/sign-in routing,
historical linking, title preservation, and draft-before-Save speaker naming.
Rendered setup and settled event details were inspected for text wrapping.
The signed candidate was installed and reopened after idle checks, with a backup
retained. All 13 protected files across three saved meetings and the runtime
configuration remained unchanged. Five read-only checks in the running app
confirmed the new recording and calendar controls; no real recording was started.
Verification receipts are in `.build/calendar-checks-2026-10-08.json`.

The user's Google connection in Codex/ChatGPT does not configure this app.
Live acceptance still requires importing a Google Desktop OAuth client JSON
through **Connect Google Calendar**, completing the browser consent flow, and
checking the account's actual event and guest availability. Real Keychain prompt
behavior and live Google token refresh remain unverified. Calendar connection
does not start audio capture; **New Recording** or Cmd-N opens setup and
**Start Recording** starts a new meeting.

The October 8 permission follow-up reproduced incompatible designated
requirements between ad-hoc builds. TCC logs also show a code-requirement mismatch
for Afterword's microphone authorization. A developer account is not required to
record, but ad-hoc code changes can require renewed permissions. Builds may use
`AFTERWORD_SIGNING_IDENTITY` for optional certificate signing; they retain secure
default requirements rather than weakening identity checks to match a bundle ID.
The build script warns about ad-hoc permission churn and refuses to overwrite a
certificate-signed bundle with ad-hoc signing.

ScreenCaptureKit permission denial now shows recovery instructions instead of
raw TCC terminology. **Quit & Open Privacy Settings** waits for successful
recording and processing cleanup before opening the relevant settings pane.
Cancelling quit discards that pending action. The permission failure stays with
the new-recording setup, without being attached to the selected old meeting.

The follow-up passed 145 Swift tests, 23 synthetic UI checks, and eight checks in
the installed app without starting capture. The live toolbar/setup/cancel path
produced no AttributeGraph cycle diagnostics; synthetic state changes did log
such diagnostics without failed interactions. After idle/backup checks, the
update was installed and only `ScreenCapture` authorization for
`local.afterword.app` was reset. All 13 protected meeting/runtime files remained
unchanged. Recording after the user's renewed macOS approval remains a manual
acceptance check; ad-hoc updates can require authorization again.

The observed exit was reported by launchd as `(0, 0, 0)`; no Afterword report was
found in the user's diagnostic-report directory. That supports a normal exit
during the permission changes rather than establishing an application crash.
Evidence is in `.build/recording-recovery-checks-2026-10-08.json`.

On October 12, TCC logs showed that the enabled ScreenCapture grant matched an
older ad hoc code hash, while the running app had a different hash. A local
self-signed certificate was imported into the login Keychain without changing
system trust settings. Two differently hashed builds signed with it had the
same designated requirement. The installed app now uses that identity, and its
stale ScreenCapture and Microphone grants were reset for fresh authorization.

### October 8 meeting deletion

Right-clicking a meeting offers **Delete Meeting…** with a confirmation naming
that meeting. Confirming permanently removes its entire app-owned directory:
audio, all transcript/notes revisions, corrections, calendar context, and working
files. Exported copies and shared model/configuration files remain untouched.

Deletion runs off the UI thread, rechecks the current manifest, and requires both
processing and calendar locks. Active capture and queued/running processing block
deletion. The manifest remains until content removal succeeds so failures remain
retryable. Deleting the selected meeting selects a remaining meeting or the empty
view; deleting another meeting preserves selection. Quit waits for file removal.

The meeting detail also offers **Delete Saved Audio…** after recording finishes,
including before transcription. It keeps the meeting, transcript, notes, and
historical chunk timeline while deleting CAF files and working WAV copies. It
marks removal before deleting bytes, retries incomplete removal on startup, and
blocks playback and full transcription afterward. Existing transcripts can still
be exported or used to regenerate notes.

Verification passed 151 Swift tests and 17 native UI checks using disposable
meetings, including Cancel, external locks, symlink boundaries, partial filesystem
failure, and correct selection. The build was installed with all four user
meetings preserved and no privacy-permission reset. Evidence is in
`.build/meeting-delete-checks-2026-10-08.json`.

### October 3 meeting status presentation

The meeting list shows active recording or current processing progress. Accepted
transcript/notes pairs show **Transcript and notes ready**, including meetings
whose recording was interrupted. A separate **Recording interrupted** line
preserves that recording history and opens its explanation. Failed, cancelled,
paused, or queued processing stays visible even
when earlier accepted results exist; a secondary line shows which results remain
available. A transcript without notes is **Transcript ready**, without inferring
that no speech was found. Dates use the user's local time and locale. The detail
view keeps Recording and Processing as separate, explained states. No persisted
states, artifacts, processing behavior, or model configuration change.

The October 6 follow-up separates available results from recording coverage.
The popup explicitly resets inherited sidebar line limits, uses body text, and
expands vertically so that its explanation and error reason wrap fully.
Hover waits 500 ms before opening; leaving before then cancels it. Moving into
the popup keeps it visible, and leaving both areas dismisses it after a short
grace period. Clicking opens immediately and keeps it open until dismissal;
clicking the warning again or pressing Escape closes it. These timings are
local to this UI and do not change system tooltip preferences.

The clipping regression uses a sidebar with a one-line parent text limit;
validation checks rendered popup height as well as text, since accessibility
can expose complete strings even when the displayed text is truncated.
Eight status tests, 11 synthetic pointer checks, and 17 live UI checks passed.
The live popup measured 261 points high, the error text wrapped onto two lines,
and hover opened in about 0.57 seconds including presentation overhead. Saved
meeting data and runtime configuration were unchanged.
[Verification](.build/meeting-status-clarity-checks-2026-10-06.json).

### October 2 reliability follow-up

The latest 19-minute recording completed transcription, labeling, and notes, but
only 2 of 200 remote segments were labeled. Replaying retained VAD/Whisper outputs
with alignment version 2 adds 33 assignments; the earlier 764-segment meeting
adds 59. Every segment's text, timestamp, and ID remains identical, and no existing
assignment changes. Real speaker accuracy remains unverified; missing speech
support and speaker changes are still Unknown. Accepted meeting revisions are
not modified by these replay checks.

One native notes extraction exhausted its output budget and the existing compact
repair succeeded. Generation budgets and prompts remain unchanged. Summary retry
now searches up to 32 prior work directories for complete extraction checkpoints
or validated native group receipts. Broken links and unrelated work entries are
ignored. Reuse requires the exact transcript, names,
model hashes, generation policy, and execution identity plus complete segment
coverage. Partial or incompatible results restart extraction. This also covers
interruption after group receipts were saved but before the aggregate checkpoint.

The language patch passed a network-denied, background-priority comparison on
41 retained clips: all 21 clips previously detected as other languages and 10
controls per supported language. Disabled output exactly matched the previous
binary for all 41 clips; enabled output preserved both language and every raw
transcription field for all 20 controls. All outputs used Chinese or English
after enabling the patch. This verifies policy and compatibility, not human
recognition accuracy. Short Chinese/English ambiguities remain possible.

The verified app and native runtime were installed and Afterword reopened.
The previous bundle and runtime have backups. All three meetings' metadata,
accepted transcripts, provenance, and notes remain unchanged. These fixes apply
to subsequent processing; existing accepted results are not silently regenerated.
Evidence: [verification record](.build/reliability-checks-2026-10-02.json) and
[installation record](.build/reliability-activation-2026-10-02.json).

### October 1 continuation: recording priority and review tools

The user authorized continuous implementation of recording-priority processing,
manual speaker correction/undo, truthful progress/resource visibility, and
transcript search with Markdown/plain-text export. No milestone approval or
commit/push is required or authorized by this continuation.

Discovery references: `ProcessingController.start/cancel/prepareToQuit`,
`MeetingController.record/finish`, `WorkerProcess.cleanupConfirmed`,
`ArtifactRecovery.recover`, `Artifacts.loadRevision`, `Control.run`,
`inference.transcribe`, and `SummaryEngine.extract_groups` are the existing seams.
The SDK provides `NSSavePanel.beginSheetModal`, `allowedContentTypes`, `UTType`,
SwiftUI focus/keyboard shortcuts, and the existing transcript `ScrollViewReader`.

1. Processing coordination: keep one worker, reserve recording before awaiting
   cancellation, require confirmed child cleanup, and resume queued work only
   after capture ends or capture startup fails. New recordings go ahead of
   deferred follow-up work. Preserve user Cancel separately from automatic
   deferral. Persist intent using existing meeting status/pending identifiers;
   validate revision/audio/language snapshots before dequeuing. On restart,
   recover artifacts and locks before reconstructing queued intent. Never use
   process suspension that retains model memory, and never overlap capture with
   inference. Verify cancellation, cleanup failure, rapid transitions, failure
   rollback, quit/restart, stale jobs, and explicit user cancellation.
2. Speaker correction: selected Unknown, non-overlapping system segments can
   be assigned to an existing system speaker. Publish an immutable child
   revision under the existing artifact schemas; retain IDs, text, times,
   coverage, all raw provenance fields, and untouched assignments. Copy names,
   clear the active summary, and record parent/edit metadata in provenance.
   Undo validates the active child and restores the parent/summary, preserving
   current names for parent speakers. Reject busy/stale edits and stale undo;
   do not guess speakers, rewrite text, or assign overlap. Verify original-byte
   preservation, lock handling, citation consistency, undo and note regeneration.
3. Progress and resources: add bounded, count-only stage progress with explicit
   units. ASR reports known windows and clips within the current window; notes
   reports generated groups and reduction rounds; pyannote reports its actual
   hook counters. Keep indeterminate phases indeterminate and avoid fake ETAs.
   Native child lifecycle events must not reset stage time or rewrite metadata.
   Keep background QoS and serialize models. Provide pause/resume through safe
   cancellation/requeue. Measure MPS tensor/driver memory before proposing hard
   limits; do not add overlapping RSS/driver measurements or infer free RAM from
   the recommended GPU working set. Test malformed, stale and terminal progress,
   cancellation, counter bounds and monotonicity within each progress phase.
4. Review integration: use explicit selection controls for correction so mouse
   text selection keeps working. Add Cmd-F and next/previous transcript matches
   without hiding surrounding context; preserve playback at source timestamps.
   Export validated snapshots as UTF-8 Markdown/plain text using the current
   names and visible notes, with pending/stale notices and safe filenames.
   Use a nonblocking save panel. Verify Unicode, Markdown escaping, export scope,
   search navigation, stale snapshots and rendered layouts.
5. Final verification: review cross-track contracts, run relevant complete
   suites, inspect synthetic renders and export artifacts, build/sign a separate
   candidate, then replace the development app only after idle/cleanup checks.
   Keep real meetings unchanged and distinguish automated checks from hardware
   and live responsiveness acceptance deferred by the user.

Each milestone ends in a reviewable result. Add tests for state, mapping, and
publication invariants as those behaviors are implemented, not placeholder tests
of the current scaffold. No later milestone can turn an unmeasured result into
a pass by assumption.

#### Delivered continuation contracts

`ProcessingController` owns one active worker and its queue. Recording reserves
the coordinator before requesting cancellation, and capture starts only after
owned-process cleanup is confirmed. Recording completion or startup failure
releases that reservation. A newly saved recording goes ahead of deferred work;
explicit cancellation removes work instead of resuming it. **Pause Processing**
and **Resume Processing** control background work separately from recording
pause. Resumption can repeat an unfinished stage and uses fresh run IDs.

Each queued request has a bounded, schema-version-1
`work/<run>/request.json` snapshot with snake-case keys. It binds meeting/run/
revision/summary IDs, parent pointers, retained-audio fingerprint, language and
name-map revision. Existing meeting pending fields and `queued`/`paused` statuses
carry intent; no new meeting-schema fields were added. Recovery validates both
the snapshot and completed artifacts before reconstructing work. Missing or stale
queue snapshots become retryable failures. Only the final revision published by
that particular full run can convert its continuation to notes-only processing.

`SpeakerCorrections.assign` requires the editor's expected active revision,
distinct selected segment IDs, and an existing system-speaker ID. It holds the
meeting's exclusive processing lock and rejects capture, queued/paused work,
assigned or local segments, and overlap. New child artifacts retain segment IDs,
text, times, coverage, speaker set, untouched assignments and all raw provenance
fields. Files are staged, synchronized, validated and renamed before changing
the accepted pointer. Original artifacts remain byte-for-byte unchanged.

Provenance appends optional `speaker_corrections` records containing parent and
child identities, the parent's accepted summary ID, parent artifact hashes,
selected segment IDs and the target speaker. The child's input fingerprint binds
that correction. The child copies current names, clears accepted notes and stale
pending fields, and reports `transcript_ready` with a regenerate-notes message.
Undo validates the current child and its parent before restoring parent pointers;
current names are retained for the parent speaker IDs. Correction history works
after restart. Earlier notes can consequently display the existing stale-name
notice. Transcript and provenance schema versions remain 1.

The app opts into `--progress-events`; older callers retain the existing event
stream. `stage_progress` carries count-only `completed`, `total`, `progress_unit`
and `progress_phase` fields. Counters satisfy `0 <= completed <= total`, with
positive totals capped at one billion. Per-stage unit/phase pairs have stable
totals and monotonic counts; phases contain 1–96 ASCII identifier bytes, with at
most 4,096 distinct pairs per stage. Native child lifecycle messages do not
change stage timing or meeting metadata. UI labels describe audio sections,
speech segments, finding/comparing speakers, drafting notes and combining notes;
they do not display internal phase IDs or estimated completion times.

Review uses explicit checkboxes for eligible Unknown lines, leaving transcript
text selectable. Cmd-F searches transcript text and current speaker names;
Cmd-G and Shift-Cmd-G navigate matches without hiding surrounding context.
Exports cover notes, transcript, or both in UTF-8 Markdown/plain text. They load
validated accepted artifacts, use current names, and include pending/stale
notices. The nonblocking save panel rechecks revision, summary, names, title and
retained audio before writing. Filenames retain whole Unicode characters within
255 UTF-8 bytes; Markdown escapes literal markup and entity-looking text. Raw
provenance, model/runtime fields and attribution diagnostics are not exported.

Verification passed 84 Swift tests and 90 Python tests. Nine correction tests
cover publication, locks, stale edits/undo, name retention, and an actual
corrected-artifact notes-only worker run with model generation replaced by a
deterministic fixture. Six search/export tests cover Unicode, navigation, scopes,
escaping and stale snapshots. Six synthetic export files passed exact UTF-8
write/read and scope checks; the three Markdown files passed `markdownlint`.
The [default review render](.build/review-tools-preview-2026-10-01.png) passed
visual inspection. Offscreen public accessibility discovery returned no child
elements, so automated search/correction/undo interaction coverage is
inconclusive. User acceptance of those controls and recording preemption remains
open. Build, plist, signature and icon checks passed. The exact verified candidate
was subsequently promoted to `.build/Afterword.app` and reopened; the previous
bundle was retained as a rollback backup. All three meetings were idle, locks
were released before launch, and ten tracked metadata/accepted-artifact/runtime
files had identical hashes before and after promotion. Installation does not
establish responsiveness under model load.
Evidence: [test/build receipt](.build/continuation-tests-2026-10-01.json) and
[export receipt](.build/review-tools-exports-2026-10-01.json), plus the
[activation receipt](.build/continuation-activation-2026-10-01.json).

### M0: development bootstrap

Deliver the current Git/SwiftPM/Python scaffold and this plan. Follow the package
manifest and bundle patterns in section 2. Run `make check`, inspect the built
bundle, and manually launch the shell. No recording controls should imply that
capture already exists. Do not download models as a side effect of building.

### M1: capture, pause mapping, and crash recovery

Implement capture/store responsibilities under `Sources/AfterwordApp/`, extracting
a small `AfterwordCore` Swift target for testable state/timeline/store logic when
it exists. Add `Tests/AfterwordCoreTests/` at that point. Follow the Apple capture
sample for stream setup and sections 3–5 for application behavior.

Verification gate:

- Record a real headphone call and inspect both saved sources independently.
- Check unequal source starts and timestamp drift at the beginning and end.
- Test rapid Pause/Resume, a boundary-straddling buffer, a delayed old callback,
  repeated Stop, Stop while paused, permission denial, and immediate Stop.
- Kill the app during writing and between chunk commit and manifest update;
  confirm committed audio survives and the loss window meets section 4.
- Exercise microphone/device loss, sleep, disk-full failure, and queue overflow.
- Confirm source formats are inspected and paused phrases never reach disk.

Do not begin model integration until audio and timeline recovery are trustworthy.
Do not copy the Apple sample's screen/video writer into this audio-only product.

### M2: worker lifecycle and artifact transactions

Implement the process controller and Python protocol without loading models.
Use small controlled fixture executables to exercise child-process behavior;
they validate lifecycle contracts, not inference quality. Add meaningful Swift
and Python tests for publication, run IDs, and cancellation.

Verification gate:

- Cancel a running child and a hung child; confirm descendants exit and a new
  recording can start within the target bound.
- Terminate the app and worker separately; check cleanup and startup recovery.
- Test malformed/oversized events, full stderr pipes, exit zero with no artifact,
  incompatible protocol versions, and late events from an earlier run.
- Crash before and after artifact publication/pointer update; verify the previous
  transcript remains reviewable and incompatible results are not reused.

Do not add an HTTP server or treat native stdout as the worker event stream.

### M3: transcription and attribution feasibility

Resolve and lock pyannote/PyTorch and decoding dependencies on Python 3.12;
verify FFmpeg/TorchCodec requirements against the chosen pyannote release.
Build exact whisper.cpp and llama.cpp commits and record their provenance.
Provision models separately after their terms are accepted. Follow the sources
in section 2 for APIs; verify every CLI option against the pinned build.

Implement preparation, ASR, diarization, and alignment adapters under
`worker/afterword_worker/`. Save accepted transcripts before attempting summaries.

Verification gate:

- Use actual models on a short annotated sample and the longest target meeting.
- Measure each stage's wall time, peak process-tree memory, disk use, and total
  processing time. Whole-source diarization must fit, not just small excerpts.
- Inspect names/technical terms, code-switching where applicable, brief turns,
  silence, interruptions, overlap, and pause/gap timestamp mapping.
- Measure transcription error and speaker-attribution error on a manually
  annotated sample, and inspect every wrong attribution of an action owner.
- Verify cancellation while a model is active and inference with network access
  disabled. Missing local assets must produce a setup error, not a download.

If this gate fails, revisit model size, runtime, or the validated duration before
building the full review UI. Do not assume CUDA examples demonstrate Mac GPU use.

### M4: summaries and review workflow

Implement bounded summary extraction/reduction using the completion and grammar
references. Build the meeting list/detail flow, stage visibility, evidence links,
speaker renaming, cancellation, summary-only retry, and explicit full reprocess.

Verification gate:

- Check every decision/action in the annotated sample against its evidence.
- Force multiple reduction levels; confirm beginning/middle/end coverage and
  correct handling of a later reversal of an earlier decision.
- Reject nonexistent references, invalid JSON, unsupported owners/dates, and
  content that attempts to instruct the model or application.
- Rename after a completed summary and during generation; verify reference
  rendering and stale-prose behavior. Full reprocess must not transfer names
  to unrelated clusters or expose summaries from another transcript revision.
- Verify the rendered Record-to-Review workflow with real capture and models.

Do not infer UI correctness from unit tests or schema-valid JSON alone.

### M5: reproducible setup and release acceptance

Complete setup/preflight instructions in this document, native/model manifests,
offline checks, and recovery/error presentation. Add test commands to `make check`
once real test suites exist. Verify documentation against the pinned APIs and
check for shell-based process launch, remote model loading, hard-coded developer
paths, and model output leaking into logs.

Verification gate:

- Set up in a clean checkout/environment from the recorded pins and hashes.
- Run all automated suites plus every HLD acceptance scenario with actual audio.
- Validate on macOS 15 or explicitly narrow the supported OS claim before release.
- Re-run offline, process-tree cleanup, crash-window, and maximum-duration checks.
- Record measured acceptance results and unresolved limitations here.

No release readiness claim until the gates pass. Build success, recorded audio,
usable transcription, and verified end-to-end behavior are separate statuses.

## 8. Validation status and benchmark decisions

Implementation status on 2026-09-30: real-meeting recovery and app promotion
succeeded. Capture is stopped and processing is completed. The active transcript
revision is `55c689ec-fbb6-41fc-95fb-a88a56bc27b0`; the active summary is
`aae07320-649c-427f-93c1-46637db935c8`. Independent validation covered all 764
transcript segments and the published notes. The summary contains 6 overview
items, 14 discussion points, 4 decisions, 7 actions, and 5 open questions.
Original chunk and interval metadata were unchanged; all 391 microphone and
391 system chunk paths still exist.

Latest results: **90 Swift and 102 Python tests pass**. Swift includes 76 XCTest
cases and 14 Swift Testing cases; the host Python run completed in 5.497 seconds.
Coverage includes recording-priority queue/cleanup/restart behavior, manual
speaker correction and undo, progress validation, search, export, earlier
publication/recovery, ASR batching, VAD padding attribution, capture failure
guards, native language policy, and automatic notes extraction reuse. The continuation
candidate built successfully and passed plist, signature and icon checks, with
source hashes unchanged during verification. Its default review layout passed
synthetic rendering. The exact candidate was promoted and reopened with accepted
meeting data and runtime hashes unchanged, and the prior bundle retained. Live
recording preemption, new review-control interactions and responsiveness still
need acceptance. See the
[continuation receipt](.build/continuation-tests-2026-10-01.json) and
[activation receipt](.build/continuation-activation-2026-10-01.json).
The user confirmed mouse selection and copy on the preceding review build;
that earlier review evidence is recorded in
[`.build/review-polish-2026-10-01.json`](.build/review-polish-2026-10-01.json).
Earlier transcription-first integration evidence is recorded in
[`.build/transcript-first-integration-2026-10-01.json`](.build/transcript-first-integration-2026-10-01.json).
The older `.build/meeting-name-check.log` records an earlier test/build snapshot.

| Area | Verified | Still required |
| --- | --- | --- |
| Capture and persistence | Real microphone and system tracks were retained. The recovered transcript has 257 microphone and 507 system segments. Swift tests cover storage, pause mapping, preparation, rename persistence, and lifecycle cases. | Permission edge cases, measured clock drift, device changes, sleep, disk-full behavior, and measured crash-loss window remain open. |
| Worker lifecycle | Cooperative cancellation, forced cleanup, SIGKILL guardian-lock retention, and real two-source artifact recovery passed. Latest full Swift/build integration includes 11 queue tests, guarded recording reservation, durable restart intent, explicit cancellation and progress boundaries. Swift validated early and final replay artifacts. | Cancellation during active model inference and recording startup, responsiveness, and additional real crash scenarios. |
| Reproducible setup | Pinned native builds, model integrity checks, Python imports/resampling, Community-1 provisioning, and a full real CPU diarization run passed. | Fresh-machine setup and reproducibility acceptance. |
| ASR | Chinese/English Auto produced the 764-segment real transcript. The short Chinese-language detection failure has an explicit language override; padded-timestamp normalization is covered by regressions. | Manually annotated recognition accuracy, rapid code-switching, interruptions, and agreed quality thresholds. Auto can still misclassify short, ambiguous speech. |
| Speaker attribution | Full CPU and MPS runs both yield 77 attributed and 430 Unknown system segments. Their exclusive labels agree across all common speech after label matching; the accepted transcript was not replaced. Manual correction/undo preserves immutable evidence and passes locks, stale-revision, rename-retention and notes-only compatibility tests. | Human attribution/overlap accuracy, manual correction UI acceptance, and representative meetings with multiple remote speakers. The benchmark contains only one remote cluster. |
| Summary | Complete notes are published with coverage of all 764 segments, validated references and exact action quotes. Repair budgeting, source-constrained action selection, bounded citations, remaining-context output allocation, and extraction checkpoint reuse passed tests and the recovered run. | Human factual/completeness review, handling of later reversals, and broader notes-quality acceptance. Structural validation is not a factual-quality score. |
| Offline operation | A fresh full two-source worker run passed with network access denied and no ASR or extraction checkpoint reuse. The standalone full remote-source MPS benchmark also passed under network denial. | Further offline recovery scenarios and broader acceptance recordings. |
| Review UI | Transcription-first review, saved names, selectable notes, optional evidence, compact rows, approved icon, correction controls, search and Markdown/plain-text export are implemented. Default layout, search/export tests and six synthetic export files passed. The user confirmed mouse selection/copy on the preceding build. | New control/save-panel interaction, correction/search layouts in use, and full Record-to-Review, retry and playback acceptance remain open; offscreen accessibility automation was inconclusive. |
| Performance and compatibility | The October 1 packaged-ASR candidate completed a fresh worker run in 612.495259 seconds. The serial-notes candidate took 768.058921 seconds under observed memory pressure. Both exactly matched baseline outputs; these were different sessions. | The 486.634547-second budget remains exceeded. Further latency reduction, a literal UI Stop-to-review measurement, 60/120-minute benchmarks, total process-tree/GPU memory, and macOS 15 runtime validation remain open. |

Historical recovery stages and the separate MPS comparison:

| Stage | Wall time | Scope |
| --- | --- | --- |
| ASR | 603.8 s | Earlier recovery measurement; not a lower bound on current ASR performance. |
| Community-1 diarization | 1,376.480 s | Full remote source on CPU. |
| Community-1 MPS comparison | 68.575763 s | Separate full-source production-adapter benchmark; includes child startup, imports, loading, inference, validation, and cleanup. |
| Final notes reduction | 56.855 s | Reused six validated extraction groups; excludes their generation and earlier retries. |

The MPS comparison used 1,946.538 seconds of prepared remote audio (about 32.44
minutes), batch sizes 32/32, and 12 threads, with network access denied. It was
20.07 times faster than the CPU stage. Peak child RSS was 1,442,496,512 bytes
(about 1.34 GiB), not a measurement of total process-tree or GPU memory. It
produced 503 regular and 502 exclusive turns with one remote cluster. Labels
agreed across all 1,062.214 seconds of common exclusive speech; CPU alone had
another 16.875 ms of speech. No original audio or accepted artifacts were changed.

Both runs leave the same 430 remote segments Unknown: 402 have incomplete turn
coverage, 20 have no supporting turn, 4 involve model padding, 3 cross an ASR
window, and 1 overlaps speech. A separate timed-token inspection matched 505 of
507 raw segments: of 3,608 lexical tokens, 3,425 had valid timing, 173 had zero
duration, and 10 extended beyond audio. Complete valid timing existed for 371
segments. It identified 98 additional strictly token-supported attribution
candidates, but these are not human-validated or accepted speaker assignments;
no attribution changes were applied.

The historical recovery timings are not a complete Stop-to-summary stopwatch;
the 56.855-second reduction excludes earlier extraction and retries. A paired
ASR probe on the same 16 files (84.64 seconds of audio) measured 10.488 seconds
with the default 4 threads and 10.965 seconds with 12 threads, 4.55% slower.
All 16 normalized texts, languages, and timestamps matched the historical
outputs exactly. Encoding consumed 8.424 seconds over 33 calls, about 80% of the
default batch time. The production thread setting remains unchanged. The earlier
batch receipt suggested about 22.371 seconds, but its difference from the fresh
probe is unexplained; no thermal or power traces were captured.

A fresh full worker benchmark then ran on isolated inputs with MPS and network
access denied, reusing neither ASR nor summary extraction. Measurements are
retained in [`.build/benchmark-2026-09-30.json`](.build/benchmark-2026-09-30.json):

| Fresh worker stage | Wall time |
| --- | --- |
| Worker preparation/preflight | 0.397793 s |
| ASR | 463.255797 s |
| MPS diarization | 90.079506 s |
| Alignment | 0.025511 s |
| Summary, including extraction and reduction | 274.165597 s |
| Total worker elapsed | 827.938614 s |
| Native audio preparation, separately measured | 1.566627 s |
| Sum of worker and native preparation measurements | 829.505241 s |

The 764 transcript segments exactly matched the accepted transcript, with the
same 77 attributed remote segments. Notes again contained 6 overview items,
14 discussion points, 4 decisions, 7 actions, and 5 open questions, with coverage
of all 764 segments. Content in all five note fields and the coverage IDs exactly
matched the accepted notes. The production Swift validator accepted the fresh
transcript and notes with `metadata_written=false`; original metadata and
accepted artifacts were unchanged. Native preparation on isolated CAF copies
reproduced both original prepared WAV hashes and all timeline pieces exactly.
Peak child RSS was 5,332,893,696 bytes (about 4.97 GiB); this is not whole-process
tree or GPU memory.

The fresh worker took about 13 minutes 48 seconds against a total budget of
486.634547 seconds (about 8 minutes 7 seconds). Adding the separately measured
native preparation gives 829.505241 seconds, about 13 minutes 49.5 seconds, still
over budget. This sum excludes UI startup and Stop finalization; it is not a
literal UI Stop-to-review stopwatch. Cleanup of all 207 owned native process
groups was confirmed, and the model runs exited successfully. Disposable worker
and preparation clones were removed after validation; the compact receipt and
all 782 original audio files were retained. This benchmark changed no production
code or configuration.
The app-open command succeeded after validation; visual verification remains
incomplete. These are the September 30 baseline results; the October 1 candidate
checkpoint below records later work separately.
The fresh ASR stage is faster than the historical 603.8-second run, so that old
measurement must not be treated as a current ASR lower bound.
The earlier 29.899625-second synthetic local-only fixture completed in 15.987
seconds, but it was never evidence of long-meeting throughput.

### October 1 optimization checkpoint

The packaged native encoder-reuse candidate passed 13 API cases with exact
hex-float values, token/segment/language results, callback counts, and return
values. A 16-file CLI corpus, including input longer than 30 seconds, preserved
results while reducing encoder calls from 33 to 17:

| Order | Unmodified baseline | Patched, disabled | Patched, enabled |
| --- | --- | --- | --- |
| Baseline → disabled → enabled | 10.370 s | 11.497 s | 7.077 s |
| Enabled → disabled → baseline | 12.850 s | 12.793 s | 7.060 s |

The controlled sample improvement was approximately 32–45%. Full packaged ASR
then completed in 172.863 seconds, with all 764 segments and all 362 raw JSON
results exactly matching the accepted output. The earlier isolated ASR stage
took 463.256 seconds in a different session; the entire difference must not be
attributed to the patch.

A fresh full-pipeline candidate run subsequently passed with neither ASR nor
extraction reuse. All 764 transcript segments, all 362 raw ASR JSON results, and
the notes exactly matched the baseline:

| October 1 candidate worker stage | Wall time |
| --- | --- |
| Worker preparation/preflight | 0.443743 s |
| ASR | 160.435538 s |
| MPS diarization | 101.186773 s |
| Alignment | 0.025315 s |
| Summary | 350.396391 s |
| Total worker elapsed | 612.495259 s |

The worker alone remains 125.860712 seconds over the 486.634547-second total
budget. This is not a UI Stop-to-review measurement. Production Swift validation
and live activation/readiness checks passed. Notes prompts, context, and behavior
remain unchanged. A shared-model notes prototype preserved all six cached
extraction outputs exactly in 117.718 seconds with serial execution. Four-way
execution took
229.520 seconds and changed groups 2 and 5, so parallel extraction was rejected.
The serial adapter and exact partition search passed 67 worker tests, including
real subprocess cancellation, receipt and
source binding, per-job repair, legacy compatibility, and publication failure.
Native setup tests are separate from that count. A fresh full-worker gate passed
without ASR or extraction reuse: all 764 segments, 362 raw ASR JSON outputs, six
extraction groups, and final notes exactly matched the accepted baseline.
Production Swift validation passed without writing metadata; original accepted
artifacts were untouched. The worker changes are promoted and the permanent
serial helper is installed and enabled, retaining the ASR encoder-reuse opt-in.
The prior runtime is preserved as
`runtime-before-serial-summary-164fdaa77674471d8cb20ac2a74e4c69.json` in the app's
Application Support directory. Activation evidence is recorded in
[`.build/serial-summary-activation-2026-10-01.json`](.build/serial-summary-activation-2026-10-01.json).
Final runtime hash verification passed with no missing or corrupt assets. The
app was reopened and its running process confirmed; no visual verification is
claimed.

| Serial summary candidate stage | Wall time |
| --- | --- |
| Worker preparation/preflight | 0.530528 s |
| ASR | 234.073244 s |
| MPS diarization | 221.120517 s |
| Alignment | 0.026552 s |
| Summary | 312.283850 s |
| Total worker elapsed | 768.058921 s |

Summary time was 312.284 seconds versus the prior run's 350.396 seconds; these
different sessions are not a controlled speed comparison. The latest total,
about 12 minutes 48 seconds, still exceeds the 486.634547-second budget and
excludes native audio preparation and UI overhead. Summary work included 72
tokenizer calls taking 20.1804 seconds, a 200.7113-second native cohort, and an
88.8936-second final completion. Memory-pressure level 2 and 20,251.62 MiB of swap
were observed during summary generation; no thermal or performance warning was
recorded. These observations do not establish the cause of timing variation.
All 118 owned process groups were cleaned up. The compact receipt is
[`.build/serial-summary-benchmark-2026-10-01.json`](.build/serial-summary-benchmark-2026-10-01.json).
Disposable full-worker and validation copies were removed after validation;
the original audio, accepted artifacts, runtime backups, and receipts remain.

Notes experiments did not justify changing production prompts, context, or
behavior:

- A 32K one-pass run finished in 102.766 seconds and produced valid JSON, but
  omitted all seven baseline actions and cited only the first third of the
  meeting. It ended normally rather than exhausting output space and was rejected.
- Removing extraction timestamps failed the synthetic superseded-action check;
  the full real-input trial was not launched.
- Grouping equivalent action-owner grammar branches preserved exact parsed notes.
  Wall time changed from 22.443 to 21.001 seconds, but aggregate native sampling
  time changed only from 198.79 to 146.16 ms, about 0.05 seconds and less than 0.3%
  of model time. Most wall-time variation lay in GPU prompt/decode timings, so
  added production grammar complexity was rejected as a non-bottleneck.
- Factoring literal citation prefixes passed native grammar equivalence checks,
  but has no demonstrated performance benefit and was not adopted.

### Current-workload and ASR batch measurements

A fresh full-worker baseline under the user's current workload took 684.391412
seconds. Its transcript, extraction groups, and notes matched the accepted
artifacts, and production Swift validation passed:

| Current-workload baseline stage | Wall time |
| --- | --- |
| Worker preparation/preflight | 0.575794 s |
| ASR | 188.756411 s |
| MPS diarization | 151.401546 s |
| Alignment | 0.025643 s |
| Summary | 343.531806 s |

System-wide counter deltas showed about 27 GiB of cumulative decompression,
about 20 MiB swapped in, and no swap-out during that run. Memory-pressure level
rose from 1 to 2 after diarization and returned to 1 after processing. This
demonstrates pressure under the measured workload, not an established leak or
proof that all pressure came from Afterword. A roughly 5 GB child RSS measurement
does not include the complete GPU allocation footprint. Background worker QoS
and descendant scheduler priority have since been verified in focused tests;
responsiveness improvements are not yet verified. A later guarded MPS probe used
a five-minute excerpt, the existing 32/32 batch sizes and 12 threads, background
QoS and network denial. It sampled 3.855 GiB peak MPS driver allocation, 0.973 GiB
peak live tensors and 675 MiB peak child RSS. These overlap and must not be added;
the recommended GPU working-set value is not free RAM. Sampling requested
250-millisecond intervals, with a largest observed gap of 874 milliseconds, so
these are sampled peaks rather than exhaustive allocation bounds.

After deleting the model and collecting garbage, tensor allocation reached zero
while 3.058 GiB remained in the driver allocator; explicitly emptying its cache
reduced that to 3.70 MiB. This is evidence of reclaimable caching in this probe,
not a proof that long-running leaks are absent. Inference took 18.627 seconds;
the complete child took 101.785 seconds including imports, model loading and
measurement phases. All three meetings were idle before the probe, original
audio/metadata/artifacts/runtime hashes were unchanged afterward, and owned
process groups exited. No batch-size policy or RAM/GPU cap changed. Memory and
responsiveness across a full meeting under normal multitasking remain unverified.
Evidence: [guarded memory probe](.build/diarization-memory-2026-10-01.json).

The promoted ASR batch policy increases the maximum from 16 to 64 utterances
within each VAD window. On the same 57 clips in ABBA order, all complete native
JSON outputs were identical:

| Batch size | First run | Second run |
| --- | --- | --- |
| 16 utterances | 27.642843 s | 26.115672 s |
| 64 utterances | 25.763832 s | 25.883211 s |

The mean improvement was about 3.93% on this small sample. Full candidate ASR
took 167.077085 seconds using 13 Whisper and 15 VAD calls, preserving all 362 raw
JSON outputs and all 764 segments exactly. Accepted meeting metadata was
unchanged. Cache policy is now `ASR_VERSION = 5`. The full pipeline has not been
remeasured with the 64-utterance policy; the 684.391412-second baseline above
must not be presented as its result. The receipt is
[`.build/asr-batch-2026-10-01.json`](.build/asr-batch-2026-10-01.json).

### Transcription-first integration checkpoint

Real-artifact replay verified all 764 evidence records unchanged, including local
attribution, with all 507 remote segments explicitly pending in the early
transcript. A missing Community-1 model left that transcript published; retry
reused compatible ASR, produced final segments exactly matching the accepted
output, and left the early revision immutable. Production Swift validators
accepted both revisions without writing original meeting metadata. Evidence is
recorded in
[`.build/transcript-first-real-artifacts-2026-10-01.json`](.build/transcript-first-real-artifacts-2026-10-01.json).

This was an artifact/publication replay, not a fresh neural-inference run: ASR
replayed validated real ASR64 output, and labeling/summary replayed accepted
outputs. It verifies publication ordering, compatibility, evidence stability,
and artifact validation, not new model performance or visual readiness. The
prelaunch termination-handler fix passed six grouped lifecycle tests and the full
54-test Swift suite. The app build, plist, and signature checks passed; the
rebuilt app was reopened. Visual readiness and responsiveness under live model
load are not yet verified. Background QoS is not a RAM or GPU allocation cap.

### Long-meeting acceptance

The detected M3 Max / 64 GB machine is the initial benchmark target. Chinese and
English are required, including mixed-language samples. End-to-end processing
from Stop/finalization through a validated summary targets 15 minutes per hour
of retained meeting audio on the representative long-meeting benchmark. Normal
multitasking takes priority: processing may take longer to yield resources, and
users need not close other applications. Responsiveness under their usual
workload must be measured separately from maximum-throughput timing.
The audio duration is the union of retained meeting intervals, not the sum of
microphone and output durations. Include model loading in the measurement;
one-time model download/build is setup, not meeting processing.

Typical/maximum meeting duration and quality thresholds remain unconfirmed.
Provisionally benchmark 60- and 120-minute recordings in M3, without claiming
120 minutes as an agreed maximum. The corresponding throughput targets are 15
and 30 minutes. Report short-input latency separately; a per-hour target does
not establish an acceptable fixed delay for a very short recording. These open
items do not block M0–M2, but must be settled before release acceptance.

Record a small benchmark table here during M3 containing input duration/languages,
model/build hashes, stage runtimes, peak memory, transcript/attribution errors,
summary factual errors, and pass/fail against the agreed thresholds. Keep raw
meeting audio/transcripts outside the repository; use consented synthetic or
redacted fixtures for committed tests.

## 9. References

- [Apple capture sample][capture]
- [Apple microphone authorization][permissions]
- [CoreMedia clocks][clocks]
- [Apple bundle layout][bundle]
- [Swift package manifest][swiftpm]
- [whisper.cpp CLI implementation][whisper-cli]
- [Community-1 model card][community]
- [pyannote setup and telemetry][pyannote]
- [llama.cpp completion tool][completion]
- [llama.cpp CLI behavior][llama-cli]
- [llama.cpp grammars and JSON Schema][grammars]
- [Google installed-app OAuth][google-native-auth]
- [Google Calendar scopes][google-calendar-scopes]
- [Google Calendar list API][google-calendar-list]
- [Google events list API][google-events-list]
- [Apple macOS Keychains][mac-keychains]

[capture]: https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos
[permissions]: https://developer.apple.com/documentation/bundleresources/requesting-authorization-for-media-capture-on-macos
[clocks]: https://developer.apple.com/documentation/coremedia/cmclock
[bundle]: https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle
[swiftpm]: https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html
[whisper-cli]: https://github.com/ggml-org/whisper.cpp/blob/master/examples/cli/cli.cpp
[community]: https://huggingface.co/pyannote/speaker-diarization-community-1
[pyannote]: https://github.com/pyannote/pyannote-audio
[completion]: https://github.com/ggml-org/llama.cpp/blob/master/tools/completion/README.md
[llama-cli]: https://github.com/ggml-org/llama.cpp/blob/master/tools/cli/README.md
[grammars]: https://github.com/ggml-org/llama.cpp/blob/master/grammars/README.md
[google-native-auth]: https://developers.google.com/identity/protocols/oauth2/native-app
[google-calendar-scopes]: https://developers.google.com/workspace/calendar/api/auth
[google-calendar-list]: https://developers.google.com/workspace/calendar/api/v3/reference/calendarList/list
[google-events-list]: https://developers.google.com/workspace/calendar/api/v3/reference/events/list
[mac-keychains]: https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains
