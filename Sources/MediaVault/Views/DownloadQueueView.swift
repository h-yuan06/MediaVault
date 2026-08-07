import SwiftUI

struct DownloadQueueView: View {
    @EnvironmentObject var engine: DownloadEngine

    private var active: [DownloadItem] { engine.queue.filter { $0.status.isActive } }
    private var finished: [DownloadItem] { engine.queue.filter { $0.status.isFinished } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if engine.queue.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No active downloads")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !active.isEmpty {
                        Section("Active") {
                            ForEach(active) { item in
                                DownloadItemRow(item: item)
                            }
                        }
                    }
                    if !finished.isEmpty {
                        Section {
                            ForEach(finished) { item in
                                DownloadItemRow(item: item)
                            }
                        } header: {
                            HStack {
                                Text("Finished")
                                Spacer()
                                Button("Clear") { engine.clearFinished() }
                                    .font(.caption)
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Downloads")
    }
}
