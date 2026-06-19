import RAMWatcherCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header

            if let lastActionMessage = model.lastActionMessage {
                Text(lastActionMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.1))
                    .transition(.opacity)
                    .animation(.default, value: model.lastActionMessage)
            }

            Divider()

            if model.connectionError != nil {
                daemonNotRunningView
            } else if model.filteredGroups.isEmpty {
                emptyStateView
            } else {
                processList
            }
        }
        .frame(width: 380, height: 480)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(menuBarSummary)
                .font(.headline)

            TextField("Search", text: $model.searchText)
                .textFieldStyle(.roundedBorder)

            Picker("Filter", selection: $model.filter) {
                ForEach(ProcessFilter.allCases, id: \.self) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(12)
    }

    /// Shows both figures Activity Monitor shows, with the same labels, so
    /// the numbers here are recognizable rather than a mystery third number:
    /// "Memory Used" (system-wide, includes wired/compressed) and
    /// "App Memory" (sum of per-process footprints, always lower).
    private var menuBarSummary: String {
        guard let snapshot = model.snapshot else { return "RAMWatcher" }
        let usedGB = Double(model.systemUsedBytes) / 1_073_741_824.0
        let totalGB = Double(snapshot.totalPhysicalMemoryBytes) / 1_073_741_824.0
        let appGB = Double(model.appMemoryBytes) / 1_073_741_824.0
        return String(format: "Memory Used: %.1f GB of %.1f GB  ·  App Memory: %.1f GB", usedGB, totalGB, appGB)
    }

    private var daemonNotRunningView: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("RAMWatcher daemon is not running")
                .font(.headline)
            Text("Install it with the install script (see Scripts/) and make sure the LaunchDaemon is loaded, then reopen this menu.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let connectionError = model.connectionError {
                Text(connectionError)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Text("No matching processes")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var processList: some View {
        List {
            ForEach(model.filteredGroups) { group in
                GroupRow(group: group)
            }
        }
        .listStyle(.sidebar)
    }
}
