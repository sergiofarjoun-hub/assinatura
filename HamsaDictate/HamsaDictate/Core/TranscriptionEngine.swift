import Foundation
import WhisperKit

enum EnginePreparationPhase: Sendable {
    /// Baixando o modelo do Hugging Face (fração 0…1).
    case downloading(Double)
    /// Carregando/pré-aquecendo o modelo em memória (Neural Engine).
    case loading
}

enum TranscriptionError: LocalizedError {
    case engineNotReady

    var errorDescription: String? {
        switch self {
        case .engineNotReady:
            return "O modelo de transcrição ainda não está carregado."
        }
    }
}

protocol TranscriptionEngine: AnyObject {
    var isReady: Bool { get }
    /// Baixa (se necessário) e carrega o modelo. Idempotente.
    func prepare(onPhaseChange: @escaping @Sendable (EnginePreparationPhase) -> Void) async throws
    /// Transcreve amostras 16 kHz mono Float32. `language` nil = auto-detect.
    func transcribe(samples: [Float], language: String?) async throws -> String
}

/// Engine baseada no WhisperKit (Argmax OSS SDK ≥ 1.0).
final class WhisperKitEngine: TranscriptionEngine {
    private let variant: String
    private var whisperKit: WhisperKit?

    init(variant: String) {
        self.variant = variant
    }

    var isReady: Bool { whisperKit != nil }

    func prepare(onPhaseChange: @escaping @Sendable (EnginePreparationPhase) -> Void) async throws {
        guard whisperKit == nil else { return }

        onPhaseChange(.downloading(0))
        // Já baixado? O hub só baixa o que falta; a Progress reflete isso.
        let modelFolder = try await WhisperKit.download(variant: variant) { progress in
            onPhaseChange(.downloading(progress.fractionCompleted))
        }

        onPhaseChange(.loading)
        let config = WhisperKitConfig(
            model: variant,
            modelFolder: modelFolder.path,
            prewarm: true,
            load: true,
            download: false
        )
        whisperKit = try await WhisperKit(config)
    }

    func transcribe(samples: [Float], language: String?) async throws -> String {
        guard let whisperKit else { throw TranscriptionError.engineNotReady }

        var options = DecodingOptions()
        options.task = .transcribe
        options.language = language
        options.temperature = 0
        options.skipSpecialTokens = true

        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        let rawText = results.map(\.text).joined(separator: " ")
        return Self.postProcess(rawText)
    }

    /// Limpeza mínima: trim, colapsa espaços e capitaliza a primeira letra.
    static func postProcess(_ text: String) -> String {
        var cleaned = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = cleaned.first, first.isLowercase {
            cleaned = first.uppercased() + cleaned.dropFirst()
        }
        return cleaned
    }
}
