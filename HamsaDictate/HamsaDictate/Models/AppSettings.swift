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

enum DictationMode: String, CaseIterable, Identifiable {
    /// Segura o hotkey enquanto fala; solta para transcrever.
    case pushToTalk
    /// Um toque inicia, outro toque encerra.
    case toggle
    /// Toque curto trava a gravação (encerra no próximo toque);
    /// segurar funciona como push-to-talk.
    case tapOrHold

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pushToTalk: return "Segurar para falar (push-to-talk)"
        case .toggle: return "Tocar para iniciar/parar (toggle)"
        case .tapOrHold: return "Inteligente (toque = toggle, segurar = push-to-talk)"
        }
    }
}

struct ModelOption: Identifiable {
    let variant: String
    let label: String
    var id: String { variant }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // No repositório argmaxinc/whisperkit-coreml, "large-v3-v20240930" É o
    // large-v3-turbo da OpenAI (nomeado pela data de lançamento).
    static let defaultModelVariant = "openai_whisper-large-v3-v20240930"

    static let modelOptions: [ModelOption] = [
        ModelOption(variant: defaultModelVariant,
                    label: "Large v3 Turbo — padrão (~1,5 GB)"),
        ModelOption(variant: "openai_whisper-large-v3-v20240930_626MB",
                    label: "Large v3 Turbo quantizado — leve (~626 MB)"),
        ModelOption(variant: "openai_whisper-small",
                    label: "Small multilíngue — rápido, menos preciso (~460 MB)"),
        ModelOption(variant: "distil-whisper_distil-large-v3",
                    label: "Distil Large v3 — só inglês (~750 MB)"),
    ]

    @Published var language: String {
        didSet { UserDefaults.standard.set(language, forKey: "language") }
    }

    @Published var modelVariant: String {
        didSet { UserDefaults.standard.set(modelVariant, forKey: "modelVariant") }
    }

    @Published var hotkeyPresetRaw: String {
        didSet { UserDefaults.standard.set(hotkeyPresetRaw, forKey: "hotkeyPreset") }
    }

    @Published var dictationModeRaw: String {
        didSet { UserDefaults.standard.set(dictationModeRaw, forKey: "dictationMode") }
    }

    /// UID do dispositivo de entrada preferido; vazio = padrão do sistema.
    @Published var inputDeviceUID: String {
        didSet { UserDefaults.standard.set(inputDeviceUID, forKey: "inputDeviceUID") }
    }

    @Published var overlayEnabled: Bool {
        didSet { UserDefaults.standard.set(overlayEnabled, forKey: "overlayEnabled") }
    }

    var dictationMode: DictationMode {
        DictationMode(rawValue: dictationModeRaw) ?? .pushToTalk
    }

    /// Limite de gravação para evitar hotkey preso (segundos).
    let maxRecordingSeconds: TimeInterval = 120

    private init() {
        let defaults = UserDefaults.standard
        language = defaults.string(forKey: "language") ?? TranscriptionLanguage.portuguese.rawValue
        modelVariant = defaults.string(forKey: "modelVariant") ?? Self.defaultModelVariant
        hotkeyPresetRaw = defaults.string(forKey: "hotkeyPreset") ?? HotkeyPreset.default.rawValue
        dictationModeRaw = defaults.string(forKey: "dictationMode") ?? DictationMode.pushToTalk.rawValue
        inputDeviceUID = defaults.string(forKey: "inputDeviceUID") ?? ""
        overlayEnabled = defaults.object(forKey: "overlayEnabled") as? Bool ?? true
    }
}
