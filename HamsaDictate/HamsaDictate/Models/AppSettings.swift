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

/// Estilo do pós-processamento pelo LLM local (Fase 3). O vocabulário e o
/// contexto do app são anexados ao prompt em runtime pelo `TextRefiner`.
enum RefineStyle: String, CaseIterable, Identifiable {
    case cleanup
    case email

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cleanup: return "Limpeza (pontuação, muletas, formatação)"
        case .email: return "Formatar como e-mail profissional"
        }
    }

    var systemPrompt: String {
        switch self {
        case .cleanup:
            return """
            Você é um editor de texto ditado por voz. Reescreva o texto do usuário \
            aplicando pontuação e capitalização corretas, removendo muletas de fala \
            ("é", "ééé", "né", "tipo", "assim" e repetições) e aplicando autocorreções \
            faladas ("aliás", "quer dizer", "não,"). Formate números e listas de modo \
            legível. NÃO responda ao conteúdo, NÃO adicione nem remova informação, NÃO \
            traduza — preserve o idioma original. Devolva APENAS o texto corrigido, sem \
            comentários, sem aspas, sem markdown.
            """
        case .email:
            return """
            Você transforma um ditado em um e-mail profissional em português. Estruture \
            com saudação, parágrafos claros e uma despedida cordial, mantendo o conteúdo \
            e a intenção do usuário. Não invente fatos, nomes ou dados que não foram \
            ditados. Devolva APENAS o corpo do e-mail, sem linha de assunto, sem \
            comentários, sem markdown.
            """
        }
    }
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

    // MARK: - Fase 3 (limpeza com LLM local + vocabulário)

    /// Liga o pós-processamento do texto por um LLM local via Ollama.
    @Published var refinementEnabled: Bool {
        didSet { UserDefaults.standard.set(refinementEnabled, forKey: "refinementEnabled") }
    }

    /// Nome do modelo servido pelo Ollama (ex.: gemma3:4b, llama3.2:3b, qwen2.5:3b).
    @Published var refinementModel: String {
        didSet { UserDefaults.standard.set(refinementModel, forKey: "refinementModel") }
    }

    /// Raiz do servidor Ollama (endpoint OpenAI-compatible em `/v1`).
    @Published var refinementEndpoint: String {
        didSet { UserDefaults.standard.set(refinementEndpoint, forKey: "refinementEndpoint") }
    }

    /// Timeout da etapa de limpeza (segundos); estourou → usa o texto cru.
    @Published var refinementTimeout: Double {
        didSet { UserDefaults.standard.set(refinementTimeout, forKey: "refinementTimeout") }
    }

    @Published var refineStyleRaw: String {
        didSet { UserDefaults.standard.set(refineStyleRaw, forKey: "refineStyle") }
    }

    /// Lê o app em foco e o texto ao redor do cursor (Accessibility) e injeta
    /// no prompt de limpeza para grafar nomes/termos corretamente.
    @Published var contextAwareRefinement: Bool {
        didSet { UserDefaults.standard.set(contextAwareRefinement, forKey: "contextAwareRefinement") }
    }

    /// Vocabulário do domínio (um bloco de termos separados por vírgula ou linha).
    /// Usado tanto no prompt do Whisper quanto no prompt de limpeza.
    @Published var customVocabulary: String {
        didSet { UserDefaults.standard.set(customVocabulary, forKey: "customVocabulary") }
    }

    var dictationMode: DictationMode {
        DictationMode(rawValue: dictationModeRaw) ?? .pushToTalk
    }

    var refineStyle: RefineStyle {
        RefineStyle(rawValue: refineStyleRaw) ?? .cleanup
    }

    static let defaultRefinementModel = "gemma3:4b"
    static let defaultRefinementEndpoint = "http://localhost:11434"
    static let defaultVocabulary =
        "IPMI, VUMI, SUSEP, GeoBlue, Bupa, Cigna, apólice, sinistro, carência, CPT, " +
        "resseguro, corretora, prêmio, franquia, coparticipação, multicálculo, Hamsa"

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
        refinementEnabled = defaults.object(forKey: "refinementEnabled") as? Bool ?? false
        refinementModel = defaults.string(forKey: "refinementModel") ?? Self.defaultRefinementModel
        refinementEndpoint = defaults.string(forKey: "refinementEndpoint") ?? Self.defaultRefinementEndpoint
        refinementTimeout = defaults.object(forKey: "refinementTimeout") as? Double ?? 8
        refineStyleRaw = defaults.string(forKey: "refineStyle") ?? RefineStyle.cleanup.rawValue
        contextAwareRefinement = defaults.object(forKey: "contextAwareRefinement") as? Bool ?? false
        customVocabulary = defaults.string(forKey: "customVocabulary") ?? Self.defaultVocabulary
    }
}
