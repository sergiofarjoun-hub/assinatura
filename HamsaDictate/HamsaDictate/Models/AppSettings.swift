import Foundation

enum TranscriptionLanguage: String, CaseIterable, Identifiable {
    case portuguese = "pt"
    case english = "en"
    case auto = "auto"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .portuguese: return "Português"
        case .english: return "English"
        case .auto: return "Detectar automaticamente"
        }
    }

    /// Código passado ao Whisper; `nil` ativa a detecção automática de idioma.
    var whisperCode: String? {
        self == .auto ? nil : rawValue
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // No repositório argmaxinc/whisperkit-coreml, "large-v3-v20240930" É o
    // large-v3-turbo da OpenAI (nomeado pela data de lançamento).
    static let defaultModelVariant = "openai_whisper-large-v3-v20240930"

    @Published var language: String {
        didSet { UserDefaults.standard.set(language, forKey: "language") }
    }

    @Published var modelVariant: String {
        didSet { UserDefaults.standard.set(modelVariant, forKey: "modelVariant") }
    }

    /// Limite de gravação para evitar hotkey preso (segundos).
    let maxRecordingSeconds: TimeInterval = 120

    private init() {
        language = UserDefaults.standard.string(forKey: "language") ?? TranscriptionLanguage.portuguese.rawValue
        modelVariant = UserDefaults.standard.string(forKey: "modelVariant") ?? Self.defaultModelVariant
    }
}
