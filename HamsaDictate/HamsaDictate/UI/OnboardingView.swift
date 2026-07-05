import AppKit
import SwiftUI

/// Janela de onboarding: permissões (microfone + Acessibilidade),
/// progresso do modelo e idioma da transcrição.
struct OnboardingView: View {
    @EnvironmentObject private var controller: DictationController
    @ObservedObject private var settings = AppSettings.shared

    private let permissionPoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("HamsaDictate")
                .font(.title2.bold())
            Text("Ditado local em PT-BR/EN: segure ⌥Espaço, fale, solte. O texto aparece no campo ativo. Nada sai do seu Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

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

            Divider()

            HStack(spacing: 8) {
                Image(systemName: modelReady ? "checkmark.circle.fill" : controller.status.symbolName)
                    .foregroundStyle(modelReady ? .green : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Modelo de transcrição")
                        .font(.headline)
                    Text(modelStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if case let .downloadingModel(fraction) = controller.status {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                    }
                }
            }

            Picker("Idioma do ditado", selection: $settings.language) {
                ForEach(TranscriptionLanguage.allCases) { language in
                    Text(language.label).tag(language.rawValue)
                }
            }
            .pickerStyle(.menu)

            Divider()

            Text("Uso: foque um campo de texto em qualquer app, segure ⌥Espaço enquanto fala e solte para inserir a transcrição.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { controller.permissions.refresh() }
        .onReceive(permissionPoll) { _ in
            // AXIsProcessTrusted não tem callback — re-checa enquanto a janela está aberta.
            controller.permissions.refresh()
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
            return "\(settings.modelVariant) — pronto (≈1,5 GB, roda no Neural Engine)"
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
final class OnboardingWindow {
    private var window: NSWindow?

    func show(controller: DictationController) {
        if window == nil {
            let hosting = NSHostingController(
                rootView: OnboardingView().environmentObject(controller)
            )
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.title = "HamsaDictate — Configuração"
            newWindow.styleMask = [.titled, .closable]
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            window = newWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
