import Foundation

enum DownloadTool: String, Codable, CaseIterable {
    case auto
    case ytdlp
    case galleryDl

    var displayName: String {
        switch self {
        case .auto:      return "Auto"
        case .ytdlp:     return "yt-dlp"
        case .galleryDl: return "gallery-dl"
        }
    }
}

enum SourceType: String, Codable {
    case youtube
    case reddit
    case generic

    static func detect(from url: String) -> SourceType {
        let lower = url.lowercased()
        if lower.contains("youtube.com") || lower.contains("youtu.be") { return .youtube }
        if lower.contains("reddit.com") { return .reddit }
        return .generic
    }

    var displayName: String {
        switch self {
        case .youtube: return "YouTube"
        case .reddit: return "Reddit"
        case .generic: return "Web"
        }
    }

    var iconName: String {
        switch self {
        case .youtube: return "play.rectangle.fill"
        case .reddit: return "bubble.left.and.bubble.right.fill"
        case .generic: return "globe"
        }
    }
}

struct FollowedSource: Identifiable, Codable, Equatable {
    let id: UUID
    var url: String
    var name: String
    var sourceType: SourceType
    var addedDate: Date
    var lastChecked: Date?
    var downloadedCount: Int
    var bookmarkData: Data?
    var customDownloadPath: String?
    var isSyncedToLatest: Bool
    var downloadTool: DownloadTool

    init(url: String, name: String = "") {
        self.id = UUID()
        self.url = url
        self.name = name.isEmpty ? url : name
        self.sourceType = SourceType.detect(from: url)
        self.addedDate = Date()
        self.lastChecked = nil
        self.downloadedCount = 0
        self.bookmarkData = nil
        self.customDownloadPath = nil
        self.isSyncedToLatest = false
        self.downloadTool = .auto
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                = try c.decode(UUID.self, forKey: .id)
        url               = try c.decode(String.self, forKey: .url)
        name              = try c.decode(String.self, forKey: .name)
        sourceType        = try c.decode(SourceType.self, forKey: .sourceType)
        addedDate         = try c.decode(Date.self, forKey: .addedDate)
        lastChecked       = try c.decodeIfPresent(Date.self, forKey: .lastChecked)
        downloadedCount   = try c.decodeIfPresent(Int.self, forKey: .downloadedCount) ?? 0
        bookmarkData      = try c.decodeIfPresent(Data.self, forKey: .bookmarkData)
        customDownloadPath = try c.decodeIfPresent(String.self, forKey: .customDownloadPath)
        isSyncedToLatest  = try c.decodeIfPresent(Bool.self, forKey: .isSyncedToLatest) ?? false
        downloadTool      = try c.decodeIfPresent(DownloadTool.self, forKey: .downloadTool) ?? .auto
    }

    var archiveFileName: String {
        ".archive-\(id.uuidString)"
    }

    // Resolves to a URL for the custom destination, if one has been set.
    // Prefers a live security-scoped bookmark; falls back to the stored raw path
    // so the destination is remembered even when an external drive is unplugged.
    var customDownloadURL: URL? {
        if let data = bookmarkData {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                return url
            }
        }
        // Bookmark unavailable (drive unplugged, etc.) — return path so caller
        // still knows the intended destination.
        if let path = customDownloadPath {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}
