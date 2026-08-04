# Speaker Diarization Phase 1 Implementation Plan

> **Outcome (2026-08-04):** executed inline, all tasks done, with one
> deviation discovered during validation: the engine uses the **chunked
> `DiarizerManager` pipeline, not `OfflineDiarizerManager`** — the offline
> VBx pipeline merges the reference call's two similar voices at every
> threshold (0.2–0.6) while the chunked one separates them (validated
> 407s/44s on the Aug 3 call, identical in debug and release). Threshold is
> `Float 0.6`; the dependency is pinned to revision `5390df9` (see the spec's
> phase-1 implementation finding). `fluidaudiocli process` defaults to the
> chunked/streaming pipeline — keep that in mind when cross-checking.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the placeholder energy-based diarizer with FluidAudio's offline CoreML pyannote pipeline so multi-person calls get real "Speaker 1/2/…" labels, with embeddings persisted and old meetings re-processable.

**Architecture:** `DiarizationEngine` keeps its public seam (`diarize(audioURL:)` called from `RecordingManager.postProcess`) but is reimplemented on `OfflineDiarizerManager`. Assignment gains a nearest-turn fallback, meetings persist per-speaker mean embeddings, and two small UI touchpoints are added (Settings model section, "Detect speakers" re-run in the meeting detail view).

**Tech Stack:** Swift 5.10 target / Swift 6.3 toolchain, SwiftPM, FluidAudio 0.15.5 (CoreML), SwiftData, SwiftUI.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-04-speaker-diarization-design.md` (phase 1 section).
- macOS deployment target 14.0 (both `Package.swift` and `project.yml`).
- FluidAudio pinned `exact: "0.15.5"`; models CC-BY-4.0 → visible attribution string required (Settings caption + README line).
- `clusteringThreshold` = **0.6** (library default 0.7 merged real call voices; validated 2026-08-04 on the Aug 3 recording).
- `make test` must stay offline — the model-download path is exercised only by the manual `--diarize-test` harness. (Deviation from the spec's "wire into make test": profile-test gains model-free logic checks instead; noted here deliberately.)
- Mic labels ("Me") are never touched by diarization.
- Never hand-edit `Parrot.xcodeproj` — edit `project.yml`, run `make xcode`.
- Build via `make` / `swift build`, not Xcode.

---

### Task 1: Add the FluidAudio dependency

**Files:**
- Modify: `Package.swift` (dependencies + target deps)
- Modify: `project.yml` (packages + target dependencies)

**Interfaces:**
- Consumes: nothing.
- Produces: `import FluidAudio` available to the Parrot target; types used later: `OfflineDiarizerConfig`, `OfflineDiarizerManager`, `OfflineDiarizerModels`, `TimedSpeakerSegment`.

- [ ] **Step 1: Package.swift** — in `dependencies` add, after the WhisperKit line:

```swift
.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5"),
```

and in the target's `dependencies` array add:

```swift
.product(name: "FluidAudio", package: "FluidAudio"),
```

- [ ] **Step 2: project.yml** — under `packages:` add:

```yaml
  FluidAudio:
    url: https://github.com/FluidInference/FluidAudio.git
    exactVersion: "0.15.5"
```

and under `targets.Parrot.dependencies` add:

```yaml
      - package: FluidAudio
        product: FluidAudio
```

- [ ] **Step 3: Regenerate + build**

Run: `make xcode && swift build 2>&1 | tail -3`
Expected: `Build complete!` (first run fetches FluidAudio + its NemoTextProcessing binary artifact — needs network).

- [ ] **Step 4: Commit** — `git add Package.swift Package.resolved project.yml Parrot.xcodeproj && git commit -m "Add FluidAudio 0.15.5 dependency"`

---

### Task 2: Reimplement DiarizationEngine on FluidAudio

**Files:**
- Rewrite: `Parrot/Services/DiarizationEngine.swift` (delete energy-based code, `windowEnergies`, `DiarizationError`, and the SpeakerKit comment block)

**Interfaces:**
- Consumes: FluidAudio offline API (Task 1).
- Produces (used by Tasks 3–5):
  - `DiarizationEngine.SpeakerSegmentResult { speakerLabel: String, startTime: TimeInterval, endTime: TimeInterval }` (unchanged shape)
  - `DiarizationEngine.Output { segments: [SpeakerSegmentResult], embeddings: [String: [Float]] }`
  - `func diarize(audioURL: URL) async throws -> Output`
  - `static var modelsInstalled: Bool`
  - `static func removeModels()`
  - `private(set) var isProcessing: Bool`, `private(set) var progress: Double` (kept)

- [ ] **Step 1: Write the new engine** — full file:

```swift
import Foundation
import FluidAudio

