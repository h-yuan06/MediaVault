import Foundation
import Combine

// MARK: - yt-dlp patterns
// "[download]  23.4% of  45.67MiB at  5.43MiB/s ETA 00:30"
private let ytProgressPattern = try! NSRegularExpression(
    pattern: #"\[download\]\s+([\d.]+)%\s+of\s+~?([\d.]+\S+)\s+at\s+([\d.]+\S+)\s+ETA\s+(\S+)"#
)
private let ytDestinationPattern = try! NSRegularExpression(
    pattern: #"\[download\] Destination: .+/(.+)$"#
)
private let ytMergePattern = try! NSRegularExpression(
    pattern: #"\[Merger\]|Merging formats"#
)
private let ytAlreadyPattern = try! NSRegularExpression(
    pattern: #"\[download\] .+ has already been downloaded"#
)

// MARK: - gallery-dl patterns
// "/path/to/file" — new file being downloaded
private let gdNewFilePattern = try! NSRegularExpression(
    pattern: #"^/.+"#
)
// "#/path/to/file" — file already in archive (skipped)
private let gdSkippedPattern = try! NSRegularExpression(
    pattern: #"^#/.+"#
)

@MainActor
class DownloadEngine: ObservableObject {
    static let shared: DownloadEngine = {
        MainActor.assumeIsolated { DownloadEngine() }
    }()

    @Published private(set) var queue: [DownloadItem] = []

    private let tools = ToolChecker.shared
    private var activeProcesses: [UUID: Process] = [:]

    private init() {}

    // MARK: - Public API

    func sync(source: FollowedSource, store: SourceStore) {
        guard let downloadDir = store.downloadDir(for: source),
              let archiveFile = store.archiveFile(for: source) else { return }

        store.markSyncStarted(source.id)
        let item = DownloadItem(sourceId: source.id, url: source.url, title: "Syncing \(source.name)…")
        queue.insert(item, at: 0)

        Task {
            await run(item: item, source: source, downloadDir: downloadDir, archiveFile: archiveFile, store: store)
        }
    }

    func pause(for sourceId: UUID) {
        queue
            .filter { $0.sourceId == sourceId && ($0.status == .downloading || $0.status == .merging || $0.status == .pending) }
            .forEach { item in
                activeProcesses[item.id]?.terminate()
                item.status = .paused
            }
    }

    func resume(for sourceId: UUID, store: SourceStore) {
        guard let item = queue.first(where: { $0.sourceId == sourceId && $0.status == .paused }),
              let source = store.sources.first(where: { $0.id == sourceId }),
              let downloadDir = store.downloadDir(for: source),
              let archiveFile = store.archiveFile(for: source) else { return }
        let countBeforePause = item.completedCount
        item.status = .downloading
        item.outputLog += "\n--- Resuming (\(countBeforePause) file\(countBeforePause == 1 ? "" : "s") downloaded before pause) ---\n"
        Task { await run(item: item, source: source, downloadDir: downloadDir, archiveFile: archiveFile, store: store) }
    }

    func cancelAll(for sourceId: UUID) {
        queue
            .filter { $0.sourceId == sourceId && $0.status.isActive }
            .forEach { item in
                activeProcesses[item.id]?.terminate()
            }
    }

    func clearFinished() {
        queue.removeAll { $0.status.isFinished }
    }

    // MARK: - Download execution

