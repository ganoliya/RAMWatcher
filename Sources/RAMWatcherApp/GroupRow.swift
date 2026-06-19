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
    @State private var pendingConfirmation: PendingKill?

    private struct PendingKill: Identifiable {
        enum Target {
            case group(ProcessGroup)
            case process(RAMWatcherCore.ProcessInfo)
        }
        let id = UUID()
        let target: Target
        let signal: KillSignal
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(group.members) { member in
                MemberRow(member: member, isProtectedGroup: group.isProtected) { signal in
                    pendingConfirmation = PendingKill(target: .process(member), signal: signal)
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
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { pendingConfirmation != nil },
                set: { if !$0 { pendingConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pending = pendingConfirmation {
                Button(confirmButtonLabel(for: pending), role: .destructive) {
                    Task { await performKill(pending) }
                }
                Button("Cancel", role: .cancel) {}
            }
        } message: {
            if let pending = pendingConfirmation {
                Text(confirmationMessage(for: pending))
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
                pendingConfirmation = PendingKill(target: .group(group), signal: .terminate)
            }
            .buttonStyle(.borderless)
            .help("Quit all \(group.members.count) process(es) in '\(group.displayName)' (SIGTERM)")

            Menu {
                Button("Force Quit") {
                    pendingConfirmation = PendingKill(target: .group(group), signal: .kill)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 20)
            .help("More actions")
        }
    }

    private var confirmationTitle: String {
        "Confirm Action"
    }

    private func confirmButtonLabel(for pending: PendingKill) -> String {
        pending.signal == .terminate ? "Quit" : "Force Quit"
    }

    private func confirmationMessage(for pending: PendingKill) -> String {
        switch pending.target {
        case .group(let group):
            let verb = pending.signal == .terminate ? "Quit" : "Force quit"
            return "\(verb) '\(group.displayName)' and its \(group.members.count) process\(group.members.count == 1 ? "" : "es")?"
        case .process(let proc):
            let verb = pending.signal == .terminate ? "Quit" : "Force quit"
            return "\(verb) process '\(proc.name)' (pid \(proc.pid))?"
        }
    }

    private func performKill(_ pending: PendingKill) async {
        switch pending.target {
        case .group(let group):
            await model.killGroup(group, signal: pending.signal)
        case .process(let proc):
            await model.killProcess(proc, signal: pending.signal)
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