/// Post-meeting speaker diarization over the system-audio track, backed by
/// FluidAudio's offline pyannote pipeline (CoreML, fully on-device).
/// Models (~34 MB, CC-BY-4.0) auto-download to Application Support on first use.
@Observable
final class DiarizationEngine {
    private(set) var isProcessing = false
    private(set) var progress: Double = 0

    struct SpeakerSegmentResult {
        let speakerLabel: String
        let startTime: TimeInterval
        let endTime: TimeInterval
    }

    struct Output {
        let segments: [SpeakerSegmentResult]
        /// Mean voice embedding per speaker label — persisted on the meeting
        /// for voice profiles (phase 3).
        let embeddings: [String: [Float]]
    }

    /// The library default (0.7) merged two similar Turkish voices on a real
    /// call; 0.5–0.6 separated them. ponytail: the one calibration knob.
    static let clusteringThreshold = 0.6

    static var modelsInstalled: Bool {
        let dir = OfflineDiarizerModels.defaultModelsDirectory()
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return !items.isEmpty
    }

    static func removeModels() {
        try? FileManager.default.removeItem(at: OfflineDiarizerModels.defaultModelsDirectory())
    }

    /// Downloads models if missing (first run needs network); reports via
    /// `progress`. Callable from Settings to pre-fetch without diarizing.
    func ensureModels() async throws {
        _ = try await OfflineDiarizerModels.load()
    }

