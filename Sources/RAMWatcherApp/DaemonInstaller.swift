import Foundation
import ServiceManagement

/// Wraps `SMAppService` registration for the privileged background daemon
/// (`RAMWatcherDaemon`), which ships embedded inside this app's bundle at
/// `Contents/Library/LaunchDaemons/com.himanshu.ramwatcher.daemon.plist`
/// once the app is properly signed and packaged.
///
/// This replaces the old manual `sudo ./Scripts/install_daemon.sh` flow:
/// with a Developer ID-signed app, registering the daemon is just an API
/// call from inside the running app. The only user-facing step left is a
/// one-time consent click in System Settings > General > Login Items &
/// Extensions -- not an admin password prompt, just an approval toggle that
/// Apple requires for visibility/trust even when the daemon is properly
/// signed.
@MainActor
final class DaemonInstaller: ObservableObject {
    enum DaemonState: Equatable {
        case notRegistered
        case registered          // .enabled -- daemon is registered and running
        case requiresApproval    // user must approve in System Settings
        case notFound             // plist missing -- packaging/build problem, not a user-fixable state
        case registrationFailed(String)
    }

    @Published private(set) var state: DaemonState = .notRegistered

    /// Must match the LaunchDaemon plist filename embedded by the build
    /// process at `Contents/Library/LaunchDaemons/`. Keep this string in
    /// sync with whatever writes that plist.
    private let service = SMAppService.daemon(plistName: "com.himanshu.ramwatcher.daemon.plist")

    /// Reflects the service's current registration status without
    /// attempting to register it. Safe to call repeatedly (e.g. when the
    /// menu bar window appears) since it has no side effects.
    func refreshStatus() {
        switch service.status {
        case .notRegistered:
            state = .notRegistered
        case .enabled:
            state = .registered
        case .requiresApproval:
            state = .requiresApproval
        case .notFound:
            state = .notFound
        @unknown default:
            state = .notRegistered
        }
    }

    /// Attempts to register the daemon. `SMAppService.register()` can throw
    /// even in the totally-expected case where the daemon ends up needing
    /// user approval -- that's the system telling us approval is pending,
    /// not a real failure. So after any attempt, whether it throws or not,
    /// re-check the actual status and let `.requiresApproval` win over
    /// treating the throw as a hard error. Only surface
    /// `.registrationFailed` when the post-attempt status is something
    /// other than `.requiresApproval`.
    func register() {
        do {
            try service.register()
            refreshStatus()
        } catch {
            refreshStatus()
            if state != .requiresApproval {
                state = .registrationFailed(error.localizedDescription)
            }
        }
    }

    /// Opens System Settings > General > Login Items & Extensions so the
    /// user can approve the pending background helper.
    func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
