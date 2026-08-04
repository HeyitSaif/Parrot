# Voice Profiles Phase 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Opt-in "Remember voices": naming a speaker saves a local voiceprint, and future meetings suggest "Sounds like Gürkan — confirm?" for matching voices. Suggestion-only per the spec's confirm-first rule; no silent auto-apply.

**Architecture:** One new `@Model` (`SpeakerProfile`: name + running-mean 256-dim embedding) and one small UI-agnostic service (`SpeakerProfileStore`: cosine match, upsert, delete). Suggestions are computed lazily from `Meeting.speakerEmbeddings` against stored profiles at render time — nothing new persisted on meetings. Profiles are only written from the naming popover when the setting is on.

**Tech Stack:** SwiftData, SwiftUI, Accelerate-free plain-Swift cosine (256 floats — no need).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-04-speaker-diarization-design.md` phase 3 + confirm-first amendment: **first release SUGGESTS only** ("Sounds like X — confirm?" with clip); silent auto-apply is a later, earned upgrade.
- **Biometric data ⇒ default OFF**, explicit toggle, local-only, fully deletable (per-person and all).
- Suggestion threshold: cosine ≥ **0.55** on the WeSpeaker mean embeddings (research band 0.5–0.6; constant in one place, calibrate on real recordings).
- All schema changes additive; `SpeakerProfile` joins every `Schema([...])` site (ParrotApp:93, SnapshotTool:95+643, ProfileTest:107+138+541 — grep before editing, phase-2 merge may have shifted lines).
- No profile writes anywhere except the naming popover path while the toggle is on.
- The "Me" mic-embedding enrollment from the spec is deferred (imports-only payoff — YAGNI for v1; note the deviation).

---

### Task 1: model + store (TDD)

**Files:**
- Create: `Parrot/Models/SpeakerProfile.swift`
- Create: `Parrot/Services/SpeakerProfileStore.swift`
- Modify: `Parrot/Models/Meeting.swift` (read accessor), the six `Schema([...])` sites
- Test: `Parrot/ProfileTest.swift` (`testVoiceProfiles()` registered after `testSpeakerNames()`)

**Interfaces (produced):**

```swift
@Model final class SpeakerProfile {
    var id: UUID
    var name: String
    var embeddingData: Data      // JSON [Float], running mean
    var sampleCount: Int
    var updatedAt: Date
    var embedding: [Float] { get set }   // JSON accessors
    init(name: String, embedding: [Float])
}

enum SpeakerProfileStore {   // stateless: context passed in; UI-agnostic
    static let suggestThreshold: Float = 0.55
    static func cosine(_ a: [Float], _ b: [Float]) -> Float
    static func profiles(in context: ModelContext) -> [SpeakerProfile]
    /// Best profile at/above threshold for this voice, or nil.
    static func match(_ embedding: [Float], in context: ModelContext) -> (name: String, similarity: Float)?
    /// Create or reinforce (running mean + sampleCount) the profile named `name`.
    static func remember(name: String, embedding: [Float], in context: ModelContext)
    static func delete(_ profile: SpeakerProfile, in context: ModelContext)
    static func deleteAll(in context: ModelContext)
}

