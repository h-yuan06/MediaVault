import SwiftUI

struct SourceRowView: View {
    let source: FollowedSource
    @EnvironmentObject var engine: DownloadEngine

    private var activeItems: [DownloadItem] {
        engine.queue.filter { $0.sourceId == source.id && $0.status.isActive }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: source.sourceType.iconName)
                .frame(width: 20)
                .foregroundStyle(iconColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .lineLimit(1)
                    .font(.body)

                if let active = activeItems.first {
                    ProgressView(value: active.progress)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                } else if let lastChecked = source.lastChecked {
                    Text("Checked \(lastChecked, style: .relative) ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(source.url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if !activeItems.isEmpty {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)
            } else if source.isSyncedToLatest {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                    .help("All content downloaded")
            }
        }
        .padding(.vertical, 2)
    }

    private var iconColor: Color {
        switch source.sourceType {
        case .youtube: return .red
        case .reddit: return .orange
        case .generic: return .blue
        }
    }
}
