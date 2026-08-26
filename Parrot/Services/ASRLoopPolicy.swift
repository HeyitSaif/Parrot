import CoreML
import FluidAudio
import Foundation
import WhisperKit

enum PreviewMode: String, Sendable {
    case on, off, tail
}

enum ComputePlacement: String, Sendable {
    case ane, gpu, all

    var computeOptions: ModelComputeOptions {
        switch self {
        case .ane:
            return ModelComputeOptions(
                melCompute: .cpuOnly,
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            )
        case .gpu:
            return ModelComputeOptions(
                melCompute: .cpuOnly,
                audioEncoderCompute: .cpuAndGPU,
                textDecoderCompute: .cpuAndNeuralEngine
            )
        case .all:
            return ModelComputeOptions(
                melCompute: .cpuAndGPU,
                audioEncoderCompute: .cpuAndGPU,
                textDecoderCompute: .cpuAndNeuralEngine
            )
        }
    }
}

enum OnDeviceASRBackend: String, Sendable, CaseIterable {
    case whisper
    case parakeet
    case sensevoice
}

/// Session knobs for the live loop. Harnesses set `sessionOverride`;
/// production reads UserDefaults plus optional `LIVELOOP_*` env.
struct LoopSessionConfig: Sendable, Equatable {
    var language: String?
    var preview: PreviewMode
    var fallbackCount: Int
    var compute: ComputePlacement
    var streams: Int
    var backend: OnDeviceASRBackend
    var freezeLanguage: Bool
    var englishOnlyWeights: Bool

    static let defaultsKeyCompute = "asrComputePlacement"
    static let defaultsKeyBackend = "onDeviceASRBackend"

    static func fromEnvironmentAndDefaults() -> LoopSessionConfig {
        let env = ProcessInfo.processInfo.environment
        let langRaw = env["LIVELOOP_LANGUAGE"]
            ?? UserDefaults.standard.string(forKey: "transcriptionLanguage")
            ?? "auto"
        let language = (langRaw == "auto" || langRaw.isEmpty) ? nil : langRaw

        let preview: PreviewMode
        if let raw = env["LIVELOOP_PREVIEW"], let parsed = PreviewMode(rawValue: raw) {
            preview = parsed
        } else {
            let on = UserDefaults.standard.object(forKey: "livePreview") as? Bool ?? true
            preview = on ? .tail : .off
        }

        let fallback: Int
        if let raw = env["LIVELOOP_FALLBACK"], let n = Int(raw) {
            fallback = n
        } else {
            fallback = 1
        }

        let compute = ComputePlacement(
            rawValue: env["LIVELOOP_COMPUTE"]
                ?? UserDefaults.standard.string(forKey: defaultsKeyCompute)
                ?? ComputePlacement.ane.rawValue
        ) ?? .ane

        let streams = Int(env["LIVELOOP_STREAMS"] ?? "") ?? 1

        let backend = OnDeviceASRBackend(
            rawValue: env["LIVELOOP_BACKEND"]
                ?? UserDefaults.standard.string(forKey: defaultsKeyBackend)
                ?? OnDeviceASRBackend.whisper.rawValue
        ) ?? .whisper

        return LoopSessionConfig(
            language: language,
            preview: preview,
            fallbackCount: fallback,
            compute: compute,
            streams: max(1, min(streams, 2)),
            backend: backend,
            freezeLanguage: language == nil,
            englishOnlyWeights: language == "en"
        )
    }

    /// Parses `--asr-bench` specs: `preview=on,language=auto,fallback=3,compute=ane,backend=whisper`
    static func parseBenchSpec(_ spec: String) -> LoopSessionConfig {
        var cfg = fromEnvironmentAndDefaults()
        for part in spec.split(separator: ",") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespaces)
            let value = kv[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "preview":
                if let mode = PreviewMode(rawValue: value) { cfg.preview = mode }
            case "language":
                cfg.language = (value == "auto" || value.isEmpty) ? nil : value
                cfg.freezeLanguage = cfg.language == nil
                cfg.englishOnlyWeights = cfg.language == "en"
            case "fallback":
                if let n = Int(value) { cfg.fallbackCount = n }
            case "compute":
                if let c = ComputePlacement(rawValue: value) { cfg.compute = c }
            case "backend":
                if let b = OnDeviceASRBackend(rawValue: value) { cfg.backend = b }
            case "streams":
                if let n = Int(value) { cfg.streams = max(1, min(n, 2)) }
            case "freeze":
                cfg.freezeLanguage = value == "1" || value == "true"
            default:
                break
            }
        }
        return cfg
    }

    /// tiny/base/small → `.en` when the session is locked to English.
    static func resolvedWhisperModel(_ model: String, language: String?) -> String {
        guard language == "en" else { return model }
        switch model {
        case "tiny", "base", "small": return model + ".en"
        default: return model
        }
    }
}

