# RAMWatcher

A menu-bar RAM usage monitor for macOS — built because Activity Monitor doesn't group subprocess memory under the parent app, and because tools that don't use the same memory metric as Activity Monitor produce numbers that just don't agree with it.

## Problem statement

Activity Monitor's Memory tab has two practical gaps:
1. **No combined view per app.** A single app like Chrome shows up as a dozen-plus unrelated rows (`Google Chrome`, `Google Chrome Helper`, `Google Chrome Helper (Renderer)` ×N, `Google Chrome Helper (GPU)`, ...) with no total. To find out how much RAM "Chrome" is actually using, you have to manually find and add up every helper row yourself.
2. **No way to act on what you find.** Activity Monitor can show you the offender, but terminating it (especially a system process) requires the separate Force Quit dialog, and there's no quick filter to just look at your own apps versus the OS's background processes.

A correct fix also has to get one detail right that's easy to get wrong: Activity Monitor's "Memory" column is `phys_footprint`, not resident set size (RSS). A tool that reads RSS instead will produce numbers that visibly disagree with Activity Monitor for the same process — looking "off" even if the rest of the logic is sound.

## Solution

RAMWatcher is a menu-bar app + a small privileged background daemon that:
- **Groups subprocesses under their parent app** and shows one combined memory total per app, using a PPID-tree walk (catches helpers that stay child processes, e.g. Chrome/Electron renderers) plus a bundle-path fallback (catches XPC services that launchd reparents away from their app).
- **Reads memory the same way Activity Monitor does** (`phys_footprint`, not RSS) — validated directly against Activity Monitor: it reported `node` at 5.08 GB and `python3.11` at 2.88 GB; RAMWatcher reported 5.078 GB and 2.877 GB for the same PIDs at the same moment.
- **Filters to just your apps or just system processes**, and lets you **terminate any app or individual process** — including system ones — directly from the list, with a hardcoded blocklist (`kernel_task`, `launchd`, `WindowServer`, etc.) that refuses to kill anything that would destabilize the session.

## Why the numbers match Activity Monitor

Activity Monitor's "Memory" column is `phys_footprint`, not resident set size (RSS). RAMWatcher reads memory the same way (`proc_pid_rusage` → `ri_phys_footprint`), so its numbers agree with Activity Monitor instead of disagreeing the way an RSS-based tool would. Validated directly: Activity Monitor showed `node` at 5.08 GB and `python3.11` at 2.88 GB; RAMWatcher's daemon reported 5.078 GB and 2.877 GB for the same PIDs at the same moment.

### Two different "total" numbers, both shown

- **Memory Used** — real system-wide pressure: `(active + wired + compressed pages) * page_size`, via `host_statistics64`. This is what the menu bar percentage shows, and matches what Activity Monitor's gauge / Stats-style tools report (validated: RAMWatcher computed 85% vs Stats showing 86% at the same moment).
- **App Memory** — sum of every group's `phys_footprint`. Always lower than Memory Used, because wired kernel/GPU/driver memory and the compressor's own bookkeeping aren't attributable to any single process — on a 64 GB Mac under load this gap was ~13 GB (App Memory) vs ~55 GB (Memory Used). This is not a bug; if you only show the per-app sum as "RAM used" it will look misleadingly low next to every other memory tool on macOS.

## Architecture

```
Menu bar app (your user account)  <-- unix socket, JSON -->  RAMWatcherDaemon (root, LaunchDaemon)
```

Reading another user's or a system process's memory, and sending it a kill signal, both require root (`proc_pid_rusage`/`kill()` return EPERM across UID boundaries otherwise). So the daemon — not the UI — does the privileged sampling and the killing; the menu bar app is a thin display/control client. This is also why "hide system processes" only hides them from the *view* — the daemon still has to read them to give you the choice.

