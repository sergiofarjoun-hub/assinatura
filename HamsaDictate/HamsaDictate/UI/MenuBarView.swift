import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var controller: DictationController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Status atual
            HStack(spacing: 8) {
                Image(systemName: controller.status.symbolName)
                    .foregroundStyle(statusColor)
                Text(controller.status.label)
                    .font(.callout)
                    .lineLimit(2)
            }

            if case let .downloadingModel(fraction) = controller.status {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            }

            if !controller.history.isEmpty {
                Divider()
                Text("Últimas transcrições")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    }
                    .buttonStyle(.plain)
                    .help("Copiar para o clipboard")
                }
            }

            Divider()

            Button("Permissões e configuração…") {
                controller.showOnboarding()
            }

            Button("Sair do HamsaDictate") {
                controller.quit()
            }
        }
        .padding(12)
        .frame(width: 300)
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
