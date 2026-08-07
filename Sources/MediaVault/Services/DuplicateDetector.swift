import Foundation
import AppKit
import CryptoKit

struct DuplicateGroup: Identifiable {
    let id = UUID()
    let files: [URL]
}

@MainActor
class DuplicateDetector: ObservableObject {
    @Published var isScanning = false
    @Published var progress = ""
    @Published var groups: [DuplicateGroup] = []

    func scan(directory: URL, ffprobePath: String) async {
        isScanning = true
        progress = "Scanning files…"
        groups = []

        let found = await Task.detached(priority: .utility) {
            DuplicateScanner.findDuplicates(in: directory, ffprobePath: ffprobePath)
        }.value

        groups = found
        progress = found.isEmpty ? "No duplicates found." : "\(found.count) duplicate group(s) found."
        isScanning = false
    }

    func delete(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        groups = groups.compactMap { group in
            let remaining = group.files.filter { $0 != url }
            return remaining.count >= 2 ? DuplicateGroup(files: remaining) : nil
        }
    }

    func keepOneFromAll() {
        for group in groups {
            // Keep the file with the earliest creation date; trash the rest
            let sorted = group.files.sorted {
                let d0 = (try? FileManager.default.attributesOfItem(atPath: $0.path)[.creationDate] as? Date) ?? .distantFuture
                let d1 = (try? FileManager.default.attributesOfItem(atPath: $1.path)[.creationDate] as? Date) ?? .distantFuture
                return d0 < d1
            }
            for url in sorted.dropFirst() {
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
        }
        groups = []
        progress = "Done — kept one copy of each duplicate group."
    }
}

// Pure value type — no actor isolation, safe to call from any context.
private enum DuplicateScanner {
    static let videoExtensions: Set<String> = ["mp4", "mkv", "webm", "mov", "avi", "m4v", "flv"]
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "tiff", "heic"]

    static func findDuplicates(in directory: URL, ffprobePath: String) -> [DuplicateGroup] {
        let all = allMediaFiles(in: directory)
        let videos = all.filter { videoExtensions.contains($0.pathExtension.lowercased()) }
        let images = all.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
        return detectVideoDuplicates(videos, ffprobePath: ffprobePath)
             + detectImageDuplicates(images)
    }

    // MARK: Videos

    static func detectVideoDuplicates(_ files: [URL], ffprobePath: String) -> [DuplicateGroup] {
        guard files.count > 1 else { return [] }
        var byDuration: [Int: [URL]] = [:]
        for file in files {
            byDuration[videoDuration(file, ffprobePath: ffprobePath), default: []].append(file)
        }
        return byDuration.values
            .filter { $0.count > 1 }
            .flatMap { hashGroup($0) }
    }

    static func videoDuration(_ url: URL, ffprobePath: String) -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobePath)
        process.arguments = [
            "-v", "quiet",
            "-of", "default=noprint_wrappers=1:nokey=1",
            "-show_entries", "format=duration",
            url.path
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
        return Int(Double(raw) ?? 0)
    }

    // MARK: Images

    static func detectImageDuplicates(_ files: [URL]) -> [DuplicateGroup] {
        guard files.count > 1 else { return [] }
        var bySize: [Int: [URL]] = [:]
        for file in files {
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            bySize[size, default: []].append(file)
        }
        var byDimensions: [[URL]] = []
        for candidates in bySize.values where candidates.count > 1 {
            var byRes: [String: [URL]] = [:]
            for file in candidates {
                byRes[imageResolutionKey(file), default: []].append(file)
            }
            byDimensions += byRes.values.filter { $0.count > 1 }
        }
        return byDimensions.flatMap { hashGroup($0) }
    }

    static func imageResolutionKey(_ url: URL) -> String {
        guard let img = NSImage(contentsOf: url),
              let rep = img.representations.first else { return "unknown" }
        return "\(rep.pixelsWide)x\(rep.pixelsHigh)"
    }

    // MARK: Hashing

    static func hashGroup(_ files: [URL]) -> [DuplicateGroup] {
        var byHash: [String: [URL]] = [:]
        for file in files {
            if let hash = sha256(file) {
                byHash[hash, default: []].append(file)
            }
        }
        return byHash.values
            .filter { $0.count > 1 }
            .map { DuplicateGroup(files: $0) }
    }

    static func sha256(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 4 * 1024 * 1024
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: File enumeration

    static func allMediaFiles(in directory: URL) -> [URL] {
        let all = videoExtensions.union(imageExtensions)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            && all.contains($0.pathExtension.lowercased())
        }
    }
}
