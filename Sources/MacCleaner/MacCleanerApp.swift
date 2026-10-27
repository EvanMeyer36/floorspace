import AppKit
import SwiftUI

@main
struct MacCleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var explorer = ExplorerModel()
    @StateObject private var apps = AppsModel()

    var body: some Scene {
        Window("Mac Cleaner", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(explorer)
                .environmentObject(apps)
                .frame(minWidth: 860, minHeight: 580)
        }
        .defaultSize(width: 1040, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Scan") {
                Button("Smart Scan") { model.smartScan() }
                    .keyboardShortcut("r")
                    .disabled(model.isScanning)
                Button("Stop All Scans") { model.cancelAllScans() }
                    .keyboardShortcut(".")
                    .disabled(!model.isScanning)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched with `swift run` (no app bundle) so the window comes to the front.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
