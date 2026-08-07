import SwiftUI

@main
struct MediaVaultApp: App {
    @StateObject private var store = SourceStore.shared
    @StateObject private var engine = DownloadEngine.shared
    @StateObject private var scheduler = Scheduler.shared
    @StateObject private var tools = ToolChecker.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(engine)
                .environmentObject(scheduler)
                .environmentObject(tools)
                .frame(minWidth: 800, minHeight: 520)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Check All Sources Now") {
                    scheduler.checkNow()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(tools)
        }
    }
}
