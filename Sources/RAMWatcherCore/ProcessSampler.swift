import Darwin
import Foundation

/// Samples the current process table into `[ProcessInfo]`.
///
/// Memory is read via `proc_pid_rusage(pid, RUSAGE_INFO_V2, ...)` and the
/// `ri_phys_footprint` field — this is what Activity Monitor's "Memory"
/// column actually shows, and it differs meaningfully from RSS. Using
/// `proc_pidinfo`'s resident-size fields instead would produce numbers
/// that visibly disagree with Activity Monitor, so that path is
/// deliberately not used anywhere in this type.
public struct ProcessSampler {

    public init() {}

    /// Enumerates all live PIDs and samples each one. PIDs that error out
    /// (zombies, EPERM because we're not root and don't own the process,
    /// or a race where the process exits mid-scan) are skipped rather than
    /// causing a crash or aborting the whole sample.
    public func sampleAll() -> [ProcessInfo] {
        let pids = listAllPIDs()
        var results: [ProcessInfo] = []
        results.reserveCapacity(pids.count)

        for pid in pids {
            if let info = sample(pid: pid) {
                results.append(info)
            }
        }
        return results
    }

    // MARK: - Single-process sampling

    private func sample(pid: Int32) -> ProcessInfo? {
        guard pid > 0 else { return nil }

        var bsdInfo = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let bsdResult = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, bsdSize)
        guard bsdResult == bsdSize else {
            // Process likely exited mid-scan, or we don't have permission
            // to query it at all (PROC_PIDTBSDINFO is normally readable
            // for any pid, but treat any short/failed read as "skip").
            return nil
        }

        let ppid = Int32(bitPattern: bsdInfo.pbi_ppid)
        let uid = bsdInfo.pbi_uid

        let name = processName(pid: pid, bsdInfo: bsdInfo)
        let execPath = processPath(pid: pid)

        guard let footprint = physFootprint(pid: pid) else {
            // EPERM (not root, not our UID) or the process exited just
            // after the bsdinfo read above — skip gracefully.
            return nil
        }

        let isUserOwned = uid >= 501

        return ProcessInfo(
            pid: pid,
            ppid: ppid,
            uid: uid,
            name: name,
            execPath: execPath,
            physFootprintBytes: footprint,
            isUserOwned: isUserOwned
        )
    }

    // MARK: - libproc helpers

    private func listAllPIDs() -> [Int32] {
        let initialCapacityHint = proc_listallpids(nil, 0)
        guard initialCapacityHint > 0 else { return [] }

        // Over-allocate a bit: the process table can grow between the
        // sizing call and the fetch call.
        var attempts = 0
        var buffer: [Int32] = []
        while attempts < 3 {
            let capacity = Int(initialCapacityHint) + 64 + (attempts * 128)
            buffer = [Int32](repeating: 0, count: capacity)
            let bufferSizeBytes = Int32(capacity * MemoryLayout<Int32>.size)
            let actualBytes = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
                proc_listallpids(ptr.baseAddress, bufferSizeBytes)
            }
            guard actualBytes > 0 else { return [] }

            // Despite the documented "returns bytes" contract, empirically
            // (verified against `ps` on macOS 15/Sequoia) this call returns
            // a PID count here, both with a NULL buffer and with a real
            // one -- dividing by sizeof(Int32) was silently keeping only
            // ~1/4 of all running processes, which is why some apps'
            // process trees (e.g. Chrome, with PIDs the truncated buffer
            // never reached) were sampled incompletely, leading to
            // partial/broken kills. The buffersize argument itself is
            // still a byte count -- only the *return value*'s unit was
            // wrong here.
            let count = Int(actualBytes)
            if count <= buffer.count {
                return Array(buffer.prefix(count)).filter { $0 > 0 }
            }
            attempts += 1
        }
        return buffer.filter { $0 > 0 }
    }

    private func processName(pid: Int32, bsdInfo: proc_bsdinfo) -> String {
        // pbi_name is empty for processes that never registered a name
        // (e.g. some system processes); fall back to proc_name().
        let bsdName = withUnsafeBytes(of: bsdInfo.pbi_name) { raw -> String in
            let bytes = raw.bindMemory(to: CChar.self)
            return String(cString: bytes.baseAddress!)
        }
        if !bsdName.isEmpty {
            return bsdName
        }

        var nameBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let len = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        if len > 0 {
            return String(cString: nameBuffer)
        }
        return "pid \(pid)"
    }

    private func processPath(pid: Int32) -> String? {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let len = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard len > 0 else { return nil }
        return String(cString: pathBuffer)
    }

    private func physFootprint(pid: Int32) -> UInt64? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reboundPtr in
                proc_pid_rusage(pid, RUSAGE_INFO_V2, reboundPtr)
            }
        }
        // EPERM (not root / not our UID), ESRCH (exited mid-scan), etc.
        // all surface as a non-zero return here — skip gracefully.
        guard result == 0 else { return nil }
        return info.ri_phys_footprint
    }
}
