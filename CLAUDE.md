# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
swift build                          # debug build, all targets
swift build -c release               # release build
swift test                           # run all tests (RAMWatcherCoreTests)
swift test --filter testGroupingSumsFootprintAcrossPPIDChildren   # run a single test
./Scripts/build_app.sh               # release build + assembles + signs dist/RAMWatcher.app (daemon embedded inside)
sudo ./Scripts/uninstall_daemon.sh    # LEGACY ONLY: removes a daemon installed by a pre-SMAppService version
```

There is no separate lint step; `swift build` surfaces all compiler warnings.

`build_app.sh` auto-detects a `Developer ID Application` identity in the keychain and uses it (required for `SMAppService` registration to actually work); it falls back to ad-hoc signing otherwise, which builds and runs locally but cannot register the daemon. After any change to `Sources/RAMWatcherDaemon`, you must re-run `build_app.sh` and reinstall the `.app` to `/Applications` — the daemon binary is embedded in the bundle, so there's no separate installed copy to go stale, but the *old bundle* in `/Applications` is still stale until you copy the new one over it.

**Never run `uninstall_daemon.sh` yourself** (it requires sudo and modifies system-level LaunchDaemon state) — provide the command for the user to run in their own terminal instead. It is legacy cleanup only; current installs are removed by deleting the `.app`.

After any change to `Sources/RAMWatcherDaemon` (or to `Sources/RAMWatcherCore`, which compiles into the daemon too), reinstalling the `.app` is **not enough** to make the change take effect: `SMAppService.register()` on an already-`.registered` daemon is a no-op and does not restart its already-running process — the old binary just keeps running, silently serving stale behavior, indefinitely. The only way to load new daemon-side code into the live process is a privileged restart, which needs the user's own terminal since it requires sudo:

```bash
sudo launchctl kickstart -k system/com.himanshu.ramwatcher.daemon
```

(This is also literally what the app's own UI tells the user to run if it detects the daemon is registered but unreachable for more than a few seconds — see `ContentView.isStuckDespiteBeingRegistered`.) When verifying a daemon-side fix, don't trust the app relaunching or `register()` returning success as evidence the new code is live — query the socket directly (`echo '{"type":"getSnapshot"}' | nc -U /var/run/ramwatcher.sock`) and check the daemon process's own `ELAPSED` time via `ps -o pid,etime,command -p $(pgrep -x RAMWatcherDaemon)` actually reset after the kickstart.

## Architecture

Three-target Swift Package, split by privilege level — this split is the central design constraint of the whole project, not an arbitrary module boundary. The daemon ships embedded inside the app bundle and self-registers via `SMAppService` (ServiceManagement framework, macOS 13+) when the app launches — this requires Developer ID signing; there is no manual sudo install step anymore:

```
RAMWatcher.app/Contents/MacOS/RAMWatcherApp (user)  <-- unix socket, newline-delimited JSON -->  RAMWatcher.app/Contents/MacOS/RAMWatcherDaemon (root, via SMAppService)
```

- **`Sources/RAMWatcherCore`** — shared library, no privilege boundary of its own:
  - `ProcessSampler.swift` — enumerates all PIDs via `proc_listallpids`/`proc_pidinfo`, reads memory via `proc_pid_rusage(... RUSAGE_INFO_V2) → ri_phys_footprint`. **Never use RSS** (`pti_resident_size`) as the memory metric — Activity Monitor's "Memory" column is `phys_footprint`, and using RSS would make every number visibly disagree with it. `listAllPIDs()`'s call to `proc_listallpids(buffer, buffersize)` returns a **PID count**, not a byte count, despite the documented "returns bytes" contract — confirmed empirically (the raw return value isn't divisible by `sizeof(Int32)`, and dividing it anyway previously kept only ~1/4 of all running processes, silently). Use the return value directly as the count; only the `buffersize` *input* argument is in bytes.
  - `Grouping.swift` — groups raw processes into app-level `ProcessGroup`s via two combined strategies: PPID-tree walk up to the nearest `.app/Contents/MacOS/` ancestor, plus a bundle-path fallback that merges processes sharing a `Something.app` path even when not a PPID descendant (catches XPC services reparented to launchd, which the PPID walk alone misses). There is no public API for the "responsible process" relationship Activity Monitor itself uses (it's a private SPI) — this heuristic is the deliberate substitute and is not airtight.
  - `Blocklist.swift` — `KillBlocklist.isProtected(pid:name:)`, a hardcoded list of unkillable core processes (`kernel_task`, `launchd`, `WindowServer`, PID 0/1, etc.). Enforced in the daemon, not just the UI.
  - `Protocol.swift` — the fixed wire contract (`ProcessInfo`, `ProcessGroup`, `Snapshot`, `Request`, `Response`, `KillSignal`, `ActionOutcome`, `IPC.socketPath`). Both other targets depend on this; treat changes to it as changes to a public API shared across the privilege boundary.

- **`Sources/RAMWatcherDaemon`** — root-only executable, the only component that can read other users'/system processes' memory or signal them (`proc_pid_rusage`/`kill()` return `EPERM` across UID boundaries for non-root callers, which is *why* this daemon exists as a separate privileged process instead of living inside the UI app). Built as a loose executable, then copied into `Contents/MacOS/` of the app bundle by `build_app.sh` — `Resources/com.himanshu.ramwatcher.daemon.plist` references it via the `BundleProgram` key (`Contents/MacOS/RAMWatcherDaemon`), which `SMAppService` resolves relative to wherever the app bundle actually lives on disk at registration time (this is what lets the daemon work regardless of install location, unlike the old absolute-path `Program`/`ProgramArguments` keys). Samples everything every 1.5s into a lock-protected cache, serves it over a Unix domain socket at `IPC.socketPath` (`/var/run/ramwatcher.sock`). Also computes system-wide "Memory Used" via `host_statistics64(HOST_VM_INFO64)` (active + wired + compressor pages) — deliberately distinct from the per-app footprint sum the UI also shows, since wired/kernel/GPU memory isn't attributable to any process. Has a `SIGPIPE` ignore handler (a disconnecting client writing into a dead socket would otherwise kill the whole root daemon) and a debug-only socket path override (`RAMWATCHER_SOCKET_PATH` env var, `#if DEBUG` gated) for testing without root.

