import AppKit
import Combine
import Foundation
import SwiftUI
import UserNotifications

struct Transcription: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let date: Date
}

/// Orquestra o pipeline completo:
/// hotkey → AudioRecorder → WhisperKit.transcribe → TextInserter.insert
/// Suporta push-to-talk, toggle e tap-or-hold; overlay com waveform;
/// troca de modelo/hotkey/device em runtime via Settings.
@MainActor
final class DictationController: ObservableObject {
    enum Status: Equatable {
        case downloadingModel(Double)
        case loadingModel
        case idle
        case recording
        case transcribing
        case refining
        case error(String)

        var symbolName: String {
            switch self {
            case .downloadingModel: return "arrow.down.circle"
            case .loadingModel: return "hourglass"
            case .idle: return "mic"
            case .recording: return "mic.fill"
            case .transcribing: return "waveform"
            case .refining: return "sparkles"
            case .error: return "exclamationmark.triangle"
            }
        }

        var label: String {
            switch self {
            case let .downloadingModel(fraction):
                return "Baixando modelo… \(Int(fraction * 100))%"
            case .loadingModel: return "Carregando modelo…"
            case .idle: return "Pronto para ditar"
            case .recording: return "Gravando…"
            case .transcribing: return "Transcrevendo…"
            case .refining: return "Refinando com IA…"
            case let .error(message): return message
            }
        }
    }

    @Published private(set) var status: Status = .loadingModel {
        didSet { updateOverlay() }
    }
    @Published private(set) var history: [Transcription] = []
    /// Níveis RMS recentes (0…1) para o waveform do overlay.
    @Published private(set) var audioLevels: [Float] = []

    let permissions = PermissionsManager()
    let settings = AppSettings.shared

    /// `true` quando o Ollama respondeu ao último health-check (só informativo
    /// para a UI; o refino se autodefende de qualquer forma).
    @Published private(set) var refinementAvailable = false

    private let recorder = AudioRecorder()
    private let inserter = TextInserter()
    private let hotkeys = HotkeyManager()
    private let refiner = TextRefiner()
    private var engine: TranscriptionEngine
    private var engineVariant: String
    private let settingsWindow = SettingsWindow()
    private let overlay = RecordingOverlay()
    private var cancellables = Set<AnyCancellable>()

    /// tap-or-hold: início do pressionamento para distinguir toque de segurada.
    private var pressStartedAt: Date?
    private static let tapThreshold: TimeInterval = 0.35

    private static let maxHistoryEntries = 20
    private static let maxLevelSamples = 48
    /// Gravações mais curtas que isso são toques acidentais no hotkey.
    private static let minimumRecordingSeconds = 0.3

