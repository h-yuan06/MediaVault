import Foundation

enum ThumbnailGenerator {
    private static let videoExts: Set<String> = ["mp4","mkv","webm","mov","m4v","avi"]
    private static let thumbExts = ["jpg","jpeg","webp","png"]

    /// Generate .jpg thumbnails for every video in `dir` that lacks a sidecar image.
    /// Runs up to `concurrency` ffmpeg processes in parallel; fires-and-forgets safely.
    static func generateMissing(in dir: URL, ffmpegPath: String, concurrency: Int = 3) async {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var targets: [URL] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  videoExts.contains(url.pathExtension.lowercased()),
                  !hasThumbnail(for: url) else { continue }
            targets.append(url)
        }
        guard !targets.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            var active = 0
            for url in targets {
                if active >= concurrency {
                    await group.next()
                    active -= 1
                }
                group.addTask { await generateThumbnail(for: url, ffmpegPath: ffmpegPath) }
                active += 1
            }
        }
    }

    /// Delete any existing thumbnail for `videoURL` and generate a fresh one at a new random frame.
    /// Returns the path of the new thumbnail, or nil if ffmpeg failed.
    static func regenerate(for videoURL: URL, ffmpegPath: String) async -> String? {
        let stem      = videoURL.deletingPathExtension().lastPathComponent
        let hiddenDir = videoURL.deletingLastPathComponent().appendingPathComponent(".thumbnails")
        let outputURL = hiddenDir.appendingPathComponent(stem).appendingPathExtension("jpg")
        // Delete all existing thumbnails for this video (all extensions, both locations)
        let dir = videoURL.deletingLastPathComponent()
        for folder in [hiddenDir, dir] {
            for ext in thumbExts {
                let c = folder.appendingPathComponent(stem).appendingPathExtension(ext)
                try? FileManager.default.removeItem(at: c)
            }
        }
        await generateThumbnail(for: videoURL, ffmpegPath: ffmpegPath)
        return FileManager.default.fileExists(atPath: outputURL.path) ? outputURL.path : nil
    }

    private static func hasThumbnail(for videoURL: URL) -> Bool {
        let stem = videoURL.deletingPathExtension().lastPathComponent
        let dir  = videoURL.deletingLastPathComponent()
        let hiddenDir = dir.appendingPathComponent(".thumbnails")
        return thumbExts.contains { ext in
            FileManager.default.fileExists(atPath: hiddenDir.appendingPathComponent(stem).appendingPathExtension(ext).path) ||
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(stem).appendingPathExtension(ext).path)
        }
    }

    private static func generateThumbnail(for videoURL: URL, ffmpegPath: String) async {
        let thumbDir = videoURL.deletingLastPathComponent().appendingPathComponent(".thumbnails")
        try? FileManager.default.createDirectory(at: thumbDir, withIntermediateDirectories: true)
        let outputURL = thumbDir
            .appendingPathComponent(videoURL.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("jpg")
        // Seek to a random offset (10–60 s) before opening the file — fast keyframe seek.
        // ffmpeg handles seeks past EOF gracefully by using the last available frame.
        let seekSecs = Int.random(in: 10...60)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = [
            "-ss", "\(seekSecs)",
            "-i", videoURL.path,
            "-frames:v", "1",
            "-vf", "scale=480:-1",
            "-q:v", "3",
            "-y",
            outputURL.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError  = FileHandle.nullDevice
        try? process.run()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in cont.resume() }
        }
    }
}
