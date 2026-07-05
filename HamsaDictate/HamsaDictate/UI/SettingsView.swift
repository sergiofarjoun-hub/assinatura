import AppKit
import SwiftUI

/// Janela única de configuração: permissões, ditado (hotkey/modo/idioma/
/// overlay), dispositivo de áudio e modelo. Também serve de onboarding —
/// abre sozinha no primeiro launch enquanto faltarem permissões.
struct SettingsView: View {
    @EnvironmentObject private var controller: DictationController
    @ObservedObject private var settings = AppSettings.shared

    @State private var inputDevices: [AudioInputDevice] = []

    private let permissionPoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Permissões") {
                permissionRow(
                    granted: controller.permissions.microphoneGranted,
                    title: "Microfone",
                    detail: "Necessário para gravar o ditado.",
                    buttonTitle: "Permitir microfone"
                ) {
                    Task { await controller.permissions.requestMicrophone() }
                }

                permissionRow(
                    granted: controller.permissions.accessibilityGranted,
                    title: "Acessibilidade",
                    detail: "Necessária para colar o texto no app ativo (⌘V simulado). Sem ela, o texto fica no clipboard.",
                    buttonTitle: "Abrir ajustes de Acessibilidade"
                ) {
                    controller.permissions.promptAccessibility()
                }
            }

            Section("Ditado") {
                Picker("Atalho global", selection: $settings.hotkeyPresetRaw) {
                    ForEach(HotkeyPreset.allCases) { preset in
                        Text(preset.label).tag(preset.rawValue)
                    }
                }

                Picker("Modo", selection: $settings.dictationModeRaw) {
                    ForEach(DictationMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }

                Picker("Idioma", selection: $settings.language) {
                    ForEach(TranscriptionLanguage.allCases) { language in
                        Text(language.label).tag(language.rawValue)
                    }
                }

                Toggle("Overlay flutuante com waveform durante a gravação", isOn: $settings.overlayEnabled)
            }

            Section("Áudio") {
                Picker("Dispositivo de entrada", selection: $settings.inputDeviceUID) {
                    Text("Padrão do sistema").tag("")
                    ForEach(inputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                Text("Mic Bluetooth em perfil HFP (16 kHz comprimido) transcreve pior — prefira o mic interno para textos longos. Vale a partir da próxima gravação.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Modelo de transcrição") {
                Picker("Modelo", selection: $settings.modelVariant) {
                    ForEach(AppSettings.modelOptions) { option in
                        Text(option.label).tag(option.variant)
                    }
                }
                .disabled(!modelPickerEnabled)

                HStack(spacing: 8) {
                    Image(systemName: modelReady ? "checkmark.circle.fill" : controller.status.symbolName)
                        .foregroundStyle(modelReady ? .green : .secondary)
                    Text(modelStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if case let .downloadingModel(fraction) = controller.status {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                }
            }

            Section {
                Text("Uso: foque um campo de texto em qualquer app e use o atalho conforme o modo escolhido. Nada sai do seu Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
        .onAppear {
            controller.permissions.refresh()
            inputDevices = AudioDeviceManager.inputDevices()
        }
        .onReceive(permissionPoll) { _ in
            // AXIsProcessTrusted não tem callback — re-checa com a janela aberta.
            controller.permissions.refresh()
        }
    }

    private var modelPickerEnabled: Bool {
        switch controller.status {
        case .idle, .error: return true
        default: return false
        }
    }

    private var modelReady: Bool {
        switch controller.status {
        case .downloadingModel, .loadingModel: return false
        case let .error(message): return !message.contains("modelo")
        default: return true
        }
    }

    private var modelStatusText: String {
        switch controller.status {
        case .downloadingModel, .loadingModel, .error:
            return controller.status.label
        default:
            return "\(settings.modelVariant) — pronto (roda no Neural Engine)"
        }
    }

    @ViewBuilder
    private func permissionRow(
        granted: Bool,
        title: String,
        detail: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !granted {
                    Button(buttonTitle, action: action)
                }
            }
        }
    }
}

/// Janela AppKit dedicada (o app é LSUIElement; uma cena `Window` do SwiftUI
/// não pode ser aberta programaticamente de fora da hierarquia de views).
@MainActor
final class SettingsWindow {
    private var window: NSWindow?

    func show(controller: DictationController) {
        if window == nil {
            let hosting = NSHostingController(
                rootView: SettingsView().environmentObject(controller)
            )
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.title = "HamsaDictate — Configurações"
            newWindow.styleMask = [.titled, .closable]
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            window = newWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
