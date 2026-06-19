import Foundation

/// Groups raw `[ProcessInfo]` into app-level `[ProcessGroup]`s.
///
/// Two strategies are combined:
///
/// 1. **PPID tree walk** — build a parent -> children map and, for every
///    process, walk up the ppid chain to find the closest ancestor that
///    looks like a top-level app: either its `execPath` contains
///    `.app/Contents/MacOS/`, or it has no app-bundled ancestor at all
///    (ppid chain bottoms out at ppid 1 / launchd without ever entering a
///    `.app` bundle) — in which case the process is itself the top-level
///    "app" for itself and its descendants.
///
/// 2. **Bundle-path fallback** — macOS frequently reparents XPC services
///    to launchd (ppid 1) once their original spawning app's process
///    exits or as part of normal XPC lifecycle management. Such a service
///    is still very much "part of" some app from a user's mental model,
///    but a pure PPID walk sees it as its own unrelated top-level
///    process, sitting right under launchd. To catch this, any process
///    whose `execPath` contains a `.app/` segment is additionally keyed by
///    its bundle path (everything up to and including `Something.app`),
///    and merged into the same group as any other process/group sharing
///    that bundle path — even when there is no ancestor/descendant
///    relationship between them at all.
///
/// This bundle-path fallback is a real, deliberate limitation worth
/// stating plainly: it is a heuristic patch for a gap in the PPID-walk
/// model, not a fully general solution. Two unrelated processes that
/// happen to share a bundle path (e.g. two independently-launched helper
/// tools from the same app bundle, with no shared ancestry at all) will
/// still be merged into one group by this logic, which is the desired
/// behavior for grouping purposes but means `ProcessGroup.mainPID` is a
/// heuristic choice (lowest-PID / earliest-seen top-level process for
/// that bundle), not a guaranteed "real" parent.
public struct ProcessGrouper {

    public init() {}