    private func run(
        item: DownloadItem,
        source: FollowedSource,
        downloadDir: URL,
        archiveFile: URL,
        store: SourceStore
    ) async {
        item.status = .downloading

        let useGalleryDl: Bool
        switch source.downloadTool {
        case .galleryDl: useGalleryDl = true
        case .ytdlp:     useGalleryDl = false
        case .auto:      useGalleryDl = source.sourceType == .reddit
        }
        let tool: String
        let args: [String]
        if useGalleryDl {
            tool = tools.galleryDlPath
            args = galleryDlArgs(source: source, downloadDir: downloadDir, archiveFile: archiveFile)
        } else {
            tool = tools.ytdlpPath
            args = ytdlpArgs(source: source, downloadDir: downloadDir, archiveFile: archiveFile, cookiesFile: store.cookiesFileURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args

        var env = ProcessInfo.processInfo.environment
        let homePath = env["HOME"] ?? NSHomeDirectory()
        let extraPaths = "\(homePath)/.deno/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = extraPaths + ":" + (env["PATH"] ?? "")
        // Force Python to flush output immediately instead of buffering to 4KB chunks
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env

        // Merge stdout + stderr so we catch progress lines regardless of which fd yt-dlp uses
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        activeProcesses[item.id] = process

        do {
            try process.run()
        } catch {
            item.status = .failed
            item.errorMessage = error.localizedDescription
            activeProcesses.removeValue(forKey: item.id)
            return
        }

        var newDownloads = 0
        var errorLines: [String] = []
        var logBuffer = ""
        var lastFlush = Date()
        let flushInterval: TimeInterval = 0.5
        let logMaxLength = 10_000
        var clearLogOnFlush = false

        // Staging variables — parsed off main actor, flushed to item every 0.5s
        var stagedProgress: Double = item.progress
        var stagedSpeed = item.speedDescription
        var stagedETA = item.etaDescription
        var stagedTotal = item.totalBytes
        var stagedFilename = item.currentFilename
        var stagedCount = item.completedCount
        var stagedStatus = item.status

        func flush() {
            if clearLogOnFlush {
                item.outputLog = logBuffer
                clearLogOnFlush = false
            } else {
                item.outputLog += logBuffer
                if item.outputLog.count > logMaxLength {
                    item.outputLog = String(item.outputLog.suffix(logMaxLength))
                }
            }
            item.progress = stagedProgress
            item.speedDescription = stagedSpeed
            item.etaDescription = stagedETA
            item.totalBytes = stagedTotal
            item.currentFilename = stagedFilename
            item.completedCount = stagedCount
            item.status = stagedStatus
            logBuffer = ""
            lastFlush = Date()
        }

        for await line in outputPipe.fileHandleForReading.lines() {
            if line.hasPrefix("ERROR:") { errorLines.append(line) }
            logBuffer += line + "\n"

            if useGalleryDl {
                parseGalleryDl(line: line, into: &stagedCount, filename: &stagedFilename, status: &stagedStatus, newDownloads: &newDownloads, clearLog: &clearLogOnFlush)
            } else {
                parseYtdlp(line: line, progress: &stagedProgress, total: &stagedTotal, speed: &stagedSpeed, eta: &stagedETA, filename: &stagedFilename, count: &stagedCount, status: &stagedStatus, newDownloads: &newDownloads, clearLog: &clearLogOnFlush)
            }

            if Date().timeIntervalSince(lastFlush) >= flushInterval {
                flush()
            }
        }
        flush()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }

        activeProcesses.removeValue(forKey: item.id)

        let exitCode = process.terminationStatus
        let isNonFatalExit = exitCode != 0 && newDownloads == 0 && item.status != .failed
        if exitCode == 0 || isNonFatalExit {
            let upToDate = newDownloads == 0
            item.status = .completed
            item.progress = 1.0
            item.speedDescription = ""
            item.etaDescription = ""
            item.errorMessage = nil
            item.title = upToDate
                ? "\(source.name) — up to date"
                : "\(source.name) — \(newDownloads) new file(s)"
            store.markChecked(source.id, downloadedCount: newDownloads, syncedToLatest: upToDate)
        } else if item.status != .failed {
            item.status = .failed
            item.errorMessage = errorLines.isEmpty
                ? "Process exited with code \(exitCode)"
                : errorLines.joined(separator: "\n")
            store.markChecked(source.id, downloadedCount: newDownloads, syncedToLatest: false)
        }
    }

    // MARK: - yt-dlp parser

    private func parseYtdlp(
        line: String,
        progress: inout Double, total: inout String, speed: inout String, eta: inout String,
        filename: inout String, count: inout Int, status: inout DownloadStatus,
        newDownloads: inout Int, clearLog: inout Bool
    ) {
        let ns = line as NSString
        let range = NSRange(line.startIndex..., in: line)

        if let match = ytProgressPattern.firstMatch(in: line, range: range) {
            progress = (Double(ns.substring(with: match.range(at: 1))) ?? 0) / 100.0
            total    = ns.substring(with: match.range(at: 2))
            speed    = ns.substring(with: match.range(at: 3))
            eta      = "ETA " + ns.substring(with: match.range(at: 4))
            status   = .downloading
            return
        }

        if ytMergePattern.firstMatch(in: line, range: range) != nil {
            newDownloads += 1
            count    = newDownloads
            status   = .merging
            progress = 0.99
            filename = ""
            clearLog = true
            return
        }

        if ytAlreadyPattern.firstMatch(in: line, range: range) == nil,
           line.contains("[download] Destination:") {
            progress = 0
            speed    = ""
            eta      = ""
            total    = ""
            if let match = ytDestinationPattern.firstMatch(in: line, range: range) {
                filename = ns.substring(with: match.range(at: 1))
            }
            let isSplitStream = line.range(of: #"\.[fF]\d+\."#, options: .regularExpression) != nil
            if !isSplitStream {
                newDownloads += 1
                count    = newDownloads
                clearLog = true
            }
        }
    }

    // MARK: - gallery-dl parser

    private func parseGalleryDl(
        line: String,
        into count: inout Int, filename: inout String, status: inout DownloadStatus,
        newDownloads: inout Int, clearLog: inout Bool
    ) {
        let range = NSRange(line.startIndex..., in: line)

        if gdNewFilePattern.firstMatch(in: line, range: range) != nil {
            newDownloads += 1
            count    = newDownloads
            filename = URL(fileURLWithPath: line.trimmingCharacters(in: .whitespaces)).lastPathComponent
            status   = .downloading
            clearLog = true
            return
        }

        if gdSkippedPattern.firstMatch(in: line, range: range) != nil {
            let path = String(line.dropFirst())
            filename = "↷ " + URL(fileURLWithPath: path).lastPathComponent
        }
    }

    // MARK: - Command builders

    private func ytdlpArgs(source: FollowedSource, downloadDir: URL, archiveFile: URL, cookiesFile: URL?) -> [String] {
        var args: [String] = []
        if let cookies = cookiesFile {
            args += ["--cookies", cookies.path]
        }
        args += [
            "-f", "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best",
            "--download-archive", archiveFile.path,
            "--output", downloadDir.path + "/%(uploader)s/%(title)s.%(ext)s",
            "--ffmpeg-location", tools.ffmpegPath,
            "--ignore-no-formats-error",
            "--newline",
            source.url
        ]
        return args
    }

    private func galleryDlArgs(source: FollowedSource, downloadDir: URL, archiveFile: URL) -> [String] {
        [
            "--download-archive", archiveFile.path,
            "--destination", downloadDir.path,
            "-o", "directory=[]",
            "--no-colors",
            source.url
        ]
    }
}

// MARK: - Async line reader

private final class LineBuffer: @unchecked Sendable {
    var data = Data()
    private let newline = Data([0x0A])

    func flush(into continuation: AsyncStream<String>.Continuation) {
        while let range = data.range(of: newline) {
            let lineData = data[..<range.lowerBound]
            data.removeSubrange(..<range.upperBound)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                continuation.yield(line)
            }
        }
    }
}

extension FileHandle {
    func lines() -> AsyncStream<String> {
        AsyncStream { continuation in
            let buffer = LineBuffer()
            readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    buffer.flush(into: continuation)
                    self.readabilityHandler = nil
                    continuation.finish()
                } else {
                    buffer.data.append(chunk)
                    buffer.flush(into: continuation)
                }
            }
        }
    }
}
