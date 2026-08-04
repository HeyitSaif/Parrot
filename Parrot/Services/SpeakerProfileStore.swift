import Foundation
import SwiftData

/// Matching and upkeep for remembered voices. Stateless — every call takes
/// the ModelContext — so views and harnesses use it without wiring.
/// Suggestion-only by design: nothing here writes a speaker name; the user
/// confirms in the naming popover (confirm-first rule in the design spec).
enum SpeakerProfileStore {
    /// Cosine similarity floor for "sounds like X" suggestions. Calibrated on
    /// the real Aug 3 call (split-half): same voice across independent halves
    /// = 0.96, different voices = 0.50–0.53 — our per-meeting MEAN embeddings
    /// score far higher than the generic 0.5–0.6 research band, so 0.7 keeps
    /// a ±0.2 margin against both false matches and misses.
    // ponytail: single knob, used only by match(_:in:).
    static let suggestThreshold: Float = 0.7

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    static func profiles(in context: ModelContext) -> [SpeakerProfile] {
        (try? context.fetch(FetchDescriptor<SpeakerProfile>(sortBy: [SortDescriptor(\.name)]))) ?? []
    }

    /// Best remembered voice at/above the threshold, or nil.
    static func match(_ embedding: [Float], in context: ModelContext) -> (name: String, similarity: Float)? {
        let best = profiles(in: context)
            .map { (name: $0.name, similarity: cosine(embedding, $0.embedding)) }
            .max { $0.similarity < $1.similarity }
        guard let best, best.similarity >= suggestThreshold else { return nil }
        return best
    }

    /// Create or reinforce the profile named `name` with one more voice sample.
    static func remember(name: String, embedding: [Float], in context: ModelContext) {
        guard !embedding.isEmpty else { return }
        if let existing = profiles(in: context).first(where: { $0.name == name }) {
            let n = Float(existing.sampleCount)
            let old = existing.embedding
            guard old.count == embedding.count else { return }
            existing.embedding = old.indices.map { (old[$0] * n + embedding[$0]) / (n + 1) }
            existing.sampleCount += 1
            existing.updatedAt = .now
        } else {
            context.insert(SpeakerProfile(name: name, embedding: embedding))
        }
        try? context.save()
    }

    static func delete(_ profile: SpeakerProfile, in context: ModelContext) {
        context.delete(profile)
        try? context.save()
    }

    static func deleteAll(in context: ModelContext) {
        for profile in profiles(in: context) { context.delete(profile) }
        try? context.save()
    }
}
