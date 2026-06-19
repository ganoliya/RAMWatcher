# RAMWatcher

A menu-bar RAM usage monitor for macOS — built because Activity Monitor doesn't group subprocess memory under the parent app, and because tools that don't use the same memory metric as Activity Monitor produce numbers that just don't agree with it.

## In plain English

Your Mac has a fixed amount of memory, and when it fills up, everything slows down: apps stutter, you get the spinning beachball, the fan kicks in. macOS already has a tool to show you what's using all that memory — Activity Monitor — but it was built for engineers, not for a quick glance. It lists dozens of cryptically-named background helper processes as separate, unconnected rows, so even though it's *technically* showing you the answer, you can't actually see it without doing manual detective work first.

RAMWatcher sits quietly in your menu bar and answers the question Activity Monitor won't: "which app is actually using my RAM, and can I just close it?" — one row per app you recognize, with a button to quit it right there.

## The problem

Open Activity Monitor on a Mac that's running hot and sort by memory. For one single app — say, Chrome with a bunch of tabs open — you won't see one number. You'll see something like this:

```
Google Chrome                       276 MB
Google Chrome Helper                344 MB
Google Chrome Helper (Renderer)     556 MB
Google Chrome Helper (Renderer)     434 MB
Google Chrome Helper (Renderer)     181 MB
... 15 more rows, same app
```

That's a real capture from this machine — 20 separate rows, all of them Chrome, adding up to over **2 GB**, and Activity Monitor never tells you that. It just shows you the rows. To answer "how much RAM is Chrome actually using," you have to recognize that a dozen-plus oddly-named processes are secretly the same app, then add them up yourself, by hand, every time. Do that across Slack, VS Code, your browser, and every other app built on Electron or Chromium, and "what's eating my memory" stops being a five-second glance and turns into a small research project.

And once you've found the actual offender, Activity Monitor's only response is a separate Force Quit window, with no quick way to filter out the 80+ system processes you'll never care about and look at just your own apps.

A correct fix also has to get one technical detail right that's easy to get subtly wrong: Activity Monitor's "Memory" column is `phys_footprint`, not resident set size (RSS) — the more commonly-used metric. A tool that reads RSS instead will produce numbers that visibly disagree with Activity Monitor for the exact same process, undermining trust in the tool even if everything else about it is correct.

## The solution

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
RAMWatcher.app
├── Contents/MacOS/RAMWatcherApp        (menu bar UI, your user account)
├── Contents/MacOS/RAMWatcherDaemon     (embedded daemon, runs as root)
└── Contents/Library/LaunchDaemons/com.himanshu.ramwatcher.daemon.plist
```

Reading another user's or a system process's memory, and sending it a kill signal, both require root (`proc_pid_rusage`/`kill()` return EPERM across UID boundaries otherwise). So the daemon — not the UI — does the privileged sampling and the killing; the menu bar app is a thin display/control client talking to it over a Unix socket. This is also why "hide system processes" only hides them from the *view* — the daemon still has to read them to give you the choice.

The daemon ships **inside** the app bundle and registers itself at launch via Apple's `SMAppService` API (ServiceManagement framework, macOS 13+) — the modern replacement for manually installing a LaunchDaemon via a sudo script. The only user-facing step is a one-time consent click in **System Settings → General → Login Items & Extensions → Allow in the Background**; no admin password is ever typed. This requires the app to be signed with a real Apple Developer ID (ad-hoc signing is enough to run locally, but `SMAppService.register()` will not work without a Developer ID signature).

- `Sources/RAMWatcherCore` — process sampling (libproc/Darwin), app grouping (PPID tree + bundle-path fallback for launchd-reparented XPC helpers), the kill blocklist, and the JSON wire protocol shared by both executables.
- `Sources/RAMWatcherDaemon` — the embedded root daemon: samples every 1.5s, serves snapshots and kill requests over a Unix domain socket at `/var/run/ramwatcher.sock`.
- `Sources/RAMWatcherApp` — SwiftUI menu-bar UI (`MenuBarExtra`), polls the daemon every 2s, filter/search/expand/kill controls, and `DaemonInstaller.swift` which drives `SMAppService` registration.

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
./Scripts/build_app.sh                                    # builds dist/RAMWatcher.app
cp -R dist/RAMWatcher.app /Applications/RAMWatcher.app
open /Applications/RAMWatcher.app
```

That's it — there is no separate privileged install step. On first launch the app registers its embedded daemon automatically; macOS will prompt you once to approve it in **System Settings → General → Login Items & Extensions → Allow in the Background**.

`build_app.sh` auto-detects a `Developer ID Application` signing identity in your keychain and uses it (with the hardened runtime, required for `SMAppService` and for notarization). Without one, it falls back to ad-hoc signing — the app still runs locally, but daemon registration will not succeed without a real Developer ID, since `SMAppService` requires it.

To remove RAMWatcher: delete `RAMWatcher.app` from `/Applications`. (`Scripts/uninstall_daemon.sh` is legacy cleanup only — for anyone who installed a pre-SMAppService version that used a manually-installed LaunchDaemon.)

**Not yet done:** notarization and a `.dmg` for distribution outside this machine. The app is currently signed but not notarized, so Gatekeeper will warn on a machine that downloaded it (no warning on a machine that built it locally, since there's no quarantine flag).

## Status

All 5 originally planned phases are implemented and build cleanly (`swift build`). Since then, the daemon installation mechanism was rewritten from a manual sudo-run LaunchDaemon install to a self-registering `SMAppService` daemon embedded in the app bundle, now that a real Apple Developer ID is available for signing:

1. Sampler/grouping/blocklist validated against Activity Monitor (phys_footprint match, see above) and against a non-root EPERM check.
2. Daemon with Unix socket protocol: snapshot fetch, blocked/permitted/no-such-process kill outcomes, SIGPIPE survival, clean shutdown — tested manually, then confirmed running for real, first as a manually-installed LaunchDaemon and now via `SMAppService`.
3. SwiftUI menu bar UI: live RAM total, sortable/searchable/filterable grouped list, expandable subprocess tree, per-group and per-process kill with confirmation dialogs, daemon-registration-aware status UI (pending approval / starting / failed states).
4. Kill guardrails (blocklist) enforced server-side.
5. Build script (now embeds + Developer ID signs in one step); this README; [CHANGELOG.md](CHANGELOG.md).

Known gap: no automated GUI test harness exists for the SwiftUI interactions (expand/search/kill flows) — those were verified by reasoning over the code, direct inspection of the code signature and the macOS Background Task Management database (`sfltool dumpbtm`), and system log output, rather than a full click-through of every control.

## License

MIT — see [LICENSE](LICENSE).
