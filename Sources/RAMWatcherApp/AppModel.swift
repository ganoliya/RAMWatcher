import Foundation
import RAMWatcherCore

/// How the process group list is filtered by ownership.
enum ProcessFilter: String, CaseIterable {
    case all = "All"
    case userOnly = "User Only"
    case systemOnly = "System Only"
}

/// A kill action awaiting user confirmation. Lives on `AppModel` (rather
/// than as row-local `@State`) so the confirmation card can be rendered
/// once at the top of `ContentView`, above the `List` -- see the note on
/// `AppModel.pendingConfirmation` for why this can't be a system
/// `.confirmationDialog`/`.alert` instead.
struct PendingKill: Identifiable {
    enum Target {
        case group(ProcessGroup)
        case process(RAMWatcherCore.ProcessInfo)
    }
    let id = UUID()
    let target: Target
    let signal: KillSignal

    var confirmButtonLabel: String {
        signal == .terminate ? "Quit" : "Force Quit"
    }

    var message: String {
        switch target {
        case .group(let group):
            let verb = signal == .terminate ? "Quit" : "Force quit"
            return "\(verb) '\(group.displayName)' and its \(group.members.count) process\(group.members.count == 1 ? "" : "es")?"
        case .process(let proc):
            let verb = signal == .terminate ? "Quit" : "Force quit"
            return "\(verb) process '\(proc.name)' (pid \(proc.pid))?"
        }
    }
}