    init() {
        engineVariant = settings.modelVariant
        engine = WhisperKitEngine(variant: settings.modelVariant)
        recorder.maxDuration = settings.maxRecordingSeconds
        recorder.preferredDeviceUID = settings.inputDeviceUID

        // Os handlers do HotKey e do recorder chegam na main thread, mas em
        // closures não-isoladas — assumeIsolated evita o hop (e reordenação)
        // que um Task introduziria entre keyDown e keyUp.
        hotkeys.onKeyDown = { [weak self] in
            MainActor.assumeIsolated { self?.hotkeyDown() }
        }
        hotkeys.onKeyUp = { [weak self] in
            MainActor.assumeIsolated { self?.hotkeyUp() }
        }

        recorder.onMaxDurationReached = { [weak self] in
            MainActor.assumeIsolated { self?.endRecordingAndTranscribe() }
        }
        recorder.onLevel = { [weak self] level in
            MainActor.assumeIsolated { self?.pushLevel(level) }
        }
        recorder.onConfigurationChange = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.status == .recording else { return }
                self.recorder.cancel()
                self.pressStartedAt = nil
                self.flashError("O dispositivo de áudio mudou durante a gravação. Tente de novo.")
            }
        }

        bindSettings()

        // PermissionsManager é um ObservableObject aninhado: repassa as
        // mudanças para as views que observam apenas o controller.
        permissions.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        permissions.refresh()
        permissions.requestNotifications()

        // Abrir a janela de onboarding tem de sair do ciclo de atualização da
        // view (este init roda dentro do primeiro render do @StateObject do App);
        // apresentá-la de forma síncrona dispara "AttributeGraph precondition
        // failure: setting value during update" → SIGABRT.
        if !permissions.allGranted {
            Task { @MainActor [weak self] in self?.showSettings() }
        }

        Task { await prepareEngine() }
    }

    /// Reage a mudanças das Settings sem exigir reinício do app.
    private func bindSettings() {
        settings.$hotkeyPresetRaw
            .removeDuplicates()
            .sink { [weak self] raw in
                let preset = HotkeyPreset(rawValue: raw) ?? .default
                self?.hotkeys.register(preset: preset)
            }
            .store(in: &cancellables)

        settings.$inputDeviceUID
            .removeDuplicates()
            .sink { [weak self] uid in
                self?.recorder.preferredDeviceUID = uid
            }
            .store(in: &cancellables)

        settings.$overlayEnabled
            .removeDuplicates()
            .sink { [weak self] _ in self?.updateOverlay() }
            .store(in: &cancellables)

        settings.$modelVariant
            .removeDuplicates()
            .dropFirst() // o init já prepara o modelo inicial
            .sink { [weak self] variant in
                self?.reloadModel(variant: variant)
            }
            .store(in: &cancellables)
    }

    // MARK: - Modelo

    func prepareEngine() async {
        status = .downloadingModel(0)
        do {
            try await engine.prepare { [weak self] phase in
                Task { @MainActor in
                    switch phase {
                    case let .downloading(fraction):
                        self?.status = .downloadingModel(fraction)
                    case .loading:
                        self?.status = .loadingModel
                    }
                }
            }
            status = .idle
        } catch {
            status = .error("Falha ao preparar o modelo: \(error.localizedDescription)")
        }
    }

    /// Troca de modelo em runtime. O picker fica desabilitado fora de
    /// idle/error, então aqui só validamos de novo por segurança.
    private func reloadModel(variant: String) {
        guard variant != engineVariant else { return }
        switch status {
        case .idle, .error: break
        default: return
        }
        engineVariant = variant
        engine = WhisperKitEngine(variant: variant)
        Task { await prepareEngine() }
    }

    // MARK: - Hotkey (modos)

    private func hotkeyDown() {
        switch settings.dictationMode {
        case .pushToTalk:
            beginRecording()
        case .toggle:
            if status == .recording {
                endRecordingAndTranscribe()
            } else {
                beginRecording()
            }
        case .tapOrHold:
            if status == .recording {
                // Segundo toque encerra a gravação travada.
                pressStartedAt = nil
                endRecordingAndTranscribe()
            } else {
                beginRecording()
                pressStartedAt = Date()
            }
        }
    }

    private func hotkeyUp() {
        switch settings.dictationMode {
        case .pushToTalk:
            endRecordingAndTranscribe()
        case .toggle:
            break
        case .tapOrHold:
            guard status == .recording, let start = pressStartedAt else { return }
            pressStartedAt = nil
            if Date().timeIntervalSince(start) >= Self.tapThreshold {
                // Estava segurando: comporta-se como push-to-talk.
                endRecordingAndTranscribe()
            }
            // Toque curto: gravação fica travada até o próximo toque.
        }
    }

    // MARK: - Pipeline de ditado

    private func beginRecording() {
        guard status == .idle else { return }
        guard permissions.microphoneGranted else {
            permissions.refresh()
            if permissions.microphoneGranted { return beginRecording() }
            showSettings()
            return
        }
        do {
            audioLevels.removeAll()
            try recorder.start()
            status = .recording
        } catch {
            flashError("Não foi possível iniciar a gravação: \(error.localizedDescription)")
        }
    }

    private func endRecordingAndTranscribe() {
        guard status == .recording else { return }
        let samples = recorder.stop()

        let duration = Double(samples.count) / AudioRecorder.targetSampleRate
        guard duration >= Self.minimumRecordingSeconds, !AudioRecorder.isSilence(samples) else {
            status = .idle
            return
        }

        status = .transcribing
        let language = TranscriptionLanguage(rawValue: settings.language)?.whisperCode ?? "pt"
        let engine = engine
        let vocabulary = settings.customVocabulary
        let refineEnabled = settings.refinementEnabled

        Task { [weak self] in
            do {
                let raw = try await engine.transcribe(
                    samples: samples, language: language, prompt: vocabulary
                )
                let text: String
                if refineEnabled, let self {
                    text = await self.refine(raw)
                } else {
                    text = raw
                }
                await MainActor.run { self?.deliver(text) }
            } catch {
                await MainActor.run {
                    self?.flashError("Falha na transcrição: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Etapa de limpeza (Fase 3). Só entra na rede se o Ollama estiver no ar;
    /// devolve o texto cru em qualquer falha ou timeout — nunca bloqueia.
    private func refine(_ raw: String) async -> String {
        guard !raw.isEmpty else { return raw }

        guard await refiner.isAvailable(endpoint: settings.refinementEndpoint) else {
            refinementAvailable = false
            return raw
        }
        refinementAvailable = true
        status = .refining

        // Captura o contexto do app alvo antes do hop de rede (o campo ainda
        // está focado: o overlay é não-ativador).
        let context: String? = settings.contextAwareRefinement
            ? AppContextReader.capture().promptString
            : nil

        let request = RefinementRequest(
            text: raw,
            systemPrompt: settings.refineStyle.systemPrompt,
            model: settings.refinementModel,
            endpoint: settings.refinementEndpoint,
            timeout: settings.refinementTimeout,
            vocabulary: settings.customVocabulary,
            appContext: context
        )
        return await refiner.refine(request)
    }

    private func deliver(_ text: String) {
        guard !text.isEmpty else {
            status = .idle
            return
        }

        history.insert(Transcription(text: text, date: .now), at: 0)
        if history.count > Self.maxHistoryEntries {
            history.removeLast(history.count - Self.maxHistoryEntries)
        }

        inserter.insert(text) { [weak self] pasted in
            // Completion chega na main thread (asyncAfter em .main).
            MainActor.assumeIsolated {
                if !pasted {
                    self?.notifyClipboardFallback()
                }
            }
        }
        status = .idle
    }

    private func pushLevel(_ level: Float) {
        guard status == .recording else { return }
        // Ganho para tornar fala em volume normal visível no waveform.
        audioLevels.append(min(1, level * 12))
        if audioLevels.count > Self.maxLevelSamples {
            audioLevels.removeFirst(audioLevels.count - Self.maxLevelSamples)
        }
    }

    // MARK: - UI helpers

    private func updateOverlay() {
        guard settings.overlayEnabled else {
            overlay.hide()
            return
        }
        switch status {
        case .recording, .transcribing, .refining:
            overlay.show(controller: self)
        default:
            overlay.hide()
        }
    }

    /// Re-checa se o Ollama está no ar (chamado ao abrir as Settings).
    func refreshRefinementAvailability() {
        Task { [weak self] in
            guard let self else { return }
            let available = await self.refiner.isAvailable(endpoint: self.settings.refinementEndpoint)
            self.refinementAvailable = available
        }
    }

    /// Alterna entre limpeza padrão e formatação de e-mail (atalho do menu).
    func toggleEmailStyle() {
        settings.refineStyleRaw = settings.refineStyle == .email
            ? RefineStyle.cleanup.rawValue
            : RefineStyle.email.rawValue
    }

    func showSettings() {
        settingsWindow.show(controller: self)
    }

    func clearHistory() {
        history.removeAll()
    }

    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func flashError(_ message: String) {
        status = .error(message)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, case .error = self.status else { return }
            self.status = .idle
        }
    }

    private func notifyClipboardFallback() {
        let content = UNMutableNotificationContent()
        content.title = "HamsaDictate"
        content.body = "Sem permissão de Acessibilidade: o texto foi copiado. Cole com ⌘V."
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
