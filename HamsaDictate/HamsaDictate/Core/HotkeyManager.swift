import Foundation
import HotKey

/// Hotkey global ⌥Space em modo push-to-talk:
/// keyDown inicia a gravação, keyUp encerra e dispara a transcrição.
final class HotkeyManager {
    private var hotKey: HotKey?

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    func register() {
        let key = HotKey(key: .space, modifiers: [.option])
        key.keyDownHandler = { [weak self] in self?.onKeyDown?() }
        key.keyUpHandler = { [weak self] in self?.onKeyUp?() }
        hotKey = key
    }

    func unregister() {
        hotKey = nil
    }
}
