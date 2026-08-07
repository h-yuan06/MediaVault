import SwiftUI
import LocalAuthentication

struct ContentView: View {
    @EnvironmentObject var store: SourceStore
    @EnvironmentObject var engine: DownloadEngine
    @EnvironmentObject var scheduler: Scheduler
    @EnvironmentObject var tools: ToolChecker
    @EnvironmentObject var updater: AutoUpdater

    @State private var selectedSourceIds: Set<UUID> = []
    @State private var showingAddSheet = false
    @State private var showingToolAlert = false
    @State private var renamingGroup: SourceGroup? = nil
    @State private var newGroupName = ""
    @State private var privateUnlocked = false
    @State private var expandedGroups: Set<UUID> = []
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            if let progress = updater.downloadProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .frame(height: 3)
                    .animation(.linear, value: progress)
            }
            Group {
                if store.downloadRootURL == nil {
                    folderPickerPrompt
                } else if !tools.allAvailable {
                    toolsSetupView
                } else {
                    mainLayout
                }
            }
            .onAppear {
                Task { await tools.check() }
            }
        } // VStack
    }

    // MARK: - Main layout

    private var mainLayout: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if selectedSourceIds.count == 1,
               let id = selectedSourceIds.first,
               let source = store.sources.first(where: { $0.id == id }) {
                SourceDetailView(source: source)
                    .environmentObject(store)
                    .environmentObject(engine)
                    .environmentObject(tools)
            } else if selectedSourceIds.count > 1 {
                multiSelectionPlaceholder
            } else {
                downloadQueueFallback
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selectedSourceIds) {
                // Groups
                ForEach(store.groups.filter { !$0.isPrivate || privateUnlocked }) { group in
                    Section(isExpanded: isExpanded(group)) {
                        ForEach(store.sources(in: group)) { source in
                            sourceRow(source)
                        }
                    } header: {
                        HStack {
                            Image(systemName: "chevron.right")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                                .rotationEffect(expandedGroups.contains(group.id) ? .degrees(90) : .zero)
                                .animation(.easeInOut(duration: 0.2), value: expandedGroups.contains(group.id))
                                .onTapGesture { isExpanded(group).wrappedValue.toggle() }
                            if group.isPrivate {
                                Image(systemName: "lock.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(group.name).font(.caption.bold())
                            Spacer()
                        }
                        .contextMenu {
                            Button("Rename…") { beginRename(group) }
                            if group.isPrivate {
                                Button("Remove Lock") { store.setPrivate(false, for: group) }
                            } else {
                                Button("Make Private…") { store.setPrivate(true, for: group) }
                            }
                            Divider()
                            Button("Delete Group", role: .destructive) {
                                store.removeGroup(group)
                            }
                        }
                    }
                }

                // Ungrouped sources
                if !store.ungroupedSources.isEmpty {
                    if !store.groups.isEmpty {
                        Section("Ungrouped") {
                            ForEach(store.ungroupedSources) { source in
                                sourceRow(source)
                            }
                        }
                    } else {
                        ForEach(store.ungroupedSources) { source in
                            sourceRow(source)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .onDeleteCommand(perform: deleteSelected)

            // Hidden button captures ⌘⌫ when the list has focus
            Button("") { deleteSelected() }
                .keyboardShortcut(.delete, modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)

            Divider()
            sidebarToolbar
        }
        .navigationTitle("MediaVault")
        .onAppear {
            expandedGroups = Set(store.groups.map { $0.id })
        }
        .onChange(of: store.groups) { groups in
            // Auto-expand any newly added group
            for group in groups where !expandedGroups.contains(group.id) {
                expandedGroups.insert(group.id)
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active { privateUnlocked = false }
        }
        .alert("Rename Group", isPresented: Binding(
            get: { renamingGroup != nil },
            set: { if !$0 { renamingGroup = nil } }
        )) {
            TextField("Group name", text: $newGroupName)
            Button("Rename") {
                if let g = renamingGroup, !newGroupName.isEmpty {
                    store.renameGroup(g, to: newGroupName)
                }
                renamingGroup = nil
            }
            Button("Cancel", role: .cancel) { renamingGroup = nil }
        }
    }

    @ViewBuilder
    private func sourceRow(_ source: FollowedSource) -> some View {
        SourceRowView(source: source)
            .tag(source.id)
            .contextMenu {
                Button("Sync Now") { engine.sync(source: source, store: store) }

                Menu("Move to Group") {
                    ForEach(store.groups.filter { !$0.isPrivate || privateUnlocked }) { group in
                        Button(group.name) { moveSelected(source, toGroup: group) }
                    }
                    if store.group(for: source) != nil {
                        Divider()
                        Button("Remove from Group") { moveSelected(source, toGroup: nil) }
                    }
                    Divider()
                    Button("New Group…") {
                        store.addGroup(name: "New Group")
                        if let last = store.groups.last {
                            moveSelected(source, toGroup: last)
                            beginRename(last)
                        }
                    }
                }

                Divider()
                Button(selectedSourceIds.contains(source.id) && selectedSourceIds.count > 1
                       ? "Remove \(selectedSourceIds.count) Channels"
                       : "Remove",
                       role: .destructive) {
                    if selectedSourceIds.contains(source.id) && selectedSourceIds.count > 1 {
                        deleteSelected()
                    } else {
                        engine.cancelAll(for: source.id)
                        store.remove(source)
                    }
                }
            }
    }

    private func isExpanded(_ group: SourceGroup) -> Binding<Bool> {
        Binding(
            get: { expandedGroups.contains(group.id) },
            set: { expanded in
                if expanded { expandedGroups.insert(group.id) }
                else { expandedGroups.remove(group.id) }
            }
        )
    }

    private func moveSelected(_ tappedSource: FollowedSource, toGroup group: SourceGroup?) {
        let ids = selectedSourceIds.contains(tappedSource.id) && selectedSourceIds.count > 1
            ? selectedSourceIds
            : [tappedSource.id]
        for id in ids {
            if let source = store.sources.first(where: { $0.id == id }) {
                store.moveSource(source, toGroup: group)
            }
        }
    }

    private func deleteSelected() {
        guard !selectedSourceIds.isEmpty else { return }
        for id in selectedSourceIds {
            if let source = store.sources.first(where: { $0.id == id }) {
                engine.cancelAll(for: source.id)
                store.remove(source)
            }
        }
        selectedSourceIds = []
    }

    private var multiSelectionPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("\(selectedSourceIds.count) channels selected")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Press ⌘⌫ to remove them")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func beginRename(_ group: SourceGroup) {
        newGroupName = group.name
        renamingGroup = group
    }

    private func togglePrivate() {
        if privateUnlocked {
            privateUnlocked = false
        } else {
            Task { privateUnlocked = await authenticate() }
        }
    }

    private func authenticate() async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return true }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your private groups")
        } catch {
            return false
        }
    }

    private var sidebarToolbar: some View {
        HStack {
            Button(action: { showingAddSheet = true }) {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.plain)
            .padding(8)
            .help("Add a new channel")

            Button(action: { store.addGroup(name: "New Group"); if let g = store.groups.last { beginRename(g) } }) {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.plain)
            .padding(.leading, 4)
            .help("New group")

            Spacer()

            Menu {
                if store.cookiesFileURL != nil {
                    Button("Change cookies.txt…") { store.selectCookiesFile() }
                    Button("Clear Cookies", role: .destructive) { store.clearCookiesFile() }
                } else {
                    Button("Import cookies.txt…") { store.selectCookiesFile() }
                }
            } label: {
                Image(systemName: store.cookiesFileURL != nil ? "key.fill" : "key")
                    .foregroundStyle(store.cookiesFileURL != nil ? .secondary : Color.orange)
                
                
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.trailing, 4)
            .help(store.cookiesFileURL != nil ? "Cookies imported" : "No cookies — YouTube downloads may fail")

            if store.groups.contains(where: { $0.isPrivate }) {
                Button(action: togglePrivate) {
                    Image(systemName: privateUnlocked ? "lock.open.fill" : "lock.fill")
                        .foregroundStyle(privateUnlocked ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
                .help(privateUnlocked ? "Lock private groups" : "Unlock private groups")
            }

            if scheduler.isRunning {
                ProgressView().scaleEffect(0.6)
                    .padding(.trailing, 8)
            } else {
                Button(action: { scheduler.checkNow() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                .help("Check all sources for new content")
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddSourceSheet()
                .environmentObject(store)
                .environmentObject(engine)
        }
    }

    private var downloadQueueFallback: some View {
        DownloadQueueView()
            .environmentObject(engine)
    }

    // MARK: - Onboarding screens

    private var folderPickerPrompt: some View {
        VStack(spacing: 20) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("Choose a Download Folder")
                .font(.title2.bold())
            Text("MediaVault will save all downloaded media here.\nYou can change this later in Settings.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Choose Folder…") {
                store.selectDownloadFolder()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var toolsSetupView: some View {
        VStack(spacing: 24) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text("Install Required Tools")
                .font(.title2.bold())
            Text("Open Terminal and run the commands below for any missing tools.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                toolRow(status: tools.ytdlp,
                        command: "pip install yt-dlp",
                        note: "or: brew install yt-dlp")
                toolRow(status: tools.ffmpeg,
                        command: "brew install ffmpeg")
                toolRow(status: tools.deno,
                        command: "curl -fsSL https://deno.land/install.sh | sh")
                toolRow(status: tools.galleryDl,
                        command: "pip install gallery-dl",
                        note: "optional — for Reddit")
            }
            .padding()
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

            cookiesRow

            Button(action: { Task { await tools.check() } }) {
                if tools.isChecking {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8)
                        Text("Checking…")
                    }
                } else {
                    Text("Re-check Tools")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(tools.isChecking)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var cookiesRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: store.cookiesFileURL != nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(store.cookiesFileURL != nil ? .green : .orange)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Browser Cookies")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                if let url = store.cookiesFileURL {
                    Text(url.lastPathComponent)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Change…") { store.selectCookiesFile() }
                        .font(.caption2)
                } else {
                    Text("Required for YouTube downloads")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("Export cookies.txt from your browser using an extension like \"Get cookies.txt LOCALLY\", then import it here.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("Import cookies.txt…") { store.selectCookiesFile() }
                        .font(.caption)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(.top, 2)
                }
            }
        }
    }

    private func toolRow(status: ToolStatus, command: String, note: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: status.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(status.isAvailable ? .green : .red)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.name)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                if !status.isAvailable {
                    Text(command)
                        .font(.system(.caption, design: .monospaced))
                    if let note {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text(status.path ?? "")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}
