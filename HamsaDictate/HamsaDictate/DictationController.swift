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
        case error(String)

        var symbolName: String {
            switch self {
            case .downloadingModel: return "arrow.down.circle"
            case .loadingModel: return "hourglass"
            case .idle: return "mic"
            case .recording: return "mic.fill"
            case .transcribing: return "waveform"
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

    private let recorder = AudioRecorder()
    private let inserter = TextInserter()
    private let hotkeys = HotkeyManager()
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

        if !permissions.allGranted {
            showSettings()
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

        Task { [weak self] in
            do {
                let text = try await engine.transcribe(samples: samples, language: language)
                await MainActor.run { self?.deliver(text) }
            } catch {
                await MainActor.run {
                    self?.flashError("Falha na transcrição: \(error.localizedDescription)")
                }
            }
        }
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
        case .recording, .transcribing:
            overlay.show(controller: self)
        default:
            overlay.hide()
        }
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
