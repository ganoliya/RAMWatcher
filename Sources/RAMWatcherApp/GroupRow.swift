import RAMWatcherCore
import SwiftUI

/// Shared byte formatter for human-readable memory sizes, e.g. "1.2 GB".
let memoryByteFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .memory
    return formatter
}()

/// One top-level app group row: name, total footprint, system badge,
/// disclosure to expand member processes, and Quit / Force Quit controls.
struct GroupRow: View {
    @EnvironmentObject private var model: AppModel
    let group: ProcessGroup

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(group.members.sorted { $0.physFootprintBytes > $1.physFootprintBytes }) { member in
                MemberRow(member: member, isProtectedGroup: group.isProtected) { signal in
                    model.pendingConfirmation = PendingKill(target: .process(member), signal: signal)
                }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(group.displayName)
                            .font(.body)
                        if !group.isUserOwned {
                            Text("system")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.2))
                                .clipShape(Capsule())
                        }
                    }
                    Text("\(group.members.count) process\(group.members.count == 1 ? "" : "es")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(memoryByteFormatter.string(fromByteCount: Int64(group.totalFootprintBytes)))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)

                killControls
            }
        }
    }

    @ViewBuilder
    private var killControls: some View {
        if group.isProtected {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
                .help("Protected system process — cannot be terminated")
        } else {
            Button("Quit") {
                model.pendingConfirmation = PendingKill(target: .group(group), signal: .terminate)
            }
            .buttonStyle(.borderless)
            .help("Quit all \(group.members.count) process(es) in '\(group.displayName)' (SIGTERM)")

            Menu {
                Button("Force Quit") {
                    model.pendingConfirmation = PendingKill(target: .group(group), signal: .kill)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 20)
            .help("More actions")
        }
    }
}

/// A single subprocess row inside an expanded group: name, pid, footprint,
/// and a small kill-this-one-process action.
private struct MemberRow: View {
    let member: RAMWatcherCore.ProcessInfo
    let isProtectedGroup: Bool
    let onRequestKill: (KillSignal) -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(member.name)
                    .font(.caption)
                if let scriptPath = member.scriptPath,
                   !URL(fileURLWithPath: scriptPath).pathExtension.isEmpty || scriptPath.hasPrefix("-m ") {
                    Text(scriptPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(nil)
                }
                Text("pid \(member.pid)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(memoryByteFormatter.string(fromByteCount: Int64(member.physFootprintBytes)))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            if isProtectedGroup {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Protected system process — cannot be terminated")
            } else {
                Menu {
                    Button("Quit Process") { onRequestKill(.terminate) }
                    Button("Force Quit Process") { onRequestKill(.kill) }
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 16)
                .help("Quit this process")
            }
        }
        .padding(.leading, 12)
    }
}
