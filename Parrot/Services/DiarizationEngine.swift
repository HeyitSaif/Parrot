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
    /// call; 0.5–0.6 separated them. ponytail: the one calibration knob —
    /// re-validate with scripts/dev/diarization-compare.py when bumping the
    /// FluidAudio pin.
    static let clusteringThreshold = 0.6

    static var modelsInstalled: Bool {
        let dir = OfflineDiarizerModels.defaultModelsDirectory()
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return !items.isEmpty
    }

    static func removeModels() {
        try? FileManager.default.removeItem(at: OfflineDiarizerModels.defaultModelsDirectory())
    }

    /// Downloads models if missing (first run needs network). Lets Settings
    /// pre-fetch without running a diarization.
    func ensureModels() async throws {
        isProcessing = true
        defer { isProcessing = false }
        _ = try await OfflineDiarizerModels.load()
    }

    func diarize(audioURL: URL) async throws -> Output {
        isProcessing = true
        progress = 0
        defer {
            isProcessing = false
            progress = 1.0
        }

        let config = OfflineDiarizerConfig(clusteringThreshold: Self.clusteringThreshold)
        let manager = OfflineDiarizerManager(config: config)
        let models = try await OfflineDiarizerModels.load()
        manager.initialize(models: models)
        progress = 0.2

        let result = try await manager.process(audioURL) { [weak self] done, total in
            guard total > 0 else { return }
            let fraction = Double(done) / Double(total)
            Task { @MainActor in self?.progress = 0.2 + 0.75 * fraction }
        }

        // Stable, human-meaningful labels: Speaker 1 talked the most.
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
