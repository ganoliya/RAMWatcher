import Darwin

/// System-wide memory figures. Both calls are unprivileged and cheap (a
/// sysctl and a single Mach host query), so the UI app reads them directly
/// for the menu bar percentage instead of round-tripping through the root
/// daemon and its full process scan.
public enum SystemMemory {
    public static func totalBytes() -> UInt64 {
        var size: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        let result = sysctlbyname("hw.memsize", &size, &len, nil, 0)
        return result == 0 ? size : 0
    }

    /// Real system-wide used memory: active + wired + compressed pages, the
    /// same inputs Activity Monitor's pressure gauge and Stats-style menu bar
    /// tools use. Deliberately NOT the sum of per-process phys_footprint:
    /// that sum excludes wired kernel/GPU/driver memory and the compressor's
    /// own bookkeeping, which is why a per-app sum alone reads much lower
    /// than the system's actual memory pressure.
    public static func usedBytes() -> UInt64 {
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { statsPtr -> kern_return_t in
            statsPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let usedPages = UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return usedPages * UInt64(pageSize)
    }

    /// Used / total, or nil if either figure couldn't be read.
    public static func usedFraction() -> Double? {
        let total = totalBytes()
        guard total > 0 else { return nil }
        let used = usedBytes()
        guard used > 0 else { return nil }
        return Double(used) / Double(total)
    }
}
