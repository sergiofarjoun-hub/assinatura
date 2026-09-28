import AppKit
import SwiftUI

/// Painel flutuante mostrado durante gravação/transcrição.
/// `.nonactivatingPanel` + `ignoresMouseEvents`: o foco (e o cursor de
/// texto) permanecem no app alvo — essencial para o ⌘V simulado.
@MainActor
final class RecordingOverlay {
    private var panel: NSPanel?

    func show(controller: DictationController) {
        if panel == nil {
            panel = makePanel(controller: controller)
        }
        position(panel!)
        panel!.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel(controller: DictationController) -> NSPanel {
        let hosting = NSHostingController(
            rootView: OverlayView().environmentObject(controller)
        )
        let panel = NSPanel(contentViewController: hosting)
        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setContentSize(NSSize(width: 240, height: 64))
        return panel
    }

    /// Centro-inferior da tela onde está o cursor do mouse (a mais provável
    /// de conter o campo de texto focado).
    private func position(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 96
        ))
    }
}

struct OverlayView: View {
    @EnvironmentObject private var controller: DictationController

    var body: some View {
        HStack(spacing: 10) {
            switch controller.status {
            case .recording:
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
                WaveformView(levels: controller.audioLevels)
            case .transcribing:
                ProgressView()
                    .controlSize(.small)
                Text("Transcrevendo…")
                    .font(.callout)
                    .foregroundStyle(.white)
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 16)
        .frame(width: 240, height: 56)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.78))
        )
        .padding(4)
    }
}

struct WaveformView: View {
    let levels: [Float]

    private static let barCount = 32

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 3, height: barHeight(at: index))
            }
        }
        .frame(height: 36)
        .animation(.linear(duration: 0.08), value: levels)
    }

    private func barHeight(at index: Int) -> CGFloat {
        // Preenche da direita para a esquerda com os níveis mais recentes.
        let offset = Self.barCount - 1 - index
        guard offset < levels.count else { return 3 }
        let level = levels[levels.count - 1 - offset]
        return max(3, CGFloat(min(level, 1)) * 36)
    }
}
