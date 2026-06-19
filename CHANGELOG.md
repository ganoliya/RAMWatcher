# Changelog

All notable changes to RAMWatcher are documented here.

## [Unreleased]

### Changed
- **Daemon installation rewritten to self-register via `SMAppService`.** The privileged background daemon now ships embedded inside `RAMWatcher.app` (`Contents/MacOS/RAMWatcherDaemon` + `Contents/Library/LaunchDaemons/com.himanshu.ramwatcher.daemon.plist`, the latter using the `BundleProgram` key so the path resolves correctly regardless of where the app is installed) and registers itself automatically at launch via Apple's `ServiceManagement` framework. The only user action is a one-time approval in System Settings → General → Login Items & Extensions — no sudo password needed. This replaces the previous flow, which required running `sudo ./Scripts/install_daemon.sh` manually. Requires the app to be signed with a real Apple Developer ID; ad-hoc signed builds run locally but cannot register the daemon.
- `Scripts/build_app.sh` now auto-detects a `Developer ID Application` identity in the keychain, signs both the embedded daemon and the outer app bundle with the hardened runtime (inside-out: daemon first, then the bundle), and embeds the daemon directly — it no longer produces a separate standalone daemon binary for manual install.
- `Scripts/install_daemon.sh` removed (obsolete — replaced by self-registration).
- `Scripts/uninstall_daemon.sh` retained only for migrating away from a pre-`SMAppService` install; current installs are removed by deleting the `.app`.

### Fixed
- Daemon registration was wired to a `.task` modifier on `MenuBarExtra`'s content view, which SwiftUI builds lazily and only when the user opens the dropdown — on a fresh install this meant registration silently never happened until the menu was clicked at least once. Moved to `AppDelegate.applicationDidFinishLaunching`, which always runs once at process launch.
- The auto-registration trigger only fired on `SMAppService.Status.notRegistered`; a fresh, never-before-registered daemon actually reports `.notFound` (raw value 3) on its first status check, which was being treated as a hard packaging error instead of the normal pre-registration state. Confirmed via `sfltool dumpbtm` and system log inspection that registration succeeds once `.notFound` is also treated as "needs registration."

## [0.1.0] - 2026-06-19

Initial release.

### Added
- Menu-bar RAM usage monitor that groups subprocess memory under the parent app (PPID-tree walk + bundle-path fallback for launchd-reparented XPC helpers), reads `phys_footprint` (matching Activity Monitor, not RSS), and shows both system-wide "Memory Used" and per-app "App Memory" figures.
- Filter to All / User Only / System Only processes; search by name.
- Kill (SIGTERM) and Force Quit (SIGKILL) per app group or individual process, with a hardcoded blocklist (`kernel_task`, `launchd`, `WindowServer`, etc.) enforced server-side.
- Privileged daemon (originally installed via a manual `sudo` script + LaunchDaemon) serving a JSON-over-Unix-socket protocol to the unprivileged UI.
- Validated `phys_footprint` readings directly against Activity Monitor and system-wide memory pressure against Stats-style tooling.
- MIT license; README with problem statement, solution, and architecture; CLAUDE.md for future contributors.
