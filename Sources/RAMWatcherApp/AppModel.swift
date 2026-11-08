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

/// Main observable state for the menu bar popover. Owns the daemon
/// connection and polls it only while the popover is visible (see
/// `setPopoverVisible`), exposing the latest snapshot plus derived/
/// filterable views over it to SwiftUI. While the popover is closed the
/// app sends nothing to the daemon, and the daemon (which samples on
/// demand) does no work at all.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: Snapshot? {
        didSet { recomputeFilteredGroups() }
    }
    @Published var connectionError: String?
    /// When `connectionError` first became non-nil, so the UI can tell a
    /// brief "still starting up" blip from a daemon that's genuinely stuck
    /// (e.g. registered with launchd but not actually listening on its
    /// socket -- which happens after a daemon-side code change, since
    /// re-registering an already-registered `SMAppService` daemon does not
    /// restart its already-running process). `nil` whenever the daemon is
    /// reachable.
    @Published private(set) var connectionErrorSince: Date?
    @Published var filter: ProcessFilter = .userOnly {
        didSet { recomputeFilteredGroups() }
    }
    @Published var searchText: String = "" {
        didSet { recomputeFilteredGroups() }
    }
    /// The ownership filter and search text applied to the latest
    /// snapshot's groups, sorted descending by total footprint so the
    /// heaviest consumers are always at the top. Stored (recomputed only
    /// when one of its inputs changes) rather than computed, since the
    /// view reads it more than once per render.
    @Published private(set) var filteredGroups: [ProcessGroup] = []
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
    private let meter: MemoryMeter?
    private let pollInterval: TimeInterval
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

    private func recomputeFilteredGroups() {
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

        filteredGroups = groups.sorted { $0.totalFootprintBytes > $1.totalFootprintBytes }
    }

    init(client: DaemonClient = DaemonClient(), meter: MemoryMeter? = nil, pollInterval: TimeInterval = 2.0) {
        self.client = client
        self.meter = meter
        self.pollInterval = pollInterval
    }

    deinit {
        pollTask?.cancel()
        actionMessageClearTask?.cancel()
    }

    /// Called by `ContentView` when the popover window is shown or hidden.
    /// Opening fetches immediately and then every `pollInterval`; closing
    /// stops polling and drops the snapshot so its (potentially large)
    /// process list doesn't sit in memory while nobody is looking. The
    /// next open shows a brief loading state until the first fetch lands.
    func setPopoverVisible(_ visible: Bool) {
        if visible {
            guard pollTask == nil else { return }
            let interval = pollInterval
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.refreshOnce()
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
            }
        } else {
            pollTask?.cancel()
            pollTask = nil
            snapshot = nil
            pendingConfirmation = nil
            // Otherwise a stale error from a previous session would show
            // instantly on the next open, and an old `connectionErrorSince`
            // would skip the startup grace period straight to "stuck".
            connectionError = nil
            connectionErrorSince = nil
        }
    }

    private func refreshOnce() async {
        do {
            let snapshot = try await client.fetchSnapshot()
            // A fetch that was already in flight when the popover closed
            // shouldn't resurrect the snapshot we just dropped.
            guard pollTask != nil else { return }
            self.snapshot = snapshot
            self.connectionError = nil
            self.connectionErrorSince = nil
            // Keep the menu bar figure in step with the popover while it's
            // open; it's a local syscall, so this costs nothing extra.
            meter?.refresh()
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