    func diarize(audioURL: URL) async throws -> Output {
        isProcessing = true
        progress = 0
        defer { isProcessing = false; progress = 1 }

        let config = OfflineDiarizerConfig(clusteringThreshold: Self.clusteringThreshold)
        let manager = OfflineDiarizerManager(config: config)
        let models = try await OfflineDiarizerModels.load()
        manager.initialize(models: models)
        progress = 0.2

        let result = try await manager.process(audioURL) { [weak self] done, total in
            guard total > 0 else { return }
            let frac = Double(done) / Double(total)
            Task { @MainActor in self?.progress = 0.2 + 0.75 * frac }
        }

        // Stable, human-meaningful labels: Speaker 1 = most speech.
        let bySpeaker = Dictionary(grouping: result.segments, by: \.speakerId)
        let ordered = bySpeaker.sorted { a, b in
            a.value.reduce(0) { $0 + $1.endTimeSeconds - $1.startTimeSeconds }
                > b.value.reduce(0) { $0 + $1.endTimeSeconds - $1.startTimeSeconds }
        }
        var labelFor: [String: String] = [:]
        for (index, entry) in ordered.enumerated() {
            labelFor[entry.key] = "Speaker \(index + 1)"
        }

        let segments = result.segments.map {
            SpeakerSegmentResult(
                speakerLabel: labelFor[$0.speakerId] ?? "Speaker ?",
                startTime: TimeInterval($0.startTimeSeconds),
                endTime: TimeInterval($0.endTimeSeconds))
        }

        var embeddings: [String: [Float]] = [:]
        for (id, segs) in bySpeaker {
            let vectors = segs.map(\.embedding).filter { !$0.isEmpty }
            guard let first = vectors.first, let label = labelFor[id] else { continue }
            var mean = [Float](repeating: 0, count: first.count)
            for vector in vectors {
                for i in 0..<min(mean.count, vector.count) { mean[i] += vector[i] }
            }
            for i in mean.indices { mean[i] /= Float(vectors.count) }
            embeddings[label] = mean
        }

        return Output(segments: segments, embeddings: embeddings)
    }
}
```

- [ ] **Step 2: Fix the one caller** — `RecordingManager.postProcess` still expects `[SpeakerSegmentResult]`; minimal interim patch so the project compiles (Task 3 rewrites it properly): change `let speakerSegments = try await diarizationEngine.diarize(audioURL: audioURL)` to `let speakerSegments = try await diarizationEngine.diarize(audioURL: audioURL).segments`.

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 4: Commit** — `git add -A Parrot && git commit -m "DiarizationEngine: real diarization via FluidAudio offline pipeline"`

---

### Task 3: Assignment fallback + embedding persistence (TDD)

**Files:**
- Modify: `Parrot/Services/RecordingManager.swift` (postProcess ~L608–649: new helper, remove `overlap(_:_:)`)
- Modify: `Parrot/Models/Meeting.swift` (new field)
- Test: `Parrot/ProfileTest.swift` (new `testDiarizedLabel()` registered in `run()`)

**Interfaces:**
- Consumes: `DiarizationEngine.Output` (Task 2).
- Produces: `RecordingManager.diarizedLabel(for:turns:) -> String?` (nonisolated static); `Meeting.speakerEmbeddingsData: Data?`.

- [ ] **Step 1: Write the failing checks** in ProfileTest (register `testDiarizedLabel()` in `run()`):

```swift
static func testDiarizedLabel() {
    typealias Turn = DiarizationEngine.SpeakerSegmentResult
    let turns = [
        Turn(speakerLabel: "Speaker 1", startTime: 0, endTime: 10),
        Turn(speakerLabel: "Speaker 2", startTime: 12, endTime: 20),
    ]
    check("max overlap wins",
          RecordingManager.diarizedLabel(for: (8, 14), turns: turns) == "Speaker 2")
    check("zero overlap falls back to nearest turn",
          RecordingManager.diarizedLabel(for: (10.5, 11.0), turns: turns) == "Speaker 1")
    check("after everything picks last turn",
          RecordingManager.diarizedLabel(for: (25, 26), turns: turns) == "Speaker 2")
    check("no turns gives nil",
          RecordingManager.diarizedLabel(for: (0, 1), turns: []) == nil)
}
```

(Overlap check math: segment 8–14 overlaps turn 1 by 2 s and turn 2 by 2 s — tie; make turn 2's overlap larger: use segment (9, 14): 1 s vs 2 s. Use `(9, 14)` in the final code.)

- [ ] **Step 2: Run to verify failure**

Run: `swift build && .build/debug/Parrot --profile-test 2>&1 | tail -3`
Expected: does not compile (`diarizedLabel` missing) — that's the failing state for a compiled language; proceed.

- [ ] **Step 3: Implement** in RecordingManager (replacing `overlap(_:_:)`):

```swift
/// Best speaker turn for a transcript segment: max time overlap, else the
/// nearest turn in time — every non-Me segment gets a label (no stray "Them").
nonisolated static func diarizedLabel(
    for segment: (start: TimeInterval, end: TimeInterval),
    turns: [DiarizationEngine.SpeakerSegmentResult]
) -> String? {
    var best: (label: String, overlap: TimeInterval)?
    var nearest: (label: String, gap: TimeInterval)?
    for turn in turns {
        let overlap = min(turn.endTime, segment.end) - max(turn.startTime, segment.start)
        if overlap > 0, overlap > (best?.overlap ?? 0) { best = (turn.speakerLabel, overlap) }
        let gap = max(turn.startTime - segment.end, segment.start - turn.endTime)
        if nearest == nil || gap < nearest!.gap { nearest = (turn.speakerLabel, gap) }
    }
    return best?.label ?? nearest?.label
}
```

and rewrite the body of `postProcess` after the guard to:

```swift
do {
    let audioURL = URL(fileURLWithPath: audioPath)
    let output = try await diarizationEngine.diarize(audioURL: audioURL)
    for transcriptSegment in meeting.segments where transcriptSegment.speakerLabel != "Me" {
        if let label = Self.diarizedLabel(
            for: (transcriptSegment.startTime, transcriptSegment.endTime),
            turns: output.segments) {
            transcriptSegment.speakerLabel = label
        }
    }
    meeting.speakerEmbeddingsData = try? JSONEncoder().encode(output.embeddings)
    try? modelContext?.save()
} catch {
    NSLog("Parrot: diarization failed — \(error.localizedDescription)")
    try? modelContext?.save()
}
```

- [ ] **Step 4: Meeting field** — after `aiUsageData` in Meeting.swift:

```swift
/// Mean voice embedding per speaker label (JSON [String: [Float]]), written
/// by diarization; feeds voice profiles later. Defaulted → old rows migrate.
var speakerEmbeddingsData: Data? = nil
```

- [ ] **Step 5: Run tests**

Run: `swift build && .build/debug/Parrot --profile-test 2>&1 | tail -3`
Expected: `ALL PASS` (117+ checks incl. the four new ones).

- [ ] **Step 6: Commit** — `git add -A Parrot && git commit -m "Diarization: nearest-turn fallback + per-speaker embeddings on Meeting"`

---

### Task 4: `--diarize-test` harness

**Files:**
- Modify: `Parrot/ParrotApp.swift` (flag parsing, mirror `--transcribe-test`)
- Modify: `Parrot/SnapshotTool.swift` (add `runDiarizeTest`)

**Interfaces:**
- Consumes: `DiarizationEngine.diarize` (Task 2).
- Produces: CLI `Parrot --diarize-test <audio-file>` printing per-speaker seconds; exit 0 when ≥1 speaker found, `DIARIZE OK` line when ≥2.

- [ ] **Step 1: ParrotApp.swift** — alongside the `--transcribe-test` branch:

```swift
if let i = args.firstIndex(of: "--diarize-test"), i + 1 < args.count {
    Task { await SnapshotTool.runDiarizeTest(audioPath: args[i + 1]) }
    RunLoop.main.run()
}
```

(Match the exact invocation style of the neighboring harness branches when editing.)

- [ ] **Step 2: SnapshotTool.swift** — add:

```swift
/// `--diarize-test <audio>`: run real diarization on a file, print clusters.
/// Downloads models on first use (network); not part of `make test`.
static func runDiarizeTest(audioPath: String) async {
    let engine = DiarizationEngine()
    do {
        let output = try await engine.diarize(audioURL: URL(fileURLWithPath: audioPath))
        var totals: [String: TimeInterval] = [:]
        for segment in output.segments {
            totals[segment.speakerLabel, default: 0] += segment.endTime - segment.startTime
        }
        for (label, seconds) in totals.sorted(by: { $0.value > $1.value }) {
            print("\(label): \(Int(seconds))s speech, embedding \(output.embeddings[label]?.count ?? 0) dims")
        }
        print(totals.count >= 2 ? "DIARIZE OK — \(totals.count) speakers" : "DIARIZE WEAK — \(totals.count) speaker(s)")
        exit(totals.isEmpty ? 1 : 0)
    } catch {
        print("DIARIZE FAIL: \(error)")
        exit(1)
    }
}
```

- [ ] **Step 3: Acceptance run** (two-voice synthetic fixture, no user data):

```bash
say -v Daniel -o /tmp/d1.aiff "The quarterly numbers look strong and I think we should expand the team next month."
say -v Samantha -o /tmp/d2.aiff "I disagree about the timing because the budget review is still pending until October."
say -v Daniel -o /tmp/d3.aiff "That is a fair point so let us revisit the plan after the review lands."
for f in d1 d2 d3; do afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/$f.aiff /tmp/$f.wav; done
sox /tmp/d1.wav /tmp/d2.wav /tmp/d3.wav /tmp/diarize-fixture.wav 2>/dev/null || \
  { cat /tmp/d1.wav > /tmp/diarize-fixture.wav; }   # sox absent → single-voice fallback, expect DIARIZE WEAK
