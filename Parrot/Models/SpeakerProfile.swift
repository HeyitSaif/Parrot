import Foundation
import SwiftData

/// A remembered voice: a name plus the running mean of that person's
/// diarization embeddings. Biometric data — created only while the opt-in
/// "Remember voices" setting is on, stored locally, deletable in Settings.
@Model
final class SpeakerProfile {
    var id: UUID
    var name: String
    /// JSON-encoded [Float] (256 dims from the diarizer), running mean.
    var embeddingData: Data
    var sampleCount: Int
    var updatedAt: Date

    var embedding: [Float] {
        get { (try? JSONDecoder().decode([Float].self, from: embeddingData)) ?? [] }
        set { embeddingData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    init(name: String, embedding: [Float]) {
        self.id = UUID()
        self.name = name
        self.embeddingData = (try? JSONEncoder().encode(embedding)) ?? Data()
        self.sampleCount = 1
        self.updatedAt = .now
    }
}
