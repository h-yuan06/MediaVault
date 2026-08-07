import SwiftUI

struct DuplicatesSheet: View {
    @ObservedObject var detector: DuplicateDetector
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Detect Repeats")
                        .font(.title2.bold())
                    Text(detector.progress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if detector.isScanning {
                    ProgressView().scaleEffect(0.8)
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            if !detector.isScanning && !detector.groups.isEmpty {
                HStack {
                    Text("\(detector.groups.count) group(s) — \(detector.groups.reduce(0) { $0 + $1.files.count - 1 }) file(s) can be removed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Keep One from Each Group") { detector.keepOneFromAll() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                Divider()
            }

            if detector.isScanning {
                Spacer()
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Comparing files…")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else if detector.groups.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    Text("No duplicates found")
                        .font(.title3.bold())
                    Text(detector.progress)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                List {
                    ForEach(detector.groups) { group in
                        Section {
                            ForEach(group.files, id: \.self) { file in
                                FileRow(url: file) {
                                    detector.delete(file)
                                }
                            }
                        } header: {
                            Label("Duplicate Group", systemImage: "doc.on.doc")
                                .font(.caption.bold())
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 560, height: 480)
    }
}

private struct FileRow: View {
    let url: URL
    let onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .lineLimit(1)
                Text(url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(fileSize)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .help("Move to Trash")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private var iconName: String {
        let ext = url.pathExtension.lowercased()
        if ["mp4","mkv","webm","mov","avi","m4v","flv"].contains(ext) { return "film" }
        if ["jpg","jpeg","png","gif","webp","bmp","tiff","heic"].contains(ext) { return "photo" }
        return "doc"
    }

    private var fileSize: String {
        guard let bytes = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 else { return "" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