    public func group(_ processes: [ProcessInfo]) -> [ProcessGroup] {
        guard !processes.isEmpty else { return [] }

        let byPID: [Int32: ProcessInfo] = Dictionary(
            processes.map { ($0.pid, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var childrenOf: [Int32: [Int32]] = [:]
        for p in processes {
            childrenOf[p.ppid, default: []].append(p.pid)
        }

        // Step 1: PPID-walk — find each process's top-level app ancestor.
        var topLevelPID: [Int32: Int32] = [:] // pid -> its top-level ancestor pid
        for p in processes {
            topLevelPID[p.pid] = findTopLevelAncestor(for: p.pid, byPID: byPID)
        }

        // Initial grouping by top-level ancestor pid.
        var membersByMain: [Int32: [Int32]] = [:]
        for p in processes {
            let main = topLevelPID[p.pid] ?? p.pid
            membersByMain[main, default: []].append(p.pid)
        }

        // Step 2: bundle-path fallback — merge groups whose top-level
        // process (or any member, to catch reparented XPC services) shares
        // a bundle path with another group's top-level process.
        var mainPIDForBundle: [String: Int32] = [:]
        // Union-find-lite: map from a "losing" main pid to the "winning" main pid it was merged into.
        var redirect: [Int32: Int32] = [:]

        func resolve(_ main: Int32) -> Int32 {
            var current = main
            while let next = redirect[current] {
                current = next
            }
            return current
        }

        // Process groups in a stable order (by main pid) so merges are deterministic.
        let mainsInOrder = membersByMain.keys.sorted()
        for main in mainsInOrder {
            guard let memberPIDs = membersByMain[main] else { continue }
            // Find a bundle path among this group's members (prefer the
            // main process's own path, else any member's).
            var groupBundlePath: String?
            if let mainProc = byPID[main], let bp = bundlePath(from: mainProc.execPath) {
                groupBundlePath = bp
            } else {
                for pid in memberPIDs {
                    if let bp = byPID[pid].flatMap({ bundlePath(from: $0.execPath) }) {
                        groupBundlePath = bp
                        break
                    }
                }
            }
            guard let bp = groupBundlePath else { continue }

            if let existingMain = mainPIDForBundle[bp] {
                let canonicalExisting = resolve(existingMain)
                let canonicalCurrent = resolve(main)
                if canonicalExisting != canonicalCurrent {
                    redirect[canonicalCurrent] = canonicalExisting
                }
            } else {
                mainPIDForBundle[bp] = main
            }
        }

        // Apply redirects to build final member lists per canonical main pid.
        var finalMembers: [Int32: [Int32]] = [:]
        for (main, memberPIDs) in membersByMain {
            let canonical = resolve(main)
            finalMembers[canonical, default: []].append(contentsOf: memberPIDs)
        }

        // Step 3: build ProcessGroup values.
        var groups: [ProcessGroup] = []
        for (mainPID, memberPIDs) in finalMembers {
            let members = memberPIDs.compactMap { byPID[$0] }
            guard !members.isEmpty else { continue }

            let mainProc = byPID[mainPID] ?? members.min(by: { $0.pid < $1.pid })!
            let totalFootprint = members.reduce(UInt64(0)) { $0 + $1.physFootprintBytes }
            let resolvedBundlePath = bundlePath(from: mainProc.execPath)
                ?? members.lazy.compactMap { bundlePath(from: $0.execPath) }.first
            let displayName = productName(fromBundlePath: resolvedBundlePath) ?? mainProc.name
            let isProtected = members.contains { KillBlocklist.isProtected(pid: $0.pid, name: $0.name) }

            groups.append(ProcessGroup(
                mainPID: mainProc.pid,
                displayName: displayName,
                bundlePath: resolvedBundlePath,
                isUserOwned: mainProc.isUserOwned,
                totalFootprintBytes: totalFootprint,
                members: members.sorted { $0.pid < $1.pid },
                isProtected: isProtected
            ))
        }

        return groups.sorted { $0.totalFootprintBytes > $1.totalFootprintBytes }
    }

    // MARK: - PPID walk

    /// Walks up the ppid chain from `pid` to find the closest ancestor
    /// that qualifies as a top-level app (per the heuristic in the type's
    /// doc comment). Falls back to `pid` itself if no qualifying ancestor
    /// is found (e.g. ppid chain breaks because an ancestor already
    /// exited and was reaped, or it bottoms out at launchd).
    private func findTopLevelAncestor(for pid: Int32, byPID: [Int32: ProcessInfo]) -> Int32 {
        var current = pid
        var visited = Set<Int32>()
        var lastSeenAppAncestor: Int32?

        while let proc = byPID[current], !visited.contains(current) {
            visited.insert(current)

            if isAppBundleProcess(proc) {
                lastSeenAppAncestor = proc.pid
            }

            let parentPID = proc.ppid
            // ppid 1 is launchd, or 0 is kernel: stop walking.
            if parentPID <= 1 || parentPID == current {
                break
            }
            guard byPID[parentPID] != nil else {
                // Parent already exited / not in this snapshot: stop here.
                break
            }
            current = parentPID
        }

        if let appAncestor = lastSeenAppAncestor {
            return appAncestor
        }
        // No app-bundled ancestor found anywhere in the chain: this
        // process (the one closest to launchd, i.e. where the walk
        // stopped) is the top-level "app" for itself and its descendants.
        return current
    }

    private func isAppBundleProcess(_ proc: ProcessInfo) -> Bool {
        guard let path = proc.execPath else { return false }
        return path.contains(".app/Contents/MacOS/")
    }

    // MARK: - Bundle path helpers

    /// Extracts everything up to and including `Something.app` from an
    /// executable path, or nil if the path doesn't contain a `.app` segment.
    private func bundlePath(from execPath: String?) -> String? {
        guard let path = execPath else { return nil }
        guard let range = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app") : nil) else {
            return nil
        }
        return String(path[path.startIndex..<range.upperBound]).trimmingTrailingSlash()
    }

    /// Derives a product display name from a bundle path, e.g.
    /// `/Applications/Safari.app` -> `Safari`.
    private func productName(fromBundlePath bundlePath: String?) -> String? {
        guard let bundlePath else { return nil }
        let trimmed = bundlePath.hasSuffix("/") ? String(bundlePath.dropLast()) : bundlePath
        guard let lastComponent = trimmed.split(separator: "/").last else { return nil }
        guard lastComponent.hasSuffix(".app") else { return nil }
        return String(lastComponent.dropLast(".app".count))
    }
}

private extension String {
    func trimmingTrailingSlash() -> String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}
