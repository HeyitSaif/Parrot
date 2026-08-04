# Speaker Naming Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users name each detected voice — click a speaker chip (or the post-call confirm card), listen to short clips of that voice, type a name — and have names flow into transcript, reports, and prompts.

**Architecture:** Additive `speakerNamesData` on `Meeting` with a precedence rule in `displayName(forSpeaker:)`; `TranscriptSegmentRow`'s existing label becomes a chip that opens a naming popover; clips reuse the detail view's existing synced players via a `playClip` closure; a one-time confirm card lists unnamed voices (spec's confirm-first rule). No new services.

**Tech Stack:** SwiftUI, SwiftData (additive fields only), existing AVAudioPlayer pair.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-04-speaker-diarization-design.md` (phase 2 + confirm-first principle).
- Confirm-first: auto-detection never asserts identity; naming happens after listening. Dismissed card leaves neutral "Speaker N".
- All SwiftData changes additive with defaults (lightweight migration, like `speakerEmbeddingsData`).
- Legacy `themName` keeps working for old meetings until any per-speaker name is set; never delete the field.
- UI text short plain English; colors only via Theme/`speakerColors`; no new hex outside the existing palette.
- Base branch: `claude/speaker-naming-phase2` stacked on the phase-1 branch (PR targets it until #40 merges).

---

### Task 1: Meeting model — names, precedence, helpers (TDD)

**Files:**
- Modify: `Parrot/Models/Meeting.swift`
- Test: `Parrot/ProfileTest.swift` (new `testSpeakerNames()` registered in `run()` after `testDiarizedLabel()`)

**Interfaces (produced):**
- `var speakerNamesData: Data? = nil` (stored), `var speakerNames: [String: String]` (computed get/set, JSON)
- `var speakerPromptDismissed: Bool = false` (stored)
- `func displayName(forSpeaker label: String?) -> String` — new precedence:
  1. `speakerNames[label]` if present
  2. `"Me"` for "Me"
  3. if `speakerNames` is empty: `themName ?? label` (legacy behavior)
  4. else `label` (once the user starts naming, no more collective fallback)
- `var otherSpeakerLabels: [String]` — distinct non-Me labels, "Speaker 1" first (sorted naturally)
- `func longestSegments(for label: String, count: Int = 3) -> [TranscriptSegment]` — that voice's longest segments, for clips
- `var participantsSummary: String?` — named speakers joined with ", "; nil when none named (callers fall back to `themName`)

- [ ] **Step 1: failing checks** in ProfileTest (in-memory container like `testMigration`):

```swift
@MainActor
static func testSpeakerNames() {
    let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self, CallProfile.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    guard let container = try? ModelContainer(for: schema, configurations: [config]) else {
        check("speaker-names container builds", false); return
    }
    let ctx = ModelContext(container)
    let m = Meeting(title: "t")
    ctx.insert(m)
    for (start, dur, label) in [(0.0, 5.0, "Speaker 1"), (10.0, 2.0, "Speaker 2"),
                                (20.0, 9.0, "Speaker 1"), (30.0, 1.0, "Me")] {
        let s = TranscriptSegment(startTime: start, endTime: start + dur, text: "x", speakerLabel: label)
        ctx.insert(s); s.meeting = m
    }
    m.themName = "The Others"
    check("legacy fallback intact", m.displayName(forSpeaker: "Speaker 1") == "The Others")
    m.speakerNames = ["Speaker 1": "Gürkan"]
    check("named label resolves", m.displayName(forSpeaker: "Speaker 1") == "Gürkan")
    check("unnamed label stays raw once naming started", m.displayName(forSpeaker: "Speaker 2") == "Speaker 2")
    check("me is me", m.displayName(forSpeaker: "Me") == "Me")
    check("names roundtrip via data", Meeting(title: "u").speakerNames.isEmpty)
    check("other labels ordered", m.otherSpeakerLabels == ["Speaker 1", "Speaker 2"])
    check("longest segments sorted", m.longestSegments(for: "Speaker 1").map(\.startTime) == [20.0, 0.0])
    check("participants summary", m.participantsSummary == "Gürkan")
}
```

- [ ] **Step 2:** build + run → fails (members missing).
- [ ] **Step 3:** implement on Meeting:

```swift
/// Per-speaker display names (JSON [label: name]); set from the naming UI.
/// Defaulted → old rows migrate.
var speakerNamesData: Data? = nil
/// One-time "name the voices" card dismissed. Defaulted → old rows migrate.
var speakerPromptDismissed: Bool = false

var speakerNames: [String: String] {
    get {
        guard let data = speakerNamesData else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
    set { speakerNamesData = try? JSONEncoder().encode(newValue) }
}

var otherSpeakerLabels: [String] {
    Set(segments.compactMap(\.speakerLabel)).subtracting(["Me"])
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
}

func longestSegments(for label: String, count: Int = 3) -> [TranscriptSegment] {
    segments.filter { $0.speakerLabel == label }
        .sorted { ($0.endTime - $0.startTime) > ($1.endTime - $1.startTime) }
        .prefix(count).map { $0 }
}

var participantsSummary: String? {
    let named = otherSpeakerLabels.compactMap { speakerNames[$0] }
    return named.isEmpty ? nil : named.joined(separator: ", ")
}
```

and replace `displayName(forSpeaker:)` body with the precedence above (keep the doc comment, updated).

- [ ] **Step 4:** build + `--profile-test` → ALL PASS.
- [ ] **Step 5:** commit "Meeting: per-speaker names with legacy themName fallback".

---

### Task 2: chips, naming popover, per-line reassign

**Files:**
- Modify: `Parrot/Views/MeetingDetailView.swift` (`transcriptList`, `TranscriptSegmentRow` ~L594, new `SpeakerNamePopover` view, clip playback helper)

**Interfaces:**
- Consumes Task 1 helpers.
- Produces: `playClip(start: TimeInterval, end: TimeInterval)` on MeetingDetailView (reuses `seekTo` + synced players + auto-stop `Task`); `SpeakerNamePopover(meeting:label:playClip:)`.

- [ ] **Step 1:** `TranscriptSegmentRow` gains `let meeting: Meeting`, `var onNameTap: (() -> Void)?`, `var onReassign: ((String) -> Void)?`; `displayLabel` uses `meeting.displayName(forSpeaker:)`; the label `Text` becomes a `Button` (plain style, same font/color) calling `onNameTap`, skipped for "Me". Row gets `.contextMenu` with a "Speaker" submenu: "Me" + each `otherSpeakerLabels` shown via displayName → `onReassign(label)`.
- [ ] **Step 2:** in `transcriptList`, hold `@State private var namingLabel: String?`; rows: `onNameTap = { namingLabel = segment.speakerLabel }`, `onReassign = { segment.speakerLabel = $0; try? modelContext.save() }` (row is non-Me only for the menu). Popover: `.popover(item:)` needs Identifiable — wrap label in a small `struct NamingTarget: Identifiable { let label: String; var id: String { label } }`.
- [ ] **Step 3:** `SpeakerNamePopover`: header "Who is this?" + caption; up to 3 clip rows (`meeting.longestSegments(for: label)`) each "▶ \(formattedTimestamp) · \(Int(dur))s" buttons calling `playClip(start, min(end, start + 8))`; `TextField("Type a name", ...)` seeded with current `speakerNames[label]`, onSubmit writes `meeting.speakerNames[label] = trimmed.nilIfEmpty` (delete key on empty), saves, dismisses. Footer caption: "Renames every line from this voice."
- [ ] **Step 4:** clip playback on MeetingDetailView:

```swift
@State private var clipStopTask: Task<Void, Never>?
private func playClip(start: TimeInterval, end: TimeInterval) {
    clipStopTask?.cancel()
    seekTo(start)
    if !isPlaying { togglePlayback() }
    clipStopTask = Task {
        try? await Task.sleep(for: .seconds(end - start))
        guard !Task.isCancelled else { return }
        if isPlaying { togglePlayback() }
    }
}
```

- [ ] **Step 5:** build + profile-test → ALL PASS; commit "Naming popover: hear the voice, type the name".

---

### Task 3: post-call confirm card

**Files:**
- Modify: `Parrot/Views/MeetingDetailView.swift` (`transcriptTab`)

- [ ] **Step 1:** above `transcriptList` (below the Detect button row), when `meeting.status == .done && meeting.otherSpeakerLabels.count >= 2 && meeting.speakerNames.isEmpty && !meeting.speakerPromptDismissed`: a card (Theme panel background, `Theme.Metrics` padding) titled "Heard \(n) people besides you — listen and name them", one row per label: color dot (row palette), display label, ▶ button playing the longest clip, "Name" button opening the same popover (set `namingLabel`). Top-right X sets `speakerPromptDismissed = true` + save.
- [ ] **Step 2:** build; commit "Confirm card: name the detected voices after the call".

---

### Task 4: names in prompts and lists

**Files:**
- Modify: `Parrot/Services/RecordingManager.swift` (~L481), `Parrot/Views/DashboardView.swift` (~L324), `Parrot/Views/SidebarView.swift` (themName usages, if any)

- [ ] **Step 1:** RecordingManager transcript-for-prompt line → `meeting.displayName(forSpeaker: $0.speakerLabel)`:

```swift
.map { "[\($0.formattedTimestamp)] \(meeting.displayName(forSpeaker: $0.speakerLabel)): \($0.text)" }
```

(confirm the closure has `meeting` in scope; it's built from `meeting.segments` in `generateSummary`).
- [ ] **Step 2:** DashboardView/SidebarView subtitle: `meeting.participantsSummary ?? meeting.themName` where `themName` is shown today.
- [ ] **Step 3:** build + profile-test; commit "Reports and lists use per-speaker names".

---

### Task 5: validate end-to-end, push, stacked PR

- [ ] **Step 1:** `make test` → ALL PASS; `make` assembles.
- [ ] **Step 2:** relaunch `dist/Parrot.app`, open the Aug 3 meeting: confirm card lists Speaker 1/2 with clips; play a clip; name Speaker 2; verify every Speaker 2 line renames and the header/sidebar update. Screenshot.
- [ ] **Step 3:** update FILEMAP line counts touched; spec phase-2 section gets an "implemented" note with any deviations.
- [ ] **Step 4:** push `claude/speaker-naming-phase2`; `gh pr create --base claude/speaker-diarization-research-c8405e` (stacked; retargets to master when #40 merges).

## Self-review notes

- Spec coverage: per-speaker names ✓ (T1), chips + popover with clips ✓ (T2), confirm-first card ✓ (T3), merge-by-same-name ✓ (free via displayName), per-line reassign ✓ (T2 context menu), names in reports/prompts ✓ (T4), `speakerCount` ✓ (already displayName-based). Deviations: single "themName seeds largest cluster" migration replaced by the simpler precedence rule (legacy fallback until first name); header keeps the legacy themName field for now (removal deferred — old meetings still rely on it; revisit after release feedback).
- Colors: reuse `TranscriptSegmentRow.speakerColors` — no new palette.
- Popover uses `.popover(item:)` with an Identifiable wrapper — plain String is not Identifiable.
