import AppKit
import RAMWatcherCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var daemonInstaller: DaemonInstaller
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        ZStack {
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

            // Rendered as a plain overlay (not a system .confirmationDialog/
            // .alert) because MenuBarExtra(.window) dismisses its whole
            // popover the instant a system-presented sheet takes key
            // status -- which swallows the button tap before its action
            // ever fires. See `AppModel.pendingConfirmation`.
            if let pending = model.pendingConfirmation {
                ConfirmationOverlay(pending: pending)
            }
        }
        .frame(width: 380, height: 480)
        .onAppear {
            isSearchFieldFocused = true
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(menuBarSummary)
                    .font(.headline)

                Spacer()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.borderless)
                .help("Quit RAMWatcher")
            }

            TextField("Search", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .focused($isSearchFieldFocused)

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
            daemonStatusContent

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

    /// The primary message + action the user should read for the current
    /// daemon registration state. `connectionError` (shown below this,
    /// smaller) is supplementary debugging detail, not the headline.
    @ViewBuilder
    private var daemonStatusContent: some View {
        switch daemonInstaller.state {
        case .requiresApproval:
            Image(systemName: "checkmark.shield")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("One-time approval needed")
                .font(.headline)
            Text("RAMWatcher needs one-time approval to run its background helper.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings") {
                daemonInstaller.openSystemSettingsLoginItems()
            }

        case .registrationFailed(let message):
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Couldn't start background helper")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Again") {
                daemonInstaller.register()
            }

        case .registered where isStuckDespiteBeingRegistered:
            // SMAppService says the daemon is registered, but we've been
            // unable to reach it over the socket for a while. Calling
            // `register()` again here would be a no-op -- re-registering
            // an already-registered daemon does NOT restart its
            // already-running process, e.g. after a daemon-side code
            // update is installed but the old process is still alive (or
            // it crashed/hung). The only fix is a privileged restart,
            // which needs the user's own terminal since it requires sudo.
            Image(systemName: "terminal")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Background helper isn't responding")
                .font(.headline)
            Text("Run this in Terminal to restart it:")
                .font(.caption)
                .foregroundStyle(.secondary)
            daemonRestartCommandBox

        case .notRegistered, .notFound, .registered:
            // `.notFound` (SMAppService status 3) is the normal status for
            // a daemon that's never been registered before -- not
            // necessarily a packaging bug despite the name. The app
            // auto-calls register() at launch for both `.notRegistered`
            // and `.notFound`, so this is a brief transient state, not a
            // dead end. If registration genuinely can't find the embedded
            // plist, that surfaces through `.registrationFailed` instead,
            // since `register()` itself would throw.
            ProgressView()
                .controlSize(.small)
            Text("Starting background helper...")
                .font(.headline)
        }
    }

    /// Gives a freshly-registered daemon a few seconds to actually start
    /// listening on its socket before treating the connection failure as
    /// "stuck" rather than "just starting up".
    private var isStuckDespiteBeingRegistered: Bool {
        guard let since = model.connectionErrorSince else { return false }
        return Date().timeIntervalSince(since) > 6
    }

    private let daemonRestartCommand = "sudo launchctl kickstart -k system/com.himanshu.ramwatcher.daemon"

    private var daemonRestartCommandBox: some View {
        HStack {
            Text(daemonRestartCommand)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)

            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(daemonRestartCommand, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy command")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
