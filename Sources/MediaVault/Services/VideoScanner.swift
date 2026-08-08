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

    // Deterministic channel color from a UUID string
    private static let palette: [String] = [
        "#c0392b","#1a5276","#117a65","#6c3483","#1e8bc3",
        "#d68910","#7d6608","#1a6b4a","#2874a6","#922b21"
    ]
    static func color(for id: String) -> String {
        var hash = 5381
        for c in id.unicodeScalars { hash = ((hash << 5) &+ hash) &+ Int(c.value) }
        return palette[abs(hash) % palette.count]
    }

    @MainActor
    static func scan(store: SourceStore) -> (public: [MediaItem], private: [MediaItem]) {
        var pub: [MediaItem] = []
        var priv: [MediaItem] = []

        for source in store.sources {
            guard let dir = store.downloadDir(for: source) else { continue }
            let isPrivate = store.group(for: source)?.isPrivate ?? false
            let ch = source.name
            let chId = source.id.uuidString
            let chColor = color(for: chId)
            let items = scanDirectory(dir, channel: ch, channelId: chId, color: chColor, isPrivate: isPrivate)
            if isPrivate { priv.append(contentsOf: items) }
            else         { pub.append(contentsOf: items) }
        }
        return (pub, priv)
    }

    private static func scanDirectory(
        _ dir: URL,
        channel: String,
        channelId: String,
        color: String,
        isPrivate: Bool
    ) -> [MediaItem] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }

        var items: [MediaItem] = []

        for url in contents {
            let ext = url.pathExtension.lowercased()
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)

            if isDir.boolValue {
                // Check if it's an image album
                if let photos = albumPhotos(in: url), !photos.isEmpty {
                    let attrs = try? fm.attributesOfItem(atPath: url.path)
                    let totalSize = photos.reduce(Int64(0)) { $0 + $1.fileSize }
                    let createdAt = (attrs?[.creationDate] as? Date)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
                    let liked = LikeStore.isLiked(url)
                    let item = MediaItem(
                        type: "album",
                        id: deterministicID(for: url),
                        title: cleanTitle(url.lastPathComponent),
                        channel: channel,
                        channelId: channelId,
                        fileSize: totalSize,
                        downloadedAt: createdAt,
                        path: url.path + "/",
                        color: color,
                        isPrivate: isPrivate,
                        liked: liked,
                        photos: photos.map { p in
                            let pAttrs = try? fm.attributesOfItem(atPath: p.url.path)
                            let pCreated = (pAttrs?[.creationDate] as? Date)?.timeIntervalSince1970 ?? createdAt
                            return PhotoItem(
                                id: deterministicID(for: p.url),
                                path: p.url.path,
                                downloadedAt: pCreated,
                                liked: LikeStore.isLiked(p.url)
                            )
                        }
                    )
                    items.append(item)
                }
            } else if videoExts.contains(ext) {
                let attrs = try? fm.attributesOfItem(atPath: url.path)
                let size = (attrs?[.size] as? Int64) ?? 0
                let createdAt = (attrs?[.creationDate] as? Date)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
                let item = MediaItem(
                    type: "video",
                    id: deterministicID(for: url),
                    title: cleanTitle(url.deletingPathExtension().lastPathComponent),
                    channel: channel,
                    channelId: channelId,
                    fileSize: size,
                    downloadedAt: createdAt,
                    path: url.path,
                    color: color,
                    isPrivate: isPrivate,
                    liked: LikeStore.isLiked(url)
                )
                items.append(item)
            }
        }
        return items
    }

    private struct PhotoEntry {
        let url: URL
        let fileSize: Int64
    }

    private static func albumPhotos(in dir: URL) -> [PhotoEntry]? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return nil }
        let photos = contents.filter { imageExts.contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !photos.isEmpty else { return nil }
        return photos.map { url in
            let sz = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            return PhotoEntry(url: url, fileSize: sz)
        }
    }

    // Stable UUID-like ID from file path using simple hash
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
        // Strip yt-dlp ID suffix like [xXxXxXxXxXx]
        var s = raw
        if let range = s.range(of: #"\s*\[[A-Za-z0-9_\-]{6,12}\]$"#, options: .regularExpression) {
            s.removeSubrange(range)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
}
