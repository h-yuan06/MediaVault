import SwiftUI
import AppKit

struct SourceDetailView: View {
    let source: FollowedSource
    @EnvironmentObject var store: SourceStore
    @EnvironmentObject var engine: DownloadEngine
    @EnvironmentObject var tools: ToolChecker
    @State private var isEditing = false
    @State private var editedName = ""
    @State private var editedURL = ""
    @State private var showingDuplicates = false
    @StateObject private var duplicateDetector = DuplicateDetector()

    private var sourceItems: [DownloadItem] {
        engine.queue.filter { $0.sourceId == source.id }
    }

    private var hasActive: Bool {
        sourceItems.contains { $0.status == .downloading || $0.status == .merging || $0.status == .pending }
    }

    private var hasPaused: Bool {
        sourceItems.contains { $0.status == .paused }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: source.sourceType.iconName)
                    .font(.system(size: 32))
                    .foregroundStyle(iconColor)

                VStack(alignment: .leading, spacing: 4) {
                    if isEditing {
                        TextField("Name", text: $editedName)
                            .textFieldStyle(.roundedBorder)
                        TextField("URL", text: $editedURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        Text(source.name)
                            .font(.title2.bold())
                        Text(source.url)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 12) {
                        if let lastChecked = source.lastChecked {
                            Label("Checked \(lastChecked, style: .relative) ago", systemImage: "clock")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Label("\(source.downloadedCount) downloaded", systemImage: "arrow.down.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    downloadFolderRow
                    downloadToolRow
                }

                Spacer()

                HStack {
                    if isEditing {
                        Button("Cancel") { isEditing = false }
                        Button("Save") { saveEdit() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button(action: { startEdit() }) {
                            Image(systemName: "pencil")
                        }

                        Button(action: { openInFinder() }) {
                            Image(systemName: "folder")
                        }
                        .help("Show in Finder")

                        if hasActive {
                            Button(action: { engine.pause(for: source.id, store: store) }) {
                                Label("Pause", systemImage: "pause.circle")
                            }
                            .buttonStyle(.bordered)
                        } else if hasPaused {
                            Button(action: { engine.resume(for: source.id, store: store) }) {
                                Label("Resume", systemImage: "play.circle.fill")
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button(action: { engine.sync(source: source, store: store) }) {
                                Label("Sync Now", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.borderedProminent)

                            Button(action: { detectRepeats() }) {
                                Label("Detect Repeats", systemImage: "doc.on.doc.fill")
                            }
                            .buttonStyle(.bordered)
                            .sheet(isPresented: $showingDuplicates) {
                                DuplicatesSheet(detector: duplicateDetector)
                            }
                        }
                    }
                }
            }
            .padding()
            .background(.regularMaterial)

            Divider()

            // Download list
            if sourceItems.isEmpty {
                emptyState
            } else {
                List(sourceItems) { item in
                    DownloadItemRow(item: item)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(source.name)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No downloads yet")
                .foregroundStyle(.secondary)
            Button("Sync Now") { engine.sync(source: source, store: store) }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var iconColor: Color {
        switch source.sourceType {
        case .youtube: return .red
        case .reddit: return .orange
        case .generic: return .blue
        }
    }

    private func startEdit() {
        editedName = source.name
        editedURL = source.url
        isEditing = true
    }

    private func saveEdit() {
        var updated = source
        updated.name = editedName
        updated.url = editedURL
        updated.sourceType = SourceType.detect(from: editedURL)
        store.update(updated)
        isEditing = false
    }

    private var downloadToolRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "wrench.and.screwdriver")
                .foregroundStyle(.secondary)
                .font(.caption)
            Text("Tool:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { source.downloadTool },
                set: { newTool in
                    var updated = source
                    updated.downloadTool = newTool
                    store.update(updated)
                }
            )) {
                ForEach(DownloadTool.allCases, id: \.self) { tool in
                    Text(tool.displayName).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }

    private var downloadFolderRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .foregroundStyle(source.customDownloadURL != nil ? Color.accentColor : .secondary)
                .font(.caption)
            if let custom = source.customDownloadURL {
                Text(custom.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Change…") { store.selectDownloadFolder(for: source) }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                Button("Reset") { store.clearCustomFolder(for: source) }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            } else if let root = store.downloadRootURL {
                Text(root.appendingPathComponent(source.name).path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Change…") { store.selectDownloadFolder(for: source) }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    private func openInFinder() {
        if let dir = store.downloadDir(for: source) {
            NSWorkspace.shared.open(dir)
        }
    }

    private func detectRepeats() {
        guard let dir = store.downloadDir(for: source) else { return }
        showingDuplicates = true
        Task {
            await duplicateDetector.scan(directory: dir, ffprobePath: tools.ffprobePath)
        }
    }
}

struct DownloadItemRow: View {
    @ObservedObject var item: DownloadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {

            // Top row: icon + source title + status badge
            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                    .frame(width: 16)
                Text(item.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer()
                statusBadge
            }

            if item.progress > 0 && (item.status == .downloading || item.status == .paused) {
                ProgressView(value: item.progress)
                    .progressViewStyle(.linear)
                    .tint(item.status == .paused ? .orange : .accentColor)
                    .padding(.leading, 24)
            }

            if item.status == .downloading || item.status == .merging || item.status == .paused {
                // Stats row
                HStack(spacing: 12) {
                    if item.completedCount > 0 {
                        Label("\(item.completedCount) done", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    if !item.currentFilename.isEmpty {
                        Text(item.currentFilename)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    if item.status == .merging {
                        Label("Merging…", systemImage: "gearshape.2")
                    }
                    if !item.speedDescription.isEmpty {
                        Text(item.speedDescription)
                    }
                    if !item.etaDescription.isEmpty {
                        Text(item.etaDescription)
                    }
                    if item.progress > 0 {
                        Text(String(format: "%.1f%%", item.progress * 100))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 24)
            }

            if (item.status.isActive && item.status != .paused) || !item.outputLog.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(item.outputLog)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                            .id("bottom")
                    }
                    .frame(height: 100)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator, lineWidth: 0.5))
                    .padding(.leading, 24)
                    .onChange(of: item.outputLog) { _ in
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }

            if let error = item.errorMessage, item.status == .failed {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .padding(.leading, 24)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusBadge: some View {
        Text(item.status.displayName)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor.opacity(0.15), in: Capsule())
            .foregroundStyle(statusColor)
    }

    private var statusIcon: String {
        switch item.status {
        case .pending: return "clock"
        case .downloading: return "arrow.down.circle"
        case .merging: return "gearshape.2"
        case .paused: return "pause.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .skipped: return "minus.circle"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .completed: return .green
        case .failed: return .red
        case .paused: return .orange
        case .downloading, .merging: return .accentColor
        default: return .secondary
        }
    }
}
