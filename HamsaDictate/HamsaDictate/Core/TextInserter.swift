import AppKit
import ApplicationServices

/// Insere texto no app ativo via clipboard + Cmd+V simulado:
/// 1. salva o clipboard atual  2. escreve a transcrição
/// 3. simula ⌘V (CGEvent)      4. restaura o clipboard original.
///
/// Requer permissão de Acessibilidade. Sem ela, deixa o texto no
/// clipboard e retorna `false` para o chamador notificar o usuário.
final class TextInserter {
    private static let vKeyCode: CGKeyCode = 9

    /// `completion(true)` = texto colado; `false` = fallback (ficou no clipboard).
    func insert(_ text: String, completion: @escaping (Bool) -> Void) {
        let pasteboard = NSPasteboard.general

        guard AXIsProcessTrusted() else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            completion(false)
            return
        }

        let saved = Self.snapshot(of: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Pequena espera para o pasteboard propagar antes do ⌘V.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            Self.sendCmdV()
            // O app alvo precisa ler o pasteboard antes da restauração.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                Self.restore(saved, to: pasteboard)
                completion(true)
            }
        }
    }

    // MARK: - Clipboard save/restore

    private static func snapshot(of pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var payload = [NSPasteboard.PasteboardType: Data]()
            for type in item.types {
                if let data = item.data(forType: type) {
                    payload[type] = data
                }
            }
            return payload
        }
    }

    private static func restore(_ saved: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        // Clipboard estava vazio antes? Mantém a transcrição disponível.
        guard !saved.isEmpty else { return }
        pasteboard.clearContents()
        let items = saved.map { payload -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in payload {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(items)
    }

    // MARK: - ⌘V sintético

    private static func sendCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else { return }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
