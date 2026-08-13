import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: SourceStore
    @EnvironmentObject var tools: ToolChecker
    @EnvironmentObject var updater: AutoUpdater

    var body: some View {
        Form {
            Section("Download Location") {
                HStack {
                    if let url = store.downloadRootURL {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(Color.accentColor)
                        Text(url.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("Not set")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Change…") { store.selectDownloadFolder() }
                        .buttonStyle(.bordered)
                }
            }

            Section("Tools") {
                toolRow(tools.ytdlp)
                toolRow(tools.ffmpeg)
                toolRow(tools.deno)
                toolRow(tools.galleryDl)

                HStack {
                    Spacer()
                    Button(action: { Task { await tools.check() } }) {
                        if tools.isChecking {
                            HStack(spacing: 6) {
                                ProgressView().scaleEffect(0.7)
                                Text("Checking…")
                            }
                        } else {
                            Text("Re-check")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(tools.isChecking)
                }
            }

            Section("Schedule") {
                LabeledContent("Check frequency", value: "Every 24 hours")
                LabeledContent("Install Homebrew") {
                    Link("brew.sh", destination: URL(string: "https://brew.sh")!)
                }
            }

            Section("About") {
                LabeledContent("Build", value: updater.localBuild.map { String($0) } ?? "Unknown")

                HStack {
                    Button(action: { updater.checkForUpdatesOnly() }) {
                        if updater.isCheckingForUpdates {
                            HStack(spacing: 6) {
                                ProgressView().scaleEffect(0.7)
                                Text("Checking…")
                            }
                        } else {
                            Text("Check for Updates")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(updater.isCheckingForUpdates)

                    if let result = updater.updateCheckResult {
                        switch result {
                        case .upToDate:
                            Label("Up to date", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.callout)
                        case .updateAvailable(let remoteBuild):
                            HStack(spacing: 8) {
                                Label("Build \(remoteBuild) available", systemImage: "arrow.down.circle.fill")
                                    .foregroundStyle(.orange)
                                    .font(.callout)
                                Button("Install") { updater.checkAndInstall() }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                            }
                        case .failed(let msg):
                            Label(msg, systemImage: "exclamationmark.circle.fill")
                                .foregroundStyle(.red)
                                .font(.callout)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
    }

    private func toolRow(_ status: ToolStatus) -> some View {
        HStack {
            Image(systemName: status.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(status.isAvailable ? .green : .red)
            Text(status.name)
            Spacer()
            Text(status.path ?? "Not found")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
