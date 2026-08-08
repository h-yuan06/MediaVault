import Foundation

struct MediaItem: Encodable {
    let type: String       // "video" | "album"
    let id: String
    let title: String
    let channel: String
    let channelId: String
    let fileSize: Int64
    let downloadedAt: Double
    let path: String
    let thumbnailPath: String?  // yt-dlp sidecar thumbnail if present
    let color: String
    let isPrivate: Bool
    let liked: Bool
    var photos: [PhotoItem]?
}

struct PhotoItem: Encodable {
    let id: String
    let path: String
    let downloadedAt: Double
    let liked: Bool
}

enum VideoScanner {
    private static let videoExts: Set<String> = ["mp4","mkv","webm","mov","m4v","avi"]
    private static let imageExts: Set<String> = ["jpg","jpeg","png","gif","webp","heic"]
    private static let thumbExts = ["jpg","jpeg","webp","png"]

    private static let palette: [String] = [
        "#c0392b","#1a5276","#117a65","#6c3483","#1e8bc3",
        "#d68910","#7d6608","#1a6b4a","#2874a6","#922b21"
    ]
    static func color(for id: String) -> String {
        var hash = 5381
        for c in id.unicodeScalars { hash = ((hash << 5) &+ hash) &+ Int(c.value) }
        return palette[abs(hash) % palette.count]
    }

    // Called from Task.detached — no main-actor access, no async I/O
    static func scan(
        sources: [(source: FollowedSource, dir: URL, isPrivate: Bool)]
    ) -> (public: [MediaItem], private: [MediaItem]) {
        var pub: [MediaItem] = []
        var priv: [MediaItem] = []
        for entry in sources {
            let items = scanDirectory(
                entry.dir,
                channel: entry.source.name,
                channelId: entry.source.id.uuidString,
                color: color(for: entry.source.id.uuidString),
                isPrivate: entry.isPrivate
            )
            if entry.isPrivate { priv.append(contentsOf: items) }
            else               { pub.append(contentsOf: items) }
        }
        return (pub, priv)
    }

    private static func scanDirectory(
        _ root: URL,
        channel: String,
        channelId: String,
        color: String,
        isPrivate: Bool
    ) -> [MediaItem] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey, .isDirectoryKey, .isRegularFileKey]
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var videoFiles: [URL] = []
        var imagesByDir: [URL: [URL]] = [:]

        for case let url as URL in enumerator {
            guard let rv = try? url.resourceValues(forKeys: Set(keys)),
                  rv.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            if videoExts.contains(ext) {
                videoFiles.append(url)
            } else if imageExts.contains(ext) {
                let dir = url.deletingLastPathComponent()
                imagesByDir[dir, default: []].append(url)
            }
        }

        var items: [MediaItem] = []

        for url in videoFiles {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? Int64) ?? 0
            let createdAt = (attrs?[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0
            items.append(MediaItem(
                type: "video",
                id: deterministicID(for: url),
                title: cleanTitle(url.deletingPathExtension().lastPathComponent),
                channel: channel,
                channelId: channelId,
                fileSize: size,
                downloadedAt: createdAt,
                path: url.path,
                thumbnailPath: findThumbnail(for: url),
                color: color,
                isPrivate: isPrivate,
                liked: LikeStore.isLiked(url)
            ))
        }

        for (dir, images) in imagesByDir {
            let sorted = images.sorted { $0.lastPathComponent < $1.lastPathComponent }
            let totalSize = sorted.reduce(Int64(0)) { sum, u in
                sum + ((try? fm.attributesOfItem(atPath: u.path)[.size] as? Int64) ?? 0)
            }
            let dirAttrs = try? fm.attributesOfItem(atPath: dir.path)
            let createdAt = (dirAttrs?[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let photos = sorted.map { u -> PhotoItem in
                let pAttrs = try? fm.attributesOfItem(atPath: u.path)
                let pCreated = (pAttrs?[.creationDate] as? Date)?.timeIntervalSince1970 ?? createdAt
                return PhotoItem(
                    id: deterministicID(for: u),
                    path: u.path,
                    downloadedAt: pCreated,
                    liked: LikeStore.isLiked(u)
                )
            }
            items.append(MediaItem(
                type: "album",
                id: deterministicID(for: dir),
                title: cleanTitle(dir.lastPathComponent),
                channel: channel,
                channelId: channelId,
                fileSize: totalSize,
                downloadedAt: createdAt,
                path: dir.path + "/",
                thumbnailPath: nil,
                color: color,
                isPrivate: isPrivate,
                liked: LikeStore.isLiked(dir),
                photos: photos
            ))
        }

        return items
    }

    private static func findThumbnail(for videoURL: URL) -> String? {
        let base = videoURL.deletingPathExtension()
        for ext in thumbExts {
            let candidate = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
        }
        return nil
    }

    private static func deterministicID(for url: URL) -> String {
        var hash = UInt64(14695981039346656037)
        for byte in url.path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        let h = String(format: "%016llx", hash)
        return "\(h.prefix(8))-\(h.dropFirst(8).prefix(4))-\(h.dropFirst(12).prefix(4))-\(h.dropFirst(8).prefix(4))-\(h.suffix(12))"
    }

    private static func cleanTitle(_ raw: String) -> String {
        var s = raw
        if let range = s.range(of: #"\s*\[[A-Za-z0-9_\-]{6,12}\]$"#, options: .regularExpression) {
            s.removeSubrange(range)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
}
