import AppKit
import Foundation
import HotKey

/// Presets de hotkey oferecidos nas Settings. Um gravador de atalho
/// arbitrário (estilo NSEvent recorder) fica para depois — presets cobrem
/// os casos práticos sem conflitar com atalhos do sistema.
enum HotkeyPreset: String, CaseIterable, Identifiable {
    case optionSpace
    case controlSpace
    case optionCommandSpace
    case shiftOptionSpace

    static let `default` = HotkeyPreset.optionSpace

    var id: String { rawValue }

    var label: String {
        switch self {
        case .optionSpace: return "⌥ Espaço"
        case .controlSpace: return "⌃ Espaço"
        case .optionCommandSpace: return "⌥⌘ Espaço"
        case .shiftOptionSpace: return "⇧⌥ Espaço"
        }
    }

    var key: Key { .space }

    var modifiers: NSEvent.ModifierFlags {
        switch self {
        case .optionSpace: return [.option]
        case .controlSpace: return [.control]
        case .optionCommandSpace: return [.option, .command]
        case .shiftOptionSpace: return [.shift, .option]
        }
    }
}

/// Hotkey global com dois eventos (down/up) para suportar push-to-talk,
/// toggle e tap-or-hold. Re-registrável quando o preset muda nas Settings.
final class HotkeyManager {
    private var hotKey: HotKey?

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    func register(preset: HotkeyPreset) {
        let key = HotKey(key: preset.key, modifiers: preset.modifiers)
        key.keyDownHandler = { [weak self] in self?.onKeyDown?() }
        key.keyUpHandler = { [weak self] in self?.onKeyUp?() }
        hotKey = key
    }

    func unregister() {
        hotKey = nil
    }
}