/// Main observable state for the menu bar UI. Owns the daemon connection
/// and polls it on a fixed cadence, exposing the latest snapshot plus
/// derived/filterable views over it to SwiftUI.
@MainActor
final class AppModel: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var connectionError: String?
    /// When `connectionError` first became non-nil, so the UI can tell a
    /// brief "still starting up" blip from a daemon that's genuinely stuck
    /// (e.g. registered with launchd but not actually listening on its
    /// socket -- which happens after a daemon-side code change, since
    /// re-registering an already-registered `SMAppService` daemon does not
    /// restart its already-running process). `nil` whenever the daemon is
    /// reachable.
    @Published private(set) var connectionErrorSince: Date?
    @Published var filter: ProcessFilter = .userOnly
    @Published var searchText: String = ""
    @Published var lastActionMessage: String?
    /// The kill action currently awaiting user confirmation, rendered by
    /// `ContentView` as a custom overlay card.
    ///
    /// This deliberately does NOT use a system `.confirmationDialog`/
    /// `.alert`: those present as a separate key window, and
    /// `MenuBarExtra(.window)` auto-dismisses its popover the instant it
    /// loses key status. The result (confirmed empirically): the dialog
    /// shows, but tapping its button just closes the whole popover before
    /// the tap is delivered to the button's action -- so the kill never
    /// fires and reopening the popover shows the same dialog still
    /// pending. A plain SwiftUI overlay in the same view hierarchy has no
    /// window/key-status transition to trigger that dismissal.
    @Published var pendingConfirmation: PendingKill?

    private let client: DaemonClient
    private var pollTask: Task<Void, Never>?
    private var actionMessageClearTask: Task<Void, Never>?

    /// Sum of per-app footprints -- Activity Monitor calls this "App Memory".
    /// This is intentionally NOT the system-wide used figure: it excludes
    /// wired kernel/GPU/driver memory and the compressor's bookkeeping, so
    /// it reads much lower than a Stats-style menu bar percentage. Use
    /// `systemUsedBytes` for that.
    var appMemoryBytes: UInt64 {
        snapshot?.groups.reduce(0) { $0 + $1.totalFootprintBytes } ?? 0
    }

    /// Real system-wide used memory (active + wired + compressed), matching
    /// Activity Monitor's pressure gauge / Stats' percentage. This is the
    /// number to show as the headline "RAM used" figure.
    var systemUsedBytes: UInt64 {
        snapshot?.usedPhysicalMemoryBytes ?? 0
    }

    var systemUsedFraction: Double {
        guard let snapshot, snapshot.totalPhysicalMemoryBytes > 0 else { return 0 }
        return Double(snapshot.usedPhysicalMemoryBytes) / Double(snapshot.totalPhysicalMemoryBytes)
    }

    /// `model.filteredGroups`: applies the ownership filter and the search
    /// text (case-insensitive substring match on `displayName`) to the
    /// latest snapshot's groups, sorted descending by total footprint so
    /// the heaviest consumers are always at the top.
    var filteredGroups: [ProcessGroup] {
        var groups = snapshot?.groups ?? []

        switch filter {
        case .all:
            break
        case .userOnly:
            groups = groups.filter { $0.isUserOwned }
        case .systemOnly:
            groups = groups.filter { !$0.isUserOwned }
        }

        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearch.isEmpty {
            groups = groups.filter {
                $0.displayName.range(of: trimmedSearch, options: .caseInsensitive) != nil
            }
        }

        return groups.sorted { $0.totalFootprintBytes > $1.totalFootprintBytes }
    }

    init(client: DaemonClient = DaemonClient(), pollInterval: TimeInterval = 2.0) {
        self.client = client
        startPolling(interval: pollInterval)
    }

    deinit {
        pollTask?.cancel()
        actionMessageClearTask?.cancel()
    }

    private func startPolling(interval: TimeInterval) {
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshOnce()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func refreshOnce() async {
        do {
            let snapshot = try await client.fetchSnapshot()
            self.snapshot = snapshot
            self.connectionError = nil
            self.connectionErrorSince = nil
        } catch {
            self.connectionError = error.localizedDescription
            if connectionErrorSince == nil {
                connectionErrorSince = Date()
            }
        }
    }

    /// Forces an immediate refresh outside the regular polling cadence,
    /// e.g. right after a kill action so the UI reflects the result
    /// without waiting up to 2s for the next tick.
    func refreshNow() async {
        await refreshOnce()
    }

    /// Cancels the pending confirmation without performing the kill.
    func cancelPendingKill() {
        pendingConfirmation = nil
    }

    /// Performs whichever kill is currently pending, then clears it.
    func confirmPendingKill() async {
        guard let pending = pendingConfirmation else { return }
        pendingConfirmation = nil
        switch pending.target {
        case .group(let group):
            await killGroup(group, signal: pending.signal)
        case .process(let proc):
            await killProcess(proc, signal: pending.signal)
        }
    }

    private func killGroup(_ group: ProcessGroup, signal: KillSignal) async {
        do {
            let (outcome, message) = try await client.killGroup(mainPID: group.mainPID, signal: signal)
            showActionMessage(describeOutcome(outcome, message: message, target: group.displayName))
        } catch {
            showActionMessage("Failed to kill '\(group.displayName)': \(error.localizedDescription)")
        }
        await refreshNow()
    }

    private func killProcess(_ proc: RAMWatcherCore.ProcessInfo, signal: KillSignal) async {
        do {
            let (outcome, message) = try await client.kill(pid: proc.pid, signal: signal)
            showActionMessage(describeOutcome(outcome, message: message, target: proc.name))
        } catch {
            showActionMessage("Failed to kill '\(proc.name)': \(error.localizedDescription)")
        }
        await refreshNow()
    }

    private func describeOutcome(_ outcome: ActionOutcome, message: String, target: String) -> String {
        switch outcome {
        case .success:
            return "\(target): \(message)"
        case .blocked, .notPermitted, .noSuchProcess, .error:
            return "\(target): \(message)"
        }
    }

    /// Shows a transient message and clears it after a few seconds so it
    /// behaves like a toast rather than a persistent banner.
    private func showActionMessage(_ message: String) {
        lastActionMessage = message
        actionMessageClearTask?.cancel()
        actionMessageClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.lastActionMessage = nil
        }
    }
}
