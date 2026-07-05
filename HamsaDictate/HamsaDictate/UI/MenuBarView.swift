import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var controller: DictationController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Status atual
            HStack(spacing: 8) {
                Image(systemName: controller.status.symbolName)
                    .foregroundStyle(statusColor)
                Text(statusLine)
                    .font(.callout)
                    .lineLimit(2)
            }

            if case let .downloadingModel(fraction) = controller.status {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            }

            if !controller.history.isEmpty {
                Divider()
                HStack {
                    Text("Últimas transcrições")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Limpar") {
                        controller.clearHistory()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(controller.history) { item in
                            Button {
                                controller.copyToClipboard(item.text)
                            } label: {
                                HStack {
                                    Text(item.text)
                                        .lineLimit(2)
                                        .truncationMode(.tail)
                                    Spacer()
                                    Image(systemName: "doc.on.doc")
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Copiar para o clipboard")
                        }
                    }
                }
                .frame(maxHeight: 220)
            }

            Divider()

            Button("Configurações…") {
                controller.showSettings()
            }

            Button("Sair do HamsaDictate") {
                controller.quit()
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    private var statusLine: String {
        if controller.status == .idle {
            let preset = HotkeyPreset(rawValue: controller.settings.hotkeyPresetRaw) ?? .default
            switch controller.settings.dictationMode {
            case .pushToTalk:
                return "Pronto — segure \(preset.label) para ditar"
            case .toggle:
                return "Pronto — toque \(preset.label) para gravar/parar"
            case .tapOrHold:
                return "Pronto — toque ou segure \(preset.label)"
            }
        }
        return controller.status.label
    }

    private var statusColor: Color {
        switch controller.status {
        case .recording: return .red
        case .transcribing: return .orange
        case .error: return .yellow
        default: return .primary
        }
    }
}
