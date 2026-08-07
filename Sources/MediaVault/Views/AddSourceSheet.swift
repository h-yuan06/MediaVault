import SwiftUI
import AppKit

struct AddSourceSheet: View {
    @EnvironmentObject var store: SourceStore
    @EnvironmentObject var engine: DownloadEngine
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var nameText = ""
    @State private var isFetching = false
    @State private var customFolder: URL? = nil

    private var detectedType: SourceType { SourceType.detect(from: urlText) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Follow a URL")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 6) {
                Label("URL", systemImage: detectedType.iconName)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                PasteableTextField(
                    placeholder: "https://www.youtube.com/c/ChannelName",
                    text: $urlText,
                    onSubmit: fetchTitle
                )

                if !urlText.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: detectedType.iconName)
                        Text(detectedType.displayName)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Name (optional)")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("Auto-detected from URL", text: $nameText)
                        .textFieldStyle(.roundedBorder)
                    if isFetching {
                        ProgressView().scaleEffect(0.7)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Download Destination")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    if let folder = customFolder {
                        Text(folder.path)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Change") { pickFolder() }
                            .font(.caption)
                        Button("Reset") { customFolder = nil }
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text(store.downloadRootURL.map { $0.appendingPathComponent(nameText.isEmpty ? "…" : nameText).path } ?? "Default folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Change…") { pickFolder() }
                            .font(.caption)
                    }
                }
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add & Sync") { addAndSync() }
                    .buttonStyle(.borderedProminent)
                    .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear { }
    }

    private func fetchTitle() {
        guard !urlText.isEmpty, nameText.isEmpty else { return }
        isFetching = true
        // Use yt-dlp --get-title to auto-fill the name
        Task {
            let name = await NameFetcher.fetch(url: urlText)
            await MainActor.run {
                if nameText.isEmpty { nameText = name ?? "" }
                isFetching = false
            }
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Downloads will be saved to this folder."
        if panel.runModal() == .OK { customFolder = panel.url }
    }

    private func addAndSync() {
        let url = urlText.trimmingCharacters(in: .whitespaces)
        let name = nameText.trimmingCharacters(in: .whitespaces)
        store.add(url: url, name: name, customFolder: customFolder)
        if let source = store.sources.first(where: { $0.url == url }) {
            engine.sync(source: source, store: store)
        }
        dismiss()
    }
}

// NSViewRepresentable wrapper so Cmd+V / right-click Paste work reliably in a sheet.
struct PasteableTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PasteableTextField
        init(_ parent: PasteableTextField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSTextField {
                parent.text = field.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}

enum NameFetcher {
    static func fetch(url: String) async -> String? {
        let ytdlpPath = await MainActor.run { ToolChecker.shared.ytdlpPath }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytdlpPath)
        process.arguments = ["--get-title", "--playlist-end", "1", "--no-warnings", url]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return raw?.isEmpty == false ? raw : nil
        } catch {
            return nil
        }
    }
}
