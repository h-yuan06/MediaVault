import Foundation
import AppKit
import os.log

private let log = Logger(subsystem: "com.mediavault.app", category: "AutoUpdater")

@MainActor
class AutoUpdater {
    static let shared: AutoUpdater = {
        MainActor.assumeIsolated { AutoUpdater() }
    }()

    private let releasesURL = URL(string: "https://api.github.com/repos/h-yuan06/MediaVault/releases/latest")!

    private init() {}

    func checkAndInstall() {
        Task { await performUpdate() }
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

            guard remoteBuild > localBuild else {
                log.info("Already up to date")
                return
            }

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
            let (tempZip, _) = try await URLSession.shared.download(from: downloadURL)
            log.info("Download complete — installing")
            try installUpdate(from: tempZip)
        } catch {
            log.error("Update failed: \(error.localizedDescription)")
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

        // Unzip the downloaded bundle
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", zipURL.path, "-d", tempDir.path]
        try unzip.run()
        unzip.waitUntilExit()

        let newAppPath = tempDir.appendingPathComponent("MediaVault.app").path

        // Shell script: wait for us to quit, strip quarantine, move new app in, relaunch
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

        // Launch script detached so it survives our process terminating
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
