import SwiftUI

/// App entry point: one main window, a Settings scene and keyboard-driven menu commands.
@main
struct DiskSunburstApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = ScanModel()

    var body: some Scene {
        Window("DiskSunburst", id: "main") {
            ContentView().environmentObject(model)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Choose Folder…") { model.chooseFolder() }.keyboardShortcut("o")
                Button("Rescan") { model.rescan() }.keyboardShortcut("r").disabled(model.rootURL == nil)
            }
            CommandMenu("Item") {
                Button("Reveal in Finder") { model.reveal() }.keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Open") { model.open() }.keyboardShortcut(.downArrow, modifiers: .command)
                Button("Copy Path") { model.copyPath() }.keyboardShortcut("c", modifiers: [.command, .shift])
                Divider()
                Button("Move to Trash…") { model.requestTrash() }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(!model.canTrash)
                Button("Up One Level") { model.goUp() }.disabled(model.path.isEmpty)
            }
            CommandGroup(after: .help) {
                Button("Support / Donate ❤️") { model.openDonate() }
            }
        }
        Settings {
            SettingsView()
        }
    }
}

/// Quits the app when its single window closes, which also cancels any running scan.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
