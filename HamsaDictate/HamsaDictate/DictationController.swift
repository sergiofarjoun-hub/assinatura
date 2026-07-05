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
/// hotkey ⌥Space (down) → AudioRecorder.start()
/// hotkey (up) → stop() → WhisperKit.transcribe → TextInserter.insert
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
            case .idle: return "Pronto — segure ⌥Espaço para ditar"
            case .recording: return "Gravando… solte ⌥Espaço para transcrever"
            case .transcribing: return "Transcrevendo…"
            case let .error(message): return message
            }
        }
    }

    @Published private(set) var status: Status = .loadingModel
    @Published private(set) var history: [Transcription] = []

    let permissions = PermissionsManager()
    let settings = AppSettings.shared

    private let recorder = AudioRecorder()
    private let inserter = TextInserter()
    private let hotkeys = HotkeyManager()
    private var engine: TranscriptionEngine
    private let onboardingWindow = OnboardingWindow()
    private var cancellables = Set<AnyCancellable>()

    private static let maxHistoryEntries = 5
    /// Gravações mais curtas que isso são toques acidentais no hotkey.
    private static let minimumRecordingSeconds = 0.3

    init() {
        engine = WhisperKitEngine(variant: settings.modelVariant)
        recorder.maxDuration = settings.maxRecordingSeconds

        // Os handlers do HotKey e do recorder chegam na main thread, mas em
        // closures não-isoladas — assumeIsolated evita o hop (e reordenação)
        // que um Task introduziria entre keyDown e keyUp.
        hotkeys.onKeyDown = { [weak self] in
            MainActor.assumeIsolated { self?.beginRecording() }
        }
        hotkeys.onKeyUp = { [weak self] in
            MainActor.assumeIsolated { self?.endRecordingAndTranscribe() }
        }
        hotkeys.register()

        recorder.onMaxDurationReached = { [weak self] in
            MainActor.assumeIsolated { self?.endRecordingAndTranscribe() }
        }
        recorder.onConfigurationChange = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.status == .recording else { return }
                self.recorder.cancel()
                self.flashError("O dispositivo de áudio mudou durante a gravação. Tente de novo.")
            }
        }

        // PermissionsManager é um ObservableObject aninhado: repassa as
        // mudanças para as views que observam apenas o controller.
        permissions.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        permissions.refresh()
        permissions.requestNotifications()

        if !permissions.allGranted {
            showOnboarding()
        }

        Task { await prepareEngine() }
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

    // MARK: - Pipeline de ditado

    private func beginRecording() {
        guard status == .idle else { return }
        guard permissions.microphoneGranted else {
            permissions.refresh()
            if permissions.microphoneGranted { return beginRecording() }
            showOnboarding()
            return
        }
        do {
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

    // MARK: - UI helpers

    func showOnboarding() {
        onboardingWindow.show(controller: self)
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
