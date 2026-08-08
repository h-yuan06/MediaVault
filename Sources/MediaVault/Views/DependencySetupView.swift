import SwiftUI

struct DependencySetupView: View {
    @EnvironmentObject var tools: ToolChecker
    @StateObject private var installer = DependencyInstaller.shared

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 56))
                .foregroundStyle(.orange)

            Text("Install Required Tools")
                .font(.title2.bold())

            // Homebrew prerequisite
            brewRow

            Divider()
                .padding(.horizontal, 32)

            // Tool rows
            VStack(alignment: .leading, spacing: 12) {
                ForEach(installer.steps) { step in
                    stepRow(step)
                }
            }
            .padding()
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

            if installer.brewInstalled && !installer.isRunning && !installer.isDone {
                Button("Install All Automatically") {
                    Task { await installer.installAll() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            if installer.isRunning {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("Installing…")
                        .foregroundStyle(.secondary)
                }
            }

            if installer.isDone {
                Button(action: { Task { await tools.check() } }) {
                    Label("Done — Re-check Tools", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
            }

            if !installer.brewInstalled || (!installer.isRunning && !installer.isDone) {
                Button(action: { Task { await tools.check() } }) {
                    tools.isChecking
                        ? AnyView(HStack(spacing: 8) { ProgressView().scaleEffect(0.8); Text("Checking…") })
                        : AnyView(Text("Re-check Tools"))
                }
                .buttonStyle(.bordered)
                .disabled(tools.isChecking)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var brewRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: installer.brewInstalled ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(installer.brewInstalled ? .green : .red)
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text("Homebrew")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                if installer.brewInstalled {
                    Text("Installed")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Required to install all other tools. Run this in Terminal:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 6) {
                        Text(#"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#,
                                forType: .string
                            )
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Copy to clipboard")
                    }
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(.horizontal, 32)
    }

    private func stepRow(_ step: DependencyInstaller.Step) -> some View {
        HStack(alignment: .top, spacing: 10) {
            stepIcon(step.status)
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.displayName)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                if case .failed(let msg) = step.status {
                    Text(msg.isEmpty ? "Installation failed" : msg)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                } else if case .running = step.status {
                    Text("Installing…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if case .done = step.status {
                    Text("Installed")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if let path = pathForTool(step.id) {
                    Text(path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Not installed")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private func stepIcon(_ status: DependencyInstaller.StepStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .running:
            ProgressView().scaleEffect(0.6)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private func pathForTool(_ id: String) -> String? {
        switch id {
        case "yt-dlp":     return tools.ytdlp.path
        case "ffmpeg":     return tools.ffmpeg.path
        case "gallery-dl": return tools.galleryDl.path
        case "deno":       return tools.deno.path
        default:           return nil
        }
    }
}
