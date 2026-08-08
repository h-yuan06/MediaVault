import Foundation

@MainActor
class DependencyInstaller: ObservableObject {
    static let shared: DependencyInstaller = {
        MainActor.assumeIsolated { DependencyInstaller() }
    }()

    enum StepStatus {
        case pending, running, done, failed(String)
    }

    struct Step: Identifiable {
        let id: String
        let displayName: String
        var status: StepStatus = .pending
        var output: String = ""
    }

    @Published var steps: [Step] = [
        Step(id: "yt-dlp",     displayName: "yt-dlp"),
        Step(id: "ffmpeg",     displayName: "ffmpeg"),
        Step(id: "gallery-dl", displayName: "gallery-dl"),
        Step(id: "deno",       displayName: "Deno"),
    ]
    @Published var isRunning = false
    @Published var isDone = false

    // Homebrew paths for Apple Silicon and Intel
    static let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    var brewPath: String? {
        Self.brewPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    var brewInstalled: Bool { brewPath != nil }

    private init() {}

    func installAll() async {
        guard let brew = brewPath else { return }
        isRunning = true
        isDone = false

        for i in steps.indices {
            steps[i].status = .running
            steps[i].output = ""
            let tool = steps[i].id
            let (output, success) = await runBrewInstall(brew: brew, package: tool)
            steps[i].output = output
            steps[i].status = success ? .done : .failed(output)
        }

        isRunning = false
        isDone = true
        await ToolChecker.shared.check()
    }

    private func runBrewInstall(brew: String, package: String) async -> (String, Bool) {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: brew)
            process.arguments = ["install", package]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try? process.run()
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (output, process.terminationStatus == 0)
        }.value
    }
}