// Meeting:
var speakerEmbeddings: [String: [Float]] { get }   // decodes speakerEmbeddingsData
```

- [ ] **Step 1: failing checks** (in-memory container including `SpeakerProfile.self`):

```swift
@MainActor
static func testVoiceProfiles() {
    let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self, CallProfile.self, SpeakerProfile.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    guard let container = try? ModelContainer(for: schema, configurations: [config]) else {
        check("voice-profiles container builds", false); return
    }
    let ctx = ModelContext(container)
    let a: [Float] = [1, 0, 0], b: [Float] = [0, 1, 0]
    check("cosine identical", abs(SpeakerProfileStore.cosine(a, a) - 1) < 0.001)
    check("cosine orthogonal", abs(SpeakerProfileStore.cosine(a, b)) < 0.001)
    check("no profiles no match", SpeakerProfileStore.match(a, in: ctx) == nil)
    SpeakerProfileStore.remember(name: "Gürkan", embedding: [1, 0, 0], in: ctx)
    check("match after remember", SpeakerProfileStore.match([0.9, 0.1, 0], in: ctx)?.name == "Gürkan")
    check("below threshold no match", SpeakerProfileStore.match([0, 0, 1], in: ctx) == nil)
    SpeakerProfileStore.remember(name: "Gürkan", embedding: [0, 1, 0], in: ctx)
    let p = SpeakerProfileStore.profiles(in: ctx).first
    check("running mean", p.map { abs($0.embedding[0] - 0.5) < 0.001 && abs($0.embedding[1] - 0.5) < 0.001 } ?? false)
    check("sample count grows", p?.sampleCount == 2)
    SpeakerProfileStore.deleteAll(in: ctx)
    check("deleteAll empties", SpeakerProfileStore.profiles(in: ctx).isEmpty)
}
```

- [ ] **Step 2:** build → fails (types missing).
- [ ] **Step 3:** implement model + store exactly per the interfaces (cosine: dot / (norm·norm), guard zero norms and mismatched counts → 0; `remember` matches by exact name, running mean `(old·n + new)/(n+1)`; `match` = max cosine ≥ threshold). Add `Meeting.speakerEmbeddings` getter decoding `speakerEmbeddingsData`. Register `SpeakerProfile.self` at all six schema sites.
- [ ] **Step 4:** build + `--profile-test` → ALL PASS.
- [ ] **Step 5:** commit "Voice profiles: SpeakerProfile model + matching store".

---

### Task 2: remember on naming + suggest in the UI

**Files:**
- Modify: `Parrot/Views/MeetingDetailView.swift` (`SpeakerNamePopover`, `nameVoicesCard`)

**Interfaces:**
- Consumes Task 1; `@AppStorage("rememberVoices") = false`; `@Environment(\.modelContext)`.

- [ ] **Step 1: popover** — add `@AppStorage("rememberVoices") private var rememberVoices = false`, `@Environment(\.modelContext) private var modelContext`. In `onSubmit`, after writing `speakerNames`: 

```swift
if rememberVoices, let trimmedName = name.trimmingCharacters(in: .whitespaces).nilIfEmpty,
   let embedding = meeting.speakerEmbeddings[label] {
    SpeakerProfileStore.remember(name: trimmedName, embedding: embedding, in: modelContext)
}
```

- [ ] **Step 2: popover suggestion** — above the TextField, when `rememberVoices`, the label is unnamed, and `meeting.speakerEmbeddings[label]` matches a profile:

```swift
if let match {
    Button {
        var names = meeting.speakerNames
        names[label] = match.name
        meeting.speakerNames = names
        SpeakerProfileStore.remember(name: match.name, embedding: meeting.speakerEmbeddings[label] ?? [], in: modelContext)
        dismiss()
    } label: {
        Label("Sounds like \(match.name) — confirm", systemImage: "person.crop.circle.badge.checkmark")
    }
}
```

(compute `match` once in a private helper; confirming also reinforces the profile).
- [ ] **Step 3: card rows** — after the label text, when remembering is on and a match exists: `Text("· sounds like \(match.name)?")` in `Theme.Colors.accent`.
- [ ] **Step 4:** build + profile-test; commit "Naming remembers voices (opt-in) and suggests known ones".

---

### Task 3: Settings management

**Files:**
- Modify: `Parrot/Views/SettingsView.swift` (Speaker Detection section)

- [ ] **Step 1:** in `Section("Speaker Detection")` add:

```swift
Toggle("Remember voices", isOn: $rememberVoices)
Text("When on, naming a speaker saves their voiceprint on this Mac so future calls can suggest who's talking. Never leaves your Mac; delete anytime.")
    .font(Theme.Typography.caption)
    .foregroundStyle(Theme.Colors.ink2)
if rememberVoices, !profiles.isEmpty {
    ForEach(profiles) { profile in
        HStack {
            Text(profile.name)
            Text("heard \(profile.sampleCount)×").foregroundStyle(Theme.Colors.ink2)
            Spacer()
            Button("Forget") { SpeakerProfileStore.delete(profile, in: modelContext) }
        }
        .font(Theme.Typography.caption)
    }
    Button("Forget All Voices") { SpeakerProfileStore.deleteAll(in: modelContext) }
}
```

with `@AppStorage("rememberVoices") private var rememberVoices = false`, `@Environment(\.modelContext) private var modelContext`, and `@Query(sort: \SpeakerProfile.name) private var profiles: [SpeakerProfile]`.
- [ ] **Step 2:** build + profile-test; commit "Settings: remember-voices toggle + stored voice management".

---

### Task 4: validate, docs, PR

- [ ] **Step 1:** `make test` → ALL PASS; `make` assembles; relaunch dist.
- [ ] **Step 2:** live check: enable Remember voices; on the Aug 3 meeting name a speaker (creates profile, visible in Settings with "heard 1×"); run "Detect speakers" on another multi-person meeting from the same group (e.g., Aug 1 11:36 pm) and confirm the popover/card shows "Sounds like …?" — or, if the similarity lands below threshold on that pair, record the measured value in the plan and tune later with real data.
- [ ] **Step 3:** FILEMAP additions (2 new files); spec phase-3 "implemented" note incl. deferred Me-enrollment.
- [ ] **Step 4:** push `claude/voice-profiles-phase3`, PR base master.

## Self-review notes

- Spec coverage: opt-in default-off ✓, local-only + deletable ✓ (T3), suggest-with-clip-confirm not auto-apply ✓ (T2 popover has the clips right above), reinforcement on confirm/correction ✓ (remember on every submit), `initializeKnownSpeakers` pipeline seeding NOT used (suggestion layer sits above diarization — simpler, pipeline stays name-blind; deviation noted), Me-enrollment deferred (noted), LLM-attribution assist deferred (spec called it optional).
- Threshold 0.55 lives only in `SpeakerProfileStore.suggestThreshold`.
- Popover computes match lazily — no stored suggestions to go stale after re-detection.
