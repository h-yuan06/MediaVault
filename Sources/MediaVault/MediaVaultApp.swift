import SwiftUI

@main
struct MediaVaultApp: App {
    @StateObject private var store = SourceStore.shared
    @StateObject private var engine = DownloadEngine.shared
    @StateObject private var scheduler = Scheduler.shared
    @StateObject private var tools = ToolChecker.shared
    @StateObject private var updater = AutoUpdater.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(engine)
                .environmentObject(scheduler)
                .environmentObject(tools)
                .environmentObject(updater)
                .frame(minWidth: 800, minHeight: 520)
                .onAppear { AutoUpdater.shared.checkAndInstall() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Check All Sources Now") {
                    scheduler.checkNow()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Window("Media Library", id: "player") {
            PlayerWindowView()
                .environmentObject(store)
        }
        .defaultSize(width: 1200, height: 760)

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(tools)
        }
    }
}