/// Pure decode-loop policy. `--profile-test` drives these without a model.
enum ASRLoopPolicy {
    static let sampleRate = 16_000
    static let tailPreviewSamples = sampleRate * 3
    static let maxDecodeSamples = sampleRate * 15
    static let minDrainSamples = sampleRate / 5

    static func previewSamples(_ pending: [Float], mode: PreviewMode) -> [Float] {
        switch mode {
        case .off: return []
        case .on: return applyDecodeWindowCap(pending)
        case .tail:
            if pending.count <= tailPreviewSamples { return applyDecodeWindowCap(pending) }
            return applyDecodeWindowCap(Array(pending.suffix(tailPreviewSamples)))
        }
    }

    static func shouldPreview(
        mode: PreviewMode,
        commitInFlight: Bool,
        pendingCount: Int,
        now: Date,
        nextAt: Date,
        otherCommitReady: Bool = false
    ) -> Bool {
        guard mode != .off else { return false }
        guard !commitInFlight else { return false }
        guard !otherCommitReady else { return false }
        guard pendingCount >= TranscriptionEngine.Segmenter.minSpeechSamples else { return false }
        return now >= nextAt
    }

    static func applyDecodeWindowCap(_ samples: [Float]) -> [Float] {
        if samples.count <= maxDecodeSamples { return samples }
        return Array(samples.suffix(maxDecodeSamples))
    }

    static func shouldDropDrainTail(_ sampleCount: Int, draining: Bool) -> Bool {
        draining && sampleCount > 0 && sampleCount < minDrainSamples
    }

    /// After the first confident detect, later options must not re-run language detection.
    static func applyingLanguageFreeze(
        _ options: DecodingOptions,
        frozen: String?
    ) -> DecodingOptions {
        var next = options
        if let frozen, !frozen.isEmpty {
            next.language = frozen
            next.detectLanguage = false
        }
        return next
    }

    static func previewOptions(_ options: DecodingOptions) -> DecodingOptions {
        var next = options
        next.detectLanguage = false
        return next
    }

    /// Energy passed the segmenter but the decode returned empty — wasted ANE time.
    static func isWastedDecode(energyPassed: Bool, text: String) -> Bool {
        energyPassed && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Picks a streaming backend by language. FluidAudio ASR is not on the
/// current diarization pin — the engine falls back to Whisper when
/// `FluidStreamingASR.isAvailable` is false.
enum ASRLanguageRouter {
    static func backend(for language: String?) -> OnDeviceASRBackend {
        switch language {
        case "en", "es", "fr", "de", "it", "pt": return .parakeet
        case "zh", "tr", "ar", "hi", "ja", "ko": return .sensevoice
        default: return .whisper
        }
    }

    static func resolved(requested: OnDeviceASRBackend, language: String?) -> OnDeviceASRBackend {
        if requested != .whisper { return requested }
        return backend(for: language)
    }
}

/// FluidAudio on this pin already ships `AsrManager` / streaming types, but we
/// do not load those weights until `--asr-bench` beats Whisper on a real file.
/// `isAvailable` stays false so the live loop never downloads a second stack.
enum FluidStreamingASR {
    static var isAvailable: Bool { false }

    static func fallbackNotice(for backend: OnDeviceASRBackend) -> String? {
        guard backend != .whisper, !isAvailable else { return nil }
        return "ANE streaming (\(backend.rawValue)) is gated until a bench win — using Whisper"
    }

    /// Type-check against the pinned FluidAudio ASR API. Not invoked at runtime
    /// while `isAvailable` is false.
    static func makeManager() -> AsrManager {
        AsrManager()
    }
}

/// FluidAudio CTC keyword boost — same gate as streaming ASR. Today's glossary
/// prompt already has a `--liveloop-test` + `LIVELOOP_VOCAB` retry path; flip
/// this only if `glossary_retries` stays high after a bench against the prompt.
enum FluidVocabBoost {
    static var isAvailable: Bool { false }
}