- `Sources/RAMWatcherCore` — process sampling (libproc/Darwin), app grouping (PPID tree + bundle-path fallback for launchd-reparented XPC helpers), the kill blocklist, and the JSON wire protocol shared by both executables.
- `Sources/RAMWatcherDaemon` — root LaunchDaemon: samples every 1.5s, serves snapshots and kill requests over a Unix domain socket at `/var/run/ramwatcher.sock`.
- `Sources/RAMWatcherApp` — SwiftUI menu-bar UI (`MenuBarExtra`), polls the daemon every 2s, filter/search/expand/kill controls.

## Grouping limitation (real, not hand-waved)

Helpers that stay child processes of their app (Chrome's renderers, Electron helpers) group correctly via the PPID walk. XPC services that launchd reparents away from their app are caught by a secondary bundle-path heuristic instead. There's no public API for the "responsible process" relationship Activity Monitor itself uses internally (it's a private SPI), so a small number of helper processes may still end up as their own singleton group rather than nested under the right app. If that turns out to matter in practice, the fix is a manual override list, not a deeper API — flag it if you see a specific case.

## Kill behavior

- **Quit** sends SIGTERM (graceful); **Force Quit** (one level behind a "..." menu, so it's reachable but not an accidental click) sends SIGKILL.
- A hardcoded blocklist refuses to kill `kernel_task`, `launchd`, `WindowServer`, PID 0/1, and several other core daemons — enforced in the daemon itself, not just the UI, so it can't be bypassed.
- Killing a launchd-managed daemon that isn't blocklisted may just respawn it. That's launchd doing its job, not a bug.
- Filter control (All / User Only / System Only) doubles as "hide system processes" — pick **User Only** to hide them entirely.

## Refresh rate

The daemon resamples all processes every **1.5s**; the menu bar app polls the daemon every **2s**. Worst case the number on screen is ~3.5s stale. Both are hardcoded constants in `Sources/RAMWatcherDaemon/main.swift` and `Sources/RAMWatcherApp/AppModel.swift` (`pollInterval`) — change them there if you want it snappier or want to cut sampling overhead.

## Build & install

```bash
git clone https://github.com/ganoliya/RAMWatcher.git
cd RAMWatcher
./Scripts/build_app.sh                          # no sudo — builds dist/RAMWatcher.app and dist/RAMWatcherDaemon
cp -R dist/RAMWatcher.app /Applications/RAMWatcher.app   # so macOS registers it as a normal launchable app
open /Applications/RAMWatcher.app               # menu bar icon appears; shows "daemon not running" until the next step

sudo ./Scripts/install_daemon.sh    # the one privileged step — installs + starts the LaunchDaemon
```

To remove the daemon later: `sudo ./Scripts/uninstall_daemon.sh`.

Both the app and the daemon are ad-hoc signed (`codesign --sign -`) — fine for running on this Mac, since this isn't being distributed or notarized.

**After changing daemon code**, `build_app.sh` only rebuilds the local `dist/` artifact — you must re-run `sudo ./Scripts/install_daemon.sh` to replace the installed binary, since it copies into `/usr/local/libexec/ramwatcher/`.

## Status

All 5 planned phases are implemented, build cleanly (`swift build`), and have been run end-to-end on this Mac with the LaunchDaemon actually installed as root (not just component-tested):
1. Sampler/grouping/blocklist validated against Activity Monitor (phys_footprint match, see above) and against a non-root EPERM check.
2. Privileged daemon with Unix socket protocol: snapshot fetch, blocked/permitted/no-such-process kill outcomes, SIGPIPE survival, clean shutdown — all tested manually, then confirmed running for real as a LaunchDaemon.
3. SwiftUI menu bar UI: live RAM total, sortable/searchable/filterable grouped list, expandable subprocess tree, per-group and per-process kill with confirmation dialogs, friendly "daemon not running" state — confirmed via screenshot from the actual running app.
4. Kill guardrails (blocklist) enforced server-side.
5. Build/install/uninstall scripts; this README.

Known gap: no automated GUI test harness exists for the SwiftUI interactions (expand/search/kill flows) — those were verified by reasoning over the code plus one direct screenshot of the daemon-not-running state, not a full click-through of every control.

## License

MIT — see [LICENSE](LICENSE).
