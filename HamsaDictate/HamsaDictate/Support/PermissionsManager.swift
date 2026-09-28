import AppKit
import ApplicationServices
import AVFoundation
import UserNotifications

@MainActor
final class PermissionsManager: ObservableObject {
    @Published private(set) var microphoneGranted = false
    @Published private(set) var accessibilityGranted = false

    func refresh() {
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityGranted = AXIsProcessTrusted()
    }

    var allGranted: Bool { microphoneGranted && accessibilityGranted }

    // MARK: - Microfone

    func requestMicrophone() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        microphoneGranted = granted
        if !granted {
            openSystemSettings(pane: "Privacy_Microphone")
        }
    }

    // MARK: - Acessibilidade

    /// Mostra o prompt do sistema (uma vez) e abre o pane de Acessibilidade.
    /// Não há callback do sistema — a UI deve re-checar via `refresh()`.
    func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        if !accessibilityGranted {
            openSystemSettings(pane: "Privacy_Accessibility")
        }
    }

    // MARK: - Notificações (fallback sem Acessibilidade)

    func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func openSystemSettings(pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