.build/debug/Parrot --diarize-test /tmp/diarize-fixture.wav
```

Expected with sox: `DIARIZE OK — 2 speakers`. Then the real thing: `.build/debug/Parrot --diarize-test "$HOME/Library/Containers/com.uygar.parrot/Data/Library/Application Support/Parrot/Audio/system_2026-08-03T12-00-32Z.caf"` → `DIARIZE OK — 2 speakers`.

- [ ] **Step 4: Commit** — `git add -A Parrot && git commit -m "Harness: --diarize-test runs real diarization on an audio file"`

---

### Task 5: Re-run action + Settings section

**Files:**
- Modify: `Parrot/Services/RecordingManager.swift` (public `redetectSpeakers`)
- Modify: `Parrot/Views/MeetingDetailView.swift` (menu action in the transcript tab header area)
- Modify: `Parrot/Views/SettingsView.swift` (new `Section("Speaker Detection")` inside the Transcription section body)

**Interfaces:**
- Consumes: `postProcess` (Task 3), `DiarizationEngine.modelsInstalled/removeModels/ensureModels` (Task 2).
- Produces: `RecordingManager.redetectSpeakers(meeting: Meeting) async`.

- [ ] **Step 1: RecordingManager**:

```swift
/// Re-runs diarization on a finished meeting (audio is retained). Safe to
/// call repeatedly; refuses the meeting currently being recorded.
func redetectSpeakers(meeting: Meeting) async {
    guard !(isRecording && meeting.id == currentMeeting?.id) else { return }
    await postProcess(meeting: meeting)
}
```

- [ ] **Step 2: MeetingDetailView** — in the transcript tab controls, following the view's existing button style:

```swift
Button {
    Task { await recordingManager.redetectSpeakers(meeting: meeting) }
} label: {
    Label(recordingManager.diarizationEngine.isProcessing ? "Detecting…" : "Detect speakers",
          systemImage: "person.2.wave.2")
}
.disabled(recordingManager.diarizationEngine.isProcessing)
.help("Re-run on-device speaker detection for this meeting")
```

(Use the view's existing `@Environment(RecordingManager.self)`; add it if absent.)

- [ ] **Step 3: SettingsView** — inside the transcription section's Form, after `Section("On-Device Model")`:

```swift
Section("Speaker Detection") {
    if DiarizationEngine.modelsInstalled {
        LabeledContent("Models", value: "Downloaded (~34 MB)")
        Button("Remove Models") { DiarizationEngine.removeModels() }
    } else {
        LabeledContent("Models", value: "Not downloaded")
        Button(diarizerDownloading ? "Downloading…" : "Download (~34 MB)") {
            diarizerDownloading = true
            Task {
                try? await recordingManager.diarizationEngine.ensureModels()
                diarizerDownloading = false
            }
        }
        .disabled(diarizerDownloading)
    }
    Text("Tells apart the different people on the call, on this Mac. Uses pyannote models via FluidAudio (CC-BY-4.0). Downloads automatically after the first call if missing.")
        .font(Theme.Typography.caption)
        .foregroundStyle(Theme.Colors.ink2)
}
```

with `@State private var diarizerDownloading = false` — match the section's exact container (it may be a plain `Form`/custom layout; mirror `Section("On-Device Model")`'s structure and Theme usage).

- [ ] **Step 4: Build + snapshot sanity**

Run: `swift build && .build/debug/Parrot --profile-test 2>&1 | tail -2`
Expected: `ALL PASS`.

- [ ] **Step 5: Commit** — `git add -A Parrot && git commit -m "Speaker detection: re-run action + Settings model management"`

---

### Task 6: Validation sweep + docs

**Files:**
- Modify: `FILEMAP.md` (DiarizationEngine line), `README.md` (feature bullet + CC-BY-4.0 attribution line)

- [ ] **Step 1:** `make test` → `ALL PASS`; `make` → app assembles; note `dist/Parrot.app` size delta vs master (NemoTextProcessing xcframework gets linked — report the number).
- [ ] **Step 2:** `--diarize-test` on the synthetic fixture and the Aug 3 file (expected outputs in Task 4).
- [ ] **Step 3:** FILEMAP line for DiarizationEngine → "FluidAudio offline pyannote diarization (CoreML); labels + per-speaker embeddings". README: add speaker-detection bullet and "Speaker detection uses pyannote-derived models (CC-BY-4.0) via FluidAudio (Apache-2.0)."
- [ ] **Step 4:** Commit — `git add FILEMAP.md README.md && git commit -m "Docs: speaker detection notes + model attribution"`.

## Self-review notes

- Spec coverage: engine swap ✓ (T2), threshold 0.6 ✓ (T2), model download UX ✓ (T5, lazy download stays in `load()` on first diarize), assignment fallback ✓ (T3), embeddings persisted ✓ (T3), re-run action ✓ (T5), live view untouched ✓, soft-degrade kept ✓ (T3 catch), migration additive ✓ (T3). Deliberate deviations: model test not in `make test` (offline constraint); re-run action only in MeetingDetailView (spec also floated a sidebar context menu — YAGNI for v1).
- Type consistency: `Output`/`SpeakerSegmentResult`/`diarizedLabel(for:turns:)`/`speakerEmbeddingsData` names match across tasks.
- The `speakerCount`/`displayName` behavior needs no change: unnamed meetings will now show real "Speaker N" labels; meetings with `themName` set still collapse until phase 2 — intended.
