import Foundation

/// Hardcoded denylist of processes the daemon will refuse to kill, even
/// when explicitly requested via `Request.killProcess` / `.killGroup`.
///
/// This list is deliberately conservative: it is far better to refuse a
/// kill that would actually have been safe than to risk destabilizing the
/// user's session by tearing down a core system daemon or the window
/// server out from under them. When in doubt, a PID/name stays on the
/// list.
///
/// Note: several of these (e.g. `launchd`-managed daemons like `configd`,
/// `coreaudiod`, `diskarbitrationd`) would simply be respawned by launchd
/// if killed anyway. That's expected behavior, not a bug, and is a
/// UI-level expectation (the user might see the process reappear with a
/// new PID) — this enum does not attempt to handle or explain that, it
/// simply refuses the kill outright for the names below regardless of
/// whether the respawn would happen.
public enum KillBlocklist {
    /// Process names that may never be killed, regardless of PID or owner.
    public static let protectedNames: Set<String> = [
        "kernel_task",
        "launchd",
        "WindowServer",
        "syslogd",
        "logd",
        "diskarbitrationd",
        "configd",
        "coreaudiod",
        "loginwindow",
    ]

    /// Returns true if the given pid/name combination must not be killed.
    public static func isProtected(pid: Int32, name: String) -> Bool {
        if pid == 0 || pid == 1 {
            return true
        }
        return protectedNames.contains(name)
    }
}
