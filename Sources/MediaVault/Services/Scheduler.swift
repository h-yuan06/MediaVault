import Foundation
import Combine

@MainActor
class Scheduler: ObservableObject {
    static let shared: Scheduler = {
        MainActor.assumeIsolated { Scheduler() }
    }()

    @Published private(set) var isRunning = false
    @Published private(set) var lastGlobalCheck: Date?

    private var timer: Timer?
    private let intervalHours: Double = 24
    private let store = SourceStore.shared
    private let engine = DownloadEngine.shared
    private let lastCheckKey = "lastGlobalCheck"

    private init() {
        if let ts = UserDefaults.standard.object(forKey: lastCheckKey) as? Date {
            lastGlobalCheck = ts
        }
        scheduleNext()
    }

    // MARK: - Manual trigger

    func checkNow() {
        runCheck()
    }

    // MARK: - Scheduling

    private func scheduleNext() {
        timer?.invalidate()

        let interval = intervalHours * 3600
        let nextFire: Date

        if let last = lastGlobalCheck {
            let elapsed = Date().timeIntervalSince(last)
            let remaining = max(interval - elapsed, 60)
            nextFire = Date().addingTimeInterval(remaining)
        } else {
            // No previous check — run soon
            nextFire = Date().addingTimeInterval(5)
        }

        let delay = nextFire.timeIntervalSinceNow
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.runCheck()
                self?.scheduleNext()
            }
        }
    }

    private func runCheck() {
        guard !isRunning else { return }
        isRunning = true

        let sources = store.sources
        for source in sources {
            engine.sync(source: source, store: store)
        }

        lastGlobalCheck = Date()
        UserDefaults.standard.set(lastGlobalCheck, forKey: lastCheckKey)
        isRunning = false
    }
}
