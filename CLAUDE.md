# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
swift build                          # debug build, all targets
swift build -c release               # release build
swift test                           # run all tests (RAMWatcherCoreTests)
swift test --filter testGroupingSumsFootprintAcrossPPIDChildren   # run a single test
./Scripts/build_app.sh               # release build + assembles dist/RAMWatcher.app (ad-hoc signed) + dist/RAMWatcherDaemon — no sudo
sudo ./Scripts/install_daemon.sh      # installs the daemon binary + LaunchDaemon plist as root and starts it — must be run by a human in a real terminal, never scripted/automated
sudo ./Scripts/uninstall_daemon.sh    # stops and removes the installed daemon
```

There is no separate lint step; `swift build` surfaces all compiler warnings.

**After changing anything under `Sources/RAMWatcherDaemon` or `Sources/RAMWatcherCore`**, `build_app.sh` only refreshes `dist/`. You must re-run `sudo ./Scripts/install_daemon.sh` to replace the binary actually installed at `/usr/local/libexec/ramwatcher/RAMWatcherDaemon` — the running LaunchDaemon does not pick up rebuilt binaries automatically.

**Never run `install_daemon.sh` or `uninstall_daemon.sh` yourself** (they require sudo and modify system-level LaunchDaemon state) — provide the command for the user to run in their own terminal instead.

## Architecture

Three-target Swift Package, split by privilege level — this split is the central design constraint of the whole project, not an arbitrary module boundary:

```
Menu bar app (user account, SwiftUI)  <-- unix socket, newline-delimited JSON -->  RAMWatcherDaemon (root, LaunchDaemon)
```

- **`Sources/RAMWatcherCore`** — shared library, no privilege boundary of its own:
  - `ProcessSampler.swift` — enumerates all PIDs via `proc_listallpids`/`proc_pidinfo`, reads memory via `proc_pid_rusage(... RUSAGE_INFO_V2) → ri_phys_footprint`. **Never use RSS** (`pti_resident_size`) as the memory metric — Activity Monitor's "Memory" column is `phys_footprint`, and using RSS would make every number visibly disagree with it.
  - `Grouping.swift` — groups raw processes into app-level `ProcessGroup`s via two combined strategies: PPID-tree walk up to the nearest `.app/Contents/MacOS/` ancestor, plus a bundle-path fallback that merges processes sharing a `Something.app` path even when not a PPID descendant (catches XPC services reparented to launchd, which the PPID walk alone misses). There is no public API for the "responsible process" relationship Activity Monitor itself uses (it's a private SPI) — this heuristic is the deliberate substitute and is not airtight.
  - `Blocklist.swift` — `KillBlocklist.isProtected(pid:name:)`, a hardcoded list of unkillable core processes (`kernel_task`, `launchd`, `WindowServer`, PID 0/1, etc.). Enforced in the daemon, not just the UI.
  - `Protocol.swift` — the fixed wire contract (`ProcessInfo`, `ProcessGroup`, `Snapshot`, `Request`, `Response`, `KillSignal`, `ActionOutcome`, `IPC.socketPath`). Both other targets depend on this; treat changes to it as changes to a public API shared across the privilege boundary.

- **`Sources/RAMWatcherDaemon`** — root-only executable, the only component that can read other users'/system processes' memory or signal them (`proc_pid_rusage`/`kill()` return `EPERM` across UID boundaries for non-root callers, which is *why* this daemon exists as a separate privileged process instead of living inside the UI app). Samples everything every 1.5s into a lock-protected cache, serves it over a Unix domain socket at `IPC.socketPath` (`/var/run/ramwatcher.sock`). Also computes system-wide "Memory Used" via `host_statistics64(HOST_VM_INFO64)` (active + wired + compressor pages) — deliberately distinct from the per-app footprint sum the UI also shows, since wired/kernel/GPU memory isn't attributable to any process. Has a `SIGPIPE` ignore handler (a disconnecting client writing into a dead socket would otherwise kill the whole root daemon) and a debug-only socket path override (`RAMWATCHER_SOCKET_PATH` env var, `#if DEBUG` gated) for testing without root.

- **`Sources/RAMWatcherApp`** — unprivileged SwiftUI `MenuBarExtra` app (`LSUIElement` via `Resources/Info.plist`, no Dock icon). Polls the daemon every 2s via `DaemonClient` (raw `AF_UNIX` socket actor with reconnect-on-demand — the daemon is very likely not running during dev, so this must fail gracefully rather than crash). `AppModel` is the `@MainActor` `ObservableObject` holding filter/search state and the derived `filteredGroups`/`appMemoryBytes`/`systemUsedBytes` computed properties the views read.

When changing the wire protocol in `Protocol.swift`, every `Snapshot`/`Request`/`Response` construction site across the daemon and the app must be updated together — there is no versioning or backward compatibility between them, since both are built from the same source tree and are expected to be redeployed together.

See `README.md` for the user-facing explanation of the phys_footprint-vs-RSS and Memory-Used-vs-App-Memory distinctions, and for the full build/install flow.