- **`Sources/RAMWatcherApp`** — unprivileged SwiftUI `MenuBarExtra` app (`.menuBarExtraStyle(.window)`, `LSUIElement` via `Resources/Info.plist`, no Dock icon). Polls the daemon every 2s via `DaemonClient` (raw `AF_UNIX` socket actor with reconnect-on-demand — the daemon is very likely not running during dev, so this must fail gracefully rather than crash). `AppModel` is the `@MainActor` `ObservableObject` holding filter/search state (default `.userOnly`, not `.all`) and the derived `filteredGroups`/`appMemoryBytes`/`systemUsedBytes` computed properties the views read. `DaemonInstaller.swift` wraps `SMAppService.daemon(plistName:)` and must be driven from `AppDelegate.applicationDidFinishLaunching` (in `App.swift`), **not** from a `.task` on `MenuBarExtra`'s content view — that content closure is built lazily by SwiftUI only when the user opens the dropdown, so registration would silently never fire on a fresh install until the first click. Also: `SMAppService.Status.notFound` (raw value 3) is the normal status for a daemon that's never been registered before, not necessarily a packaging bug despite the name — confirmed empirically via `sfltool dumpbtm` and system log inspection (`com.apple.libxpc.SMAppService` subsystem) during development. Treat `.notFound` the same as `.notRegistered` when deciding whether to call `register()`. `AppModel.connectionErrorSince` tracks how long the daemon has been unreachable so `ContentView` can distinguish a brief startup blip from a daemon that's `.registered` but genuinely stuck (see the daemon-restart note in Commands above) and surface the actual fix instead of an endless spinner.

  **Never use a system `.confirmationDialog`/`.alert`/`.sheet` anywhere in this view tree.** `MenuBarExtra(.menuBarExtraStyle(.window))` dismisses its entire popover the instant a system-presented dialog takes key status, which swallows the button tap before SwiftUI ever delivers it to the action closure — confirmed empirically: the dialog visibly appears, but tapping its button just closes the whole popover, and reopening it shows the same dialog still pending with nothing actually having happened. All kill confirmations instead go through `AppModel.pendingConfirmation` (a plain `@Published` value, not row-local `@State`, so it survives the `List` re-rendering on every poll tick) rendered by `ConfirmationOverlay.swift` as an ordinary in-content overlay `View` — no separate window, so no key-status transition to trigger the auto-dismiss. Apply the same constraint to any future confirmation/alert UI added here.

  `GroupRow` sorts a group's `members` by `physFootprintBytes` descending before display (heaviest subprocess first) — this is purely a display-time sort in the app, not a change to the daemon's grouping/membership logic, so it never requires a daemon restart. The header's Quit button (`NSApplication.shared.terminate(nil)`) exists because `.menuBarExtraStyle(.window)` has no built-in right-click context menu to hang a native Quit item on; that would require dropping to a raw `NSStatusItem`-based implementation instead.

When changing the wire protocol in `Protocol.swift`, every `Snapshot`/`Request`/`Response` construction site across the daemon and the app must be updated together — there is no versioning or backward compatibility between them, since both are built from the same source tree and are expected to be redeployed together.

See `README.md` for the user-facing explanation of the phys_footprint-vs-RSS and Memory-Used-vs-App-Memory distinctions, and for the full build/install flow.
