import SwiftUI

@main
struct HamsaDictateApp: App {
    @StateObject private var controller = DictationController()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(controller)
        } label: {
            MenuBarIcon()
                .environmentObject(controller)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Ícone do menu bar que reflete o estado atual (idle / gravando / transcrevendo…).
struct MenuBarIcon: View {
    @EnvironmentObject private var controller: DictationController

    var body: some View {
        Image(systemName: controller.status.symbolName)
    }
}
