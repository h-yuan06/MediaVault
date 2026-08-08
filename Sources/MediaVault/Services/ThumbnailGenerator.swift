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

    private static func hasThumbnail(for videoURL: URL) -> Bool {
        let base = videoURL.deletingPathExtension()
        return thumbExts.contains { ext in
            FileManager.default.fileExists(atPath: base.appendingPathExtension(ext).path)
        }
    }

    private static func generateThumbnail(for videoURL: URL, ffmpegPath: String) async {
        let outputURL = videoURL.deletingPathExtension().appendingPathExtension("jpg")
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
