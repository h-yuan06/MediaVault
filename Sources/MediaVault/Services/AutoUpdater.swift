import Foundation
import AppKit
import os.log

private let log = Logger(subsystem: "com.mediavault.app", category: "AutoUpdater")

// MARK: - Download delegate for progress reporting

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    var onProgress: (Double) -> Void = { _ in }
    var onComplete: (URL?, Error?) -> Void = { _, _ in }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite total: Int64) {
        guard total > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(total))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".zip")
        try? FileManager.default.moveItem(at: location, to: dest)
        onComplete(dest, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { onComplete(nil, error) }
    }
}

// MARK: - AutoUpdater

@MainActor
class AutoUpdater: ObservableObject {
    static let shared: AutoUpdater = {
        MainActor.assumeIsolated { AutoUpdater() }
    }()

    @Published var downloadProgress: Double? = nil  // nil = idle, 0–1 = downloading
    @Published var isCheckingForUpdates = false
    @Published var updateCheckResult: UpdateCheckResult? = nil

    enum UpdateCheckResult {
        case upToDate
        case updateAvailable(remoteBuild: Int)
        case failed(String)
    }

    private let releasesURL = URL(string: "https://api.github.com/repos/h-yuan06/MediaVault/releases/latest")!

    private init() {}

    var localBuild: Int? { localBuildNumber() }

    func checkAndInstall() {
        Task { await performUpdate() }
    }

    func checkForUpdatesOnly() {
        Task {
            isCheckingForUpdates = true
            updateCheckResult = nil
            defer { isCheckingForUpdates = false }

            guard let localBuild = localBuildNumber() else {
                updateCheckResult = .failed("Could not read local build number")
                return
            }
            do {
                var request = URLRequest(url: releasesURL)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, _) = try await URLSession.shared.data(for: request)
                guard
                    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let tagName = json["tag_name"] as? String,
                    let remoteBuild = Int(tagName)
                else {
                    updateCheckResult = .failed("Could not parse release response")
                    return
                }
                if remoteBuild > localBuild {
                    updateCheckResult = .updateAvailable(remoteBuild: remoteBuild)
                } else {
                    updateCheckResult = .upToDate
                }
            } catch {
                updateCheckResult = .failed(error.localizedDescription)
            }
        }
    }

    private func performUpdate() async {
        guard let localBuild = localBuildNumber() else {
            log.warning("Could not read local build number")
            return
        }
        log.info("Local build: \(localBuild) — checking for updates")

        do {
            var request = URLRequest(url: releasesURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: request)

            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let tagName = json["tag_name"] as? String,
                let remoteBuild = Int(tagName)
            else {
                log.warning("Could not parse release JSON")
                return
            }

            log.info("Remote build: \(remoteBuild)")
            guard remoteBuild > localBuild else { log.info("Already up to date"); return }

            guard
                let assets = json["assets"] as? [[String: Any]],
                let asset = assets.first(where: { ($0["name"] as? String) == "MediaVault.zip" }),
                let downloadString = asset["browser_download_url"] as? String,
                let downloadURL = URL(string: downloadString)
            else {
                log.error("Could not find MediaVault.zip asset in release")
                return
            }

            log.info("Downloading update from \(downloadString)")
            downloadProgress = 0
            let tempZip = try await downloadWithProgress(from: downloadURL)
            log.info("Download complete — installing")
            try installUpdate(from: tempZip)
        } catch {
            log.error("Update failed: \(error.localizedDescription)")
            downloadProgress = nil
        }
    }

    private func downloadWithProgress(from url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadDelegate()
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

            delegate.onProgress = { [weak self] fraction in
                Task { @MainActor [weak self] in self?.downloadProgress = fraction }
            }
            delegate.onComplete = { tempURL, error in
                session.invalidateAndCancel()
                if let error { continuation.resume(throwing: error) }
                else if let tempURL { continuation.resume(returning: tempURL) }
            }

            session.downloadTask(with: url).resume()
        }
    }

    private func localBuildNumber() -> Int? {
        guard let v = Bundle.main.infoDictionary?["CFBundleVersion"] as? String else { return nil }
        return Int(v)
    }

    private func installUpdate(from zipURL: URL) throws {
        let appPath = Bundle.main.bundlePath
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaVault_update_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", zipURL.path, "-d", tempDir.path]
        try unzip.run()
        unzip.waitUntilExit()

        let newAppPath = tempDir.appendingPathComponent("MediaVault.app").path
        let script = """
        #!/bin/bash
        sleep 1
        xattr -rd com.apple.quarantine '\(newAppPath)' 2>/dev/null || true
        rm -rf '\(appPath)'
        mv '\(newAppPath)' '\(appPath)'
        open '\(appPath)'
        """
        let scriptPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("mediavault_update.sh").path
        try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        launcher.arguments = ["-c", "nohup bash '\(scriptPath)' > /dev/null 2>&1 &"]
        try launcher.run()

        log.info("Relaunch script launched — quitting for update")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApplication.shared.terminate(nil)
        }
    }
}
