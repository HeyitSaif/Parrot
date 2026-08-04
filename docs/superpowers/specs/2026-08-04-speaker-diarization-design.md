# Speaker diarization — who said what

Design spec, 2026-08-04. Research + prototype validated on real call audio;
implementation not started.

## Problem

When a call has more than one remote participant, Parrot can't tell them
apart. The mic stream is labeled "Me"; everything from system audio is "Them",
one collective bucket. The single `themName` field makes it worse for group
calls: the Aug 3 stakeholder call is named "Dietift Stake Holders" — two
different people collapsed into one pseudo-person, and the post-call report
can't say who committed to what.

The current `DiarizationEngine` is an honest placeholder: it splits system
audio on silence gaps and **alternates** "Speaker 1"/"Speaker 2" labels. On
the Aug 3 call it produced 47/41 segments whose assignment disagrees with the
acoustic reality roughly half the time — which is why the UI deliberately
collapses those labels back into `themName`.

## What Parrot already has (the good news)

The feature is an *engine swap plus UX*, not a greenfield build. Existing
pieces, verified in code:

| Piece | Where | State |
|---|---|---|
| Mic vs system as separate streams | `AudioCaptureManager` | ✅ "Me" is free and always right |
| Audio retained per meeting, 16 kHz mono PCM `.caf` | `Meeting.systemAudioPath` / `micAudioPath` | ✅ exactly the input diarization models want; enables re-processing old meetings |
| `TranscriptSegment.speakerLabel: String?` | model | ✅ schema needs no change for phase 1 |
| Post-call diarize → overlap-assign labels | `RecordingManager.postProcess` (~L608) | ✅ seam exists; only the engine behind it is fake |
| Diarization failure = soft degrade to "Them" | `postProcess` catch | ✅ keep exactly this behavior |
| Rename UI | `MeetingDetailView` "Name the other speaker" | exists, but single-name; becomes per-speaker |
| Model download UX pattern | Whisper model flow in onboarding/settings | reuse for diarizer models (34 MB) |

## Prototype evidence (Aug 3 call, 3 people, Turkish)

Ran FluidAudio's CoreML pyannote pipeline (`fluidaudiocli process`) on the
real `system_2026-08-03T12-00-32Z.caf`:

- **Speed**: 981 s of audio in 6.2 s cold, ~380× realtime warm, on-device.
  Post-call diarization costs seconds, not minutes.
- **Models**: 34 MB on disk, auto-downloaded once (segmentation + embedding).
- **Default threshold (0.7) failed**: merged both remote voices into one
  cluster — two same-language voices through the same meeting-app audio
  processing are acoustically close.
- **Threshold 0.5–0.6 succeeded**: two clusters, 406 s vs 45 s of speech.
  Spot-checking cluster 2's lines confirms a coherent second person (the one
  who "couldn't look at the dashboard much", answers "Ben buradayım", asks
  what model Parrot uses) — a real separation, not noise. 0.4 over-fragments
  (14 clusters).
- Short utterances sometimes get no cluster (kept "Them" today) — needs a
  nearest-turn fallback rather than a hole.
- Forcing `numClusters` appeared to be ignored by the offline path in the CLI
  — verify against the library API before relying on a "how many people were
  on this call?" hint.

Takeaways: quality hinges on one tunable (clustering threshold), we can
calibrate it against our own recordings because we keep the audio, and user
correction must be first-class because no threshold is perfect.

## Competitive picture (Aug 2026)

- **Meetily**: diarization is Pro-only ($10/mo) and their #1 community
  complaint; open repo contains no wired-up diarization (may not have shipped
  at all). Markets "no voiceprint database" as a privacy feature.
- **Anarlog** (ex-Hyprnote/Char, GPL, ~9k stars): free tier is exactly
  Parrot's current state — mic="you", system=other channel. Acoustic
  diarization only via **cloud** STT vendors (AssemblyAI/Deepgram/pyannoteAI
  adapters), Pro $15/mo. Clever no-biometrics trick: post-call LLM maps
  clusters to calendar participants from transcript evidence at ≥0.9
  confidence.
