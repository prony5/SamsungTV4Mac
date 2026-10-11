import AppKit
import SwiftUI

@main
struct SamsungTV4MacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("SamsungTV4Mac", id: "main") {
            ContentView()
                .environmentObject(model)
        }
        .defaultSize(width: 860, height: 540)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Video…") { model.chooseFile() }
                    .keyboardShortcut("o")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare binary (`swift run`) rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Files opened via Finder ("Open With", or dropped on the Dock icon).
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        Task { @MainActor in AppModel.shared.openFile(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
