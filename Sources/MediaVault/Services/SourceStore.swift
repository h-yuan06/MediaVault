import Foundation
import AppKit

@MainActor
class SourceStore: ObservableObject {
    static let shared: SourceStore = {
        MainActor.assumeIsolated { SourceStore() }
    }()

    @Published private(set) var sources: [FollowedSource] = []
    @Published private(set) var groups: [SourceGroup] = []
    @Published var downloadRootURL: URL?
    @Published var cookiesFileURL: URL?

    private let appSupport: URL
    private let sourcesFile: URL
    private let groupsFile: URL
    private let bookmarkKey = "downloadRootBookmark"
    private let cookiesBookmarkKey = "cookiesFileBookmark"

    private init() {
        let fm = FileManager.default
        appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MediaVault", isDirectory: true)
        sourcesFile = appSupport.appendingPathComponent("sources.json")
        groupsFile = appSupport.appendingPathComponent("groups.json")
        try? fm.createDirectory(at: appSupport, withIntermediateDirectories: true)

        restoreDownloadRoot()
        restoreCookiesFile()
        load()
    }

    // MARK: - Download root

    func selectDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose Download Folder"
        panel.message = "MediaVault will save all downloaded media here."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setDownloadRoot(url)
    }

    private func setDownloadRoot(_ url: URL) {
        downloadRootURL = url
        let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
    }

    private func restoreDownloadRoot() {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var stale = false
        let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        if let url {
            _ = url.startAccessingSecurityScopedResource()
            downloadRootURL = url
            if stale { setDownloadRoot(url) }
        }
    }

    // MARK: - Cookies file

    func selectCookiesFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.init(filenameExtension: "txt")!]
        panel.prompt = "Import Cookies"
        panel.message = "Select a Netscape-format cookies.txt file exported from your browser."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmark, forKey: cookiesBookmarkKey)
        cookiesFileURL = url
    }

    func clearCookiesFile() {
        UserDefaults.standard.removeObject(forKey: cookiesBookmarkKey)
        cookiesFileURL = nil
    }

    private func restoreCookiesFile() {
        guard let bookmark = UserDefaults.standard.data(forKey: cookiesBookmarkKey) else { return }
        var stale = false
        let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        if let url {
            _ = url.startAccessingSecurityScopedResource()
            cookiesFileURL = url
            if stale {
                let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(fresh, forKey: cookiesBookmarkKey)
            }
        }
    }

    func archiveFile(for source: FollowedSource) -> URL? {
        guard let dir = downloadDir(for: source) else { return nil }
        let archiveURL = dir.appendingPathComponent(source.archiveFileName)

        // Migrate: if old archive exists in the root but not in the source folder, move it
        if let root = downloadRootURL {
            let oldURL = root.appendingPathComponent(source.archiveFileName)
            if FileManager.default.fileExists(atPath: oldURL.path),
               !FileManager.default.fileExists(atPath: archiveURL.path) {
                try? FileManager.default.moveItem(at: oldURL, to: archiveURL)
            }
        }

        return archiveURL
    }

    func downloadDir(for source: FollowedSource) -> URL? {
        // Use custom per-source folder if set, otherwise fall back to root/name
        if let custom = source.customDownloadURL {
            _ = custom.startAccessingSecurityScopedResource()
            try? FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
            return custom
        }
        guard let root = downloadRootURL else { return nil }
        let dir = root.appendingPathComponent(source.name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func selectDownloadFolder(for source: FollowedSource) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose Folder"
        panel.message = "Downloads for \(source.name) will be saved here."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var updated = source
        applyCustomFolder(url: url, to: &updated)
        update(updated)
    }

    func clearCustomFolder(for source: FollowedSource) {
        var updated = source
        updated.bookmarkData = nil
        updated.customDownloadPath = nil
        update(updated)
    }

    /// Applies a chosen folder URL to a source value, saving both the security-scoped
    /// bookmark (for live access) and the raw path (so the destination survives drive removal).
    func applyCustomFolder(url: URL, to source: inout FollowedSource) {
        source.bookmarkData = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        source.customDownloadPath = url.path
    }

    // MARK: - Group CRUD

    func addGroup(name: String) {
        groups.append(SourceGroup(name: name))
        saveGroups()
    }

    func renameGroup(_ group: SourceGroup, to name: String) {
        guard let idx = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[idx].name = name
        saveGroups()
    }

    func removeGroup(_ group: SourceGroup) {
        groups.removeAll { $0.id == group.id }
        saveGroups()
    }

    func setPrivate(_ isPrivate: Bool, for group: SourceGroup) {
        guard let idx = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[idx].isPrivate = isPrivate
        saveGroups()
    }

    func moveSource(_ source: FollowedSource, toGroup group: SourceGroup?) {
        // Remove from all groups first
        for idx in groups.indices {
            groups[idx].sourceIds.removeAll { $0 == source.id }
        }
        // Add to new group if specified
        if let group, let idx = groups.firstIndex(where: { $0.id == group.id }) {
            groups[idx].sourceIds.append(source.id)
        }
        saveGroups()
    }

    func group(for source: FollowedSource) -> SourceGroup? {
        groups.first { $0.sourceIds.contains(source.id) }
    }

    var ungroupedSources: [FollowedSource] {
        let grouped = Set(groups.flatMap { $0.sourceIds })
        return sources.filter { !grouped.contains($0.id) }
    }

    func sources(in group: SourceGroup) -> [FollowedSource] {
        group.sourceIds.compactMap { id in sources.first { $0.id == id } }
    }

    // MARK: - CRUD

    func add(url: String, name: String, customFolder: URL? = nil) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sources.contains(where: { $0.url == trimmed }) else { return }
        var source = FollowedSource(url: trimmed, name: name)
        if let folder = customFolder {
            applyCustomFolder(url: folder, to: &source)
        }
        sources.append(source)
        save()
    }

    func remove(_ source: FollowedSource) {
        sources.removeAll { $0.id == source.id }
        save()
    }

    func update(_ source: FollowedSource) {
        if let idx = sources.firstIndex(where: { $0.id == source.id }) {
            sources[idx] = source
            save()
        }
    }

    func markSyncStarted(_ sourceId: UUID) {
        if let idx = sources.firstIndex(where: { $0.id == sourceId }) {
            sources[idx].isSyncedToLatest = false
            save()
        }
    }

    func markChecked(_ sourceId: UUID, downloadedCount: Int, syncedToLatest: Bool) {
        if let idx = sources.firstIndex(where: { $0.id == sourceId }) {
            sources[idx].lastChecked = Date()
            sources[idx].downloadedCount += downloadedCount
            if syncedToLatest { sources[idx].isSyncedToLatest = true }
            save()
        }
    }

    // MARK: - Persistence

    private func load() {
        if let data = try? Data(contentsOf: sourcesFile) {
            sources = (try? JSONDecoder().decode([FollowedSource].self, from: data)) ?? []
        }
        if let data = try? Data(contentsOf: groupsFile) {
            groups = (try? JSONDecoder().decode([SourceGroup].self, from: data)) ?? []
        }
    }

    private func save() {
        let data = try? JSONEncoder().encode(sources)
        try? data?.write(to: sourcesFile, options: .atomic)
    }

    private func saveGroups() {
        let data = try? JSONEncoder().encode(groups)
        try? data?.write(to: groupsFile, options: .atomic)
    }
}
