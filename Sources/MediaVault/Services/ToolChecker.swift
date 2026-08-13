import Foundation

struct ToolStatus {
    let name: String
    let path: String?
    var isAvailable: Bool { path != nil }
}

@MainActor
class ToolChecker: ObservableObject {
    static let shared: ToolChecker = {
        MainActor.assumeIsolated { ToolChecker() }
    }()

    @Published private(set) var ytdlp     = ToolStatus(name: "yt-dlp",     path: nil)
    @Published private(set) var galleryDl = ToolStatus(name: "gallery-dl", path: nil)
    @Published private(set) var ffmpeg    = ToolStatus(name: "ffmpeg",      path: nil)
    @Published private(set) var deno      = ToolStatus(name: "Deno",        path: nil)
    @Published private(set) var isChecking = false
    @Published private(set) var upgradingTool: String? = nil

    var allAvailable: Bool { ytdlp.isAvailable && ffmpeg.isAvailable && deno.isAvailable }

    private static let defaults = UserDefaults.standard
    private static let cachedPathsKey = "toolPaths"
    private static let lastUpgradeKey = "lastBrewUpgrade"
    private static let upgradeInterval: TimeInterval = 7 * 24 * 3600

    private init() {
        // Restore cached paths immediately so the UI doesn't block on relaunch
        if let saved = Self.defaults.dictionary(forKey: Self.cachedPathsKey) as? [String: String] {
            if let p = saved["yt-dlp"]     { ytdlp     = ToolStatus(name: "yt-dlp",     path: p) }
            if let p = saved["gallery-dl"] { galleryDl = ToolStatus(name: "gallery-dl", path: p) }
            if let p = saved["ffmpeg"]     { ffmpeg    = ToolStatus(name: "ffmpeg",      path: p) }
            if let p = saved["deno"]       { deno      = ToolStatus(name: "Deno",        path: p) }
        } else {
            // First launch — check immediately
            Task { await check() }
        }
    }

    func check() async {
        isChecking = true
        let (yt, gd, ff, dn) = await Task.detached(priority: .utility) {
            let ytPath = Self.resolve("yt-dlp")
            if let path = ytPath { Self.update(toolPath: path) }
            return (ytPath, Self.resolve("gallery-dl"), Self.resolve("ffmpeg"), Self.resolve("deno"))
        }.value
        ytdlp     = ToolStatus(name: "yt-dlp",     path: yt)
        galleryDl = ToolStatus(name: "gallery-dl", path: gd)
        ffmpeg    = ToolStatus(name: "ffmpeg",      path: ff)
        deno      = ToolStatus(name: "Deno",        path: dn)
        isChecking = false

        // Persist found paths so subsequent launches skip the check
        var cache: [String: String] = [:]
        if let p = yt { cache["yt-dlp"]     = p }
        if let p = gd { cache["gallery-dl"] = p }
        if let p = ff { cache["ffmpeg"]      = p }
        if let p = dn { cache["deno"]        = p }
        Self.defaults.set(cache, forKey: Self.cachedPathsKey)
    }

    private nonisolated static func resolve(_ tool: String) -> String? {
        let searchDirs = [
            "\(NSHomeDirectory())/.deno/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
        for dir in searchDirs {
            let path = "\(dir)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "command -v \(tool)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty,
              FileManager.default.isExecutableFile(atPath: output) else { return nil }
        return output
    }

    private nonisolated static func update(toolPath: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)
        process.arguments = ["-U"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }

    // brew package name for each tool (nil = self-update via -U flag)
    private static let brewPackage: [String: String?] = [
        "yt-dlp":     nil,
        "gallery-dl": "gallery-dl",
        "ffmpeg":     "ffmpeg",
        "Deno":       "deno",
    ]

    func upgradeTool(_ toolName: String) {
        guard upgradingTool == nil else { return }
        upgradingTool = toolName
        Task.detached(priority: .userInitiated) { [weak self] in
            let package = Self.brewPackage[toolName] ?? nil
            if let package {
                guard let brew = DependencyInstaller.brewPaths.first(where: {
                    FileManager.default.isExecutableFile(atPath: $0)
                }) else {
                    await MainActor.run { self?.upgradingTool = nil }
                    return
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: brew)
                process.arguments = ["upgrade", package]
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
                process.environment = env
                process.standardOutput = Pipe()
                process.standardError = Pipe()
                try? process.run()
                process.waitUntilExit()
            } else {
                // yt-dlp self-update
                let path = Self.resolve("yt-dlp") ?? "yt-dlp"
                Self.update(toolPath: path)
            }
            await MainActor.run {
                self?.upgradingTool = nil
                Task { await self?.check() }
            }
        }
    }

    func upgradeIfNeeded() {
        let last = Self.defaults.object(forKey: Self.lastUpgradeKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > Self.upgradeInterval else { return }
        guard let brew = DependencyInstaller.brewPaths.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return }
        Self.defaults.set(Date(), forKey: Self.lastUpgradeKey)
        Task.detached(priority: .background) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: brew)
            process.arguments = ["upgrade", "yt-dlp", "ffmpeg", "gallery-dl", "deno"]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            process.environment = env
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
            await MainActor.run { Task { await ToolChecker.shared.check() } }
        }
    }

    var ytdlpPath:    String { ytdlp.path    ?? "yt-dlp" }
    var galleryDlPath: String { galleryDl.path ?? "gallery-dl" }
    var ffmpegPath:   String { ffmpeg.path   ?? "ffmpeg" }
    var ffprobePath:  String {
        guard let p = ffmpeg.path else { return "ffprobe" }
        return URL(fileURLWithPath: p).deletingLastPathComponent().appendingPathComponent("ffprobe").path
    }
}
