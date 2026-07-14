import AppKit
import ApplicationServices

/// Lê o nome do app em foco e o texto ao redor do cursor via Accessibility,
/// para dar contexto à etapa de limpeza (grafia de nomes e termos). Padrão
/// `AppContextService` do FreeFlow. Reaproveita a permissão de Acessibilidade
/// que o app já usa para o ⌘V simulado — sem ela, degrada em silêncio.
@MainActor
enum AppContextReader {
    /// Teto de caracteres injetados, para não estourar a latência da limpeza.
    private static let maxContextChars = 500

    struct Context {
        let appName: String?
        let nearbyText: String?

        /// Representação de uma linha para o prompt de limpeza; `nil` se vazio.
        var promptString: String? {
            var parts: [String] = []
            if let appName, !appName.isEmpty { parts.append("app: \(appName)") }
            if let nearbyText, !nearbyText.isEmpty {
                parts.append("texto próximo ao cursor: \"\(nearbyText)\"")
            }
            return parts.isEmpty ? nil : parts.joined(separator: "; ")
        }
    }

    static func capture() -> Context {
        Context(
            appName: NSWorkspace.shared.frontmostApplication?.localizedName,
            nearbyText: focusedText()
        )
    }

    /// Valor textual do elemento de UI focado no sistema (o campo onde o texto
    /// será inserido). Retorna os últimos `maxContextChars` caracteres.
    private static func focusedText() -> String? {
        let systemWide = AXUIElementCreateSystemWide()

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focused
        ) == .success, let focused else { return nil }
        // swiftlint:disable:next force_cast
        let element = focused as! AXUIElement

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &value
        ) == .success, let string = value as? String else { return nil }

        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count <= maxContextChars ? trimmed : String(trimmed.suffix(maxContextChars))
    }
}