- **MacWhisper**: on-device speaker recognition via Argmax WhisperKit Pro +
  SpeakerKit (commercial license).
- **Otter/Krisp**: persistent voiceprints that auto-label future meetings —
  the stickiest version, but cloud (Otter) and biometric-sensitive.
- **UX conventions across all of them**: "Speaker 1/2/3" + stable per-speaker
  color; rename once → whole cluster renames; Descript's gold-standard wizard
  plays a short clip per detected voice and you type the name; best popovers
  suggest calendar participants; cluster-wide vs single-segment reassignment.

**The wedge**: nobody local-first ships free on-device acoustic diarization.
Shipping it free undercuts Meetily's paywall and Anarlog's cloud dependency at
their most-demanded feature, and it's already on Parrot's wishlist.

## Approaches considered

1. **FluidAudio (recommended)** — Apache-2.0 Swift package (v0.15.5,
   Jul 2026, ~2.6k stars, active), CoreML pyannote Community-1 pipeline
   (segmentation + WeSpeaker v2 embeddings + VBx clustering), macOS 14+,
   **zero external SwiftPM deps** (no conflict with WhisperKit), models
   auto-download ungated from HF (34 MB landed on disk for the diarization
   path; no HF token needed, unlike pyannote's own gated repos). Published
   benchmark: **15.07% DER avg (10.7 median) on AMI-SDM at ~122× realtime**
   — production-class. Offline + streaming modes, per-segment embeddings,
   `speakerDatabase`, and `SpeakerManager.initializeKnownSpeakers` /
   `enrollSpeaker` — voice profiles are first-class API. Adopted by
   VoiceInk/Spokenly/BoltAI. Validated on our own audio today. Risks: young
   project (pin a tag; Apache-2.0 allows vendoring); **models are CC-BY-4.0**
   (pyannote-derived) → attribution line in app credits required.
2. **Argmax SpeakerKit** — now open source: WhisperKit graduated into
   `argmax-oss-swift` v1.0.0 (MIT, May 2026) bundling WhisperKit + SpeakerKit
   (pyannote v4 CoreML, auto speaker count, joint diarized transcription);
   Parrot's existing dependency URL redirects there, so this looks like the
   cheapest integration — **but the OSS tier exposes no speaker-embedding /
   enrollment API**, so persistent voice profiles (phase 3) would require
   SpeakerKit Pro (commercial, opaque pricing). Rejected as primary for that
   gap; FluidAudio is validated and free end-to-end. Note regardless of
   diarizer choice: the **WhisperKit 0.9 → argmax-oss 1.0 migration** is
   coming for our transcription dependency — track it as separate
   maintenance.
3. **sherpa-onnx** — Apache-2.0, same pyannote segmentation + embedding
   pipeline over onnxruntime, proven Swift examples for diarization *and*
   embedding extraction. But no first-party SwiftPM support: hand-built
   xcframework + C bridging + dylib-packaging care (App Store rejection
   reports exist for loose dylibs). Several days of integration for the same
   models FluidAudio ships in CoreML with ANE offload. Escape hatch if
   FluidAudio stalls. (Avoid the Rev reverb-diarization model —
   non-commercial license.)
4. **Cloud diarization** (Deepgram already integrated for opt-in streaming
   STT) — Deepgram returns `speaker` per word when diarize=true. Fine as a
   bonus for users already on cloud STT, but cannot be the main path:
   local-first is the product line and the competitive wedge.
5. **Rejected outright**: whisper.cpp tinydiarize (speaker-turn tokens only,
   `small.en`/English-only — useless for Turkish calls, frozen since 2023);
   embedding Python/pyannote in the app (GB-scale, notarization pain, no
   ANE — no shipped Mac app does it); waiting for Apple (macOS 26
   SpeechAnalyzer ships transcription + VAD, **no diarization API**).

## Design

### Phase 1 — real diarization (the engine swap)

Replace `DiarizationEngine`'s energy heuristic with FluidAudio behind the
existing interface; everything downstream already works.

- `Package.swift`: add `FluidAudio` (pin exact version).
- `DiarizationEngine.diarize(audioURL:)` → load 16 kHz floats (already have
  caf reader), `DiarizerManager.performCompleteDiarization(samples)`, map
  `TimedSpeakerSegment` → existing `SpeakerSegmentResult`. Keep
  `isProcessing`/`progress` (FluidAudio has a progressHandler).
- Config: `clusteringThreshold` default **0.6** for call audio (not the 0.7
  library default — see prototype), rest defaults. `// ponytail:` note the
  knob and why.
- Models: `DiarizerModels.downloadIfNeeded()` on first use; surface state via
  the same pattern as Whisper model download (progress in Settings +
  first-run). Settings row shows "Speaker detection models (34 MB)" with
  download/delete. No models → postProcess silently keeps "Them" (current
  soft-degrade), plus a one-time hint.
- Assignment: keep max-overlap, add fallback — a non-Me segment with zero
  overlap inherits the label of the nearest-in-time diarized turn (kills the
  stray "Them" leftovers; 8 of them on the Aug 3 call).
- Persist per-speaker mean embeddings on the meeting
  (`speakerEmbeddingsData: Data?` JSON `[label: [Float]]`) — cheap now,
  feeds phases 3–4.
- **Re-run on old meetings**: context-menu + detail-view action "Detect
  speakers again" → wipes non-Me labels, re-runs postProcess with the real
  engine. Works because audio is retained. This is how the Aug 3 meeting
  gets fixed without re-recording.
- Live view unchanged this phase: bubbles still say Me/Them during recording;
  labels refine when the call ends (matches current behavior where
  diarization is post-call).

### Phase 2 — naming UX (label the voices)

Data model:
- `Meeting.speakerNames: [String: String]` (label → display name), stored as
  Data/JSON like `profileSnapshotData`. `displayName(forSpeaker:)` consults
  it; `themName` migrates in as the name for the largest non-Me cluster (or
  stays the collective fallback when there's exactly one cluster) and the
  field is kept for old rows.
- `speakerCount` becomes distinct display names (unchanged logic, now
  meaningful).

UI (transcript tab):
- Speaker chip on each bubble gets a stable per-speaker color (Theme-driven,
  index-based palette).
- Click chip → popover: name field, **play buttons for that speaker's 2–3
  longest/highest-quality segments** (`AVAudioPlayer` over the retained
  system `.caf`, seek to segment range — no clip files needed), "apply to
  this segment only" toggle for mis-clustered lines (Anarlog's all/segment
  pattern).
- Naming two clusters identically merges them at display level — that's the
  whole merge UI. No split UI in v2; per-segment reassign covers it.
- Header keeps one field per detected speaker instead of the single "Name
  the other speaker" TextField.

Report/Copilot prompts: transcript lines already carry labels into prompts;
switch to display names so reports say "Gürkan flagged onboarding" instead of
"Speaker 2". One-line change at the prompt builders.

### Phase 3 — voice profiles (opt-in "remember this voice")

- `SpeakerProfile` @Model: name, centroid embedding ([Float] as Data),
  sampleCount, updatedAt. Created/updated only when the user names a speaker
  and the **"Remember voices" setting (default off)** is enabled — biometric
  data, so explicit opt-in, local-only, listed + deletable in Settings.
  (Meetily markets *not* storing voiceprints; we match their privacy story by
  default and beat them when the user opts in.)
- Post-diarization: cosine-match cluster centroids against profiles. Store
  3–5 embeddings per profile taken from ≥5 s clean segments; match on
  max/mean cosine, starting threshold ~0.5–0.6 on the WeSpeaker embeddings
  (research consensus; no universal number — calibrate on our recordings and
  expect compressed call audio to score lower than mic audio). Hysteresis:
  suggest at lower confidence, auto-apply at higher. Auto-applied names
  render normally but stay re-editable; corrections update the profile.
  FluidAudio's `SpeakerManager.initializeKnownSpeakers` supports seeding
  known voices directly into the pipeline — prefer that over hand-rolled
  matching if it fits.
- "Me" enrollment is free: mic stream is definitionally the user — profile
  built silently from mic embeddings, later lets imported single-track files
  auto-tag which speaker is the user.
- Optional no-biometrics assist (cheap, uses existing Copilot provider): ask
  the LLM to propose cluster→name mappings from transcript evidence
  ("thanks, Gürkan" right after cluster 2 speaks), suggestion-only. Anarlog
  ships this; for us it's an optional refinement, not the backbone.

### Phase 4 — live diarization (later, separate spec)

FluidAudio has streaming diarizers, but their published numbers say choose
carefully: chunked-pyannote streaming is bad (38–53% DER — avoid), Sortformer
is ≤4 speakers at 31.7% DER (NVIDIA Open Model License — legal review before
shipping), **LS-EEND is the target**: up to 10 speakers, 100 ms updates,
20.7% DER, MIT models, plus `enrollSpeaker` pre-enrollment. Live labels will
still be visibly worse than the post-call pass — show provisional Speaker N
live, reconcile when the call ends. Copilot prompts gain speaker names
mid-call. Not designed further here — post-call value ships first.

## Migration

- SwiftData: only additive fields (`speakerEmbeddingsData`, `speakerNamesData`)
  with defaults — same lightweight-migration pattern as `notes`/`wasRecovered`.
- Old meetings keep their labels until the user hits "Detect speakers again".
- `themName` → seeded into `speakerNames` on first open of a meeting detail.

## Risks

| Risk | Mitigation |
|---|---|
| Similar voices merge (seen at default threshold) | ship 0.6 default; per-segment reassign + rename-to-merge; optional "number of speakers" hint if library supports forced k (verify — CLI offline path ignored it) |
| Over-fragmentation on long calls | rename-to-same-name merges; profiles (phase 3) absorb fragments matching one person |
| Overlapping speech / crosstalk | pyannote handles overlap better than most; accept imperfection, per-segment fix exists |
| FluidAudio is young | pin version; Apache-2.0 allows vendoring; sherpa-onnx as escape hatch; interface seam (`SpeakerSegmentResult`) keeps the engine swappable |
| Voiceprint privacy | phase 3 opt-in default-off, local-only, deletable; phases 1–2 store nothing biometric beyond the meeting's own audio we already keep |
| Model download friction | 34 MB, one-time, same UX as Whisper models; feature degrades to today's behavior without it |
| Model licensing | diarization models CC-BY-4.0 → add attribution (pyannote community-1 / FluidAudio) to About/credits; Apache-2.0 code is fine commercially |
| WhisperKit 0.9 → argmax-oss 1.0 migration lands mid-flight | independent of FluidAudio (zero shared deps); schedule the bump as its own task |

## Validation

- `--diarize-test` harness flag (SnapshotTool pattern): run engine on a
  committed ~30 s synthetic two-voice fixture (generate with `say -v` two
  voices) → assert ≥2 clusters, assignment sanity, and wire into `make test`.
- Real-data eval script (dev-only, reads the local SwiftData store):
  `scripts/dev/diarization-compare.py` joins a `fluidaudiocli process` JSON
  against a meeting's stored transcript — rerun on the Aug 3 call after any
  threshold change; eyeball cluster-2 coherence.
- Manual: re-run on 2–3 real multi-party calls, confirm naming flow end-to-end.

## Effort (rough)

- Phase 1: ~1–2 days incl. model-download UX and re-run action.
- Phase 2: ~2–3 days, mostly popover/clip-playback UI.
- Phase 3: ~2 days incl. settings + matching calibration.
- Phase 4: unscoped, separate design.

Phases 1+2 together are the shippable headline ("Parrot now knows who said
what — free, on your Mac"); 3 is the retention feature; 4 is the wow.
