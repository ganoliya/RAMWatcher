import Darwin
import Foundation
import RAMWatcherCore

// MARK: - Snapshot cache

/// Thread-safe holder for the most recently sampled snapshot. The
/// sampling loop writes to this on a 1.5s cadence; socket-server client
/// threads read from it on every `.getSnapshot` request.
final class SnapshotCache: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Snapshot

    init(initial: Snapshot) {
        self.current = initial
    }

    func get() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func set(_ snapshot: Snapshot) {
        lock.lock()
        defer { lock.unlock() }
        current = snapshot
    }
}

// MARK: - System memory

func totalPhysicalMemoryBytes() -> UInt64 {
    var size: UInt64 = 0
    var len = MemoryLayout<UInt64>.size
    let result = sysctlbyname("hw.memsize", &size, &len, nil, 0)
    return result == 0 ? size : 0
}

/// Real system-wide used memory: active + wired + compressed pages, the
/// same inputs Activity Monitor's pressure gauge and Stats-style menu bar
/// tools use. Deliberately NOT the sum of per-process phys_footprint --
/// that sum excludes wired kernel/GPU/driver memory and the compressor's
/// own bookkeeping, which is why a per-app sum alone reads much lower
/// than the system's actual memory pressure.
func usedPhysicalMemoryBytes() -> UInt64 {
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

// MARK: - Logging

func logLine(_ message: String) {
    FileHandle.standardError.write(("[ramwatcherd] " + message + "\n").data(using: .utf8)!)
}

// MARK: - Sampling loop

let sampler = ProcessSampler()
let grouper = ProcessGrouper()

func takeSnapshot() -> Snapshot {
    let processes = sampler.sampleAll()
    let groups = grouper.group(processes)
    return Snapshot(
        takenAt: Date(),
        totalPhysicalMemoryBytes: totalPhysicalMemoryBytes(),
        usedPhysicalMemoryBytes: usedPhysicalMemoryBytes(),
        groups: groups
    )
}

let cache = SnapshotCache(initial: takeSnapshot())

let samplingThread = Thread {
    while true {
        Thread.sleep(forTimeInterval: 1.5)
        let snapshot = takeSnapshot()
        cache.set(snapshot)
    }
}
samplingThread.name = "ramwatcherd.sampler"
samplingThread.start()

// MARK: - JSON coding

let jsonEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}()

let jsonDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}()

// MARK: - Kill helpers

enum KillError {
    case blocked(String)
    case notPermitted
    case noSuchProcess
    case other(String)
}

/// Sends `signal` to `pid` after checking the blocklist. Returns nil on
/// success, or the failure reason.
func killPID(_ pid: Int32, name: String, signal: KillSignal) -> KillError? {
    if KillBlocklist.isProtected(pid: pid, name: name) {
        return .blocked("pid \(pid) (\(name)) is protected and cannot be killed")
    }
    let sig = signal == .terminate ? SIGTERM : SIGKILL
    let result = kill(pid, sig)
    guard result == -1 else { return nil }
    switch errno {
    case EPERM:
        return .notPermitted
    case ESRCH:
        return .noSuchProcess
    default:
        return .other(String(cString: strerror(errno)))
    }
}

func handleKillProcess(pid: Int32, signal: KillSignal) -> Response {
    // Find the process's name from the latest snapshot if we have it, so
    // the blocklist can match on name as well as pid. If the pid isn't
    // in our cached snapshot (e.g. it's brand new), fall back to an
    // empty name -- the pid-based blocklist checks (0, 1) still apply.
    let snapshot = cache.get()
    let name = snapshot.groups
        .flatMap(\.members)
        .first(where: { $0.pid == pid })?.name ?? ""

    if let failure = killPID(pid, name: name, signal: signal) {
        return response(for: failure)
    }
    return .actionResult(outcome: .success, message: "Sent \(signal) to pid \(pid)")
}

func handleKillGroup(mainPID: Int32, signal: KillSignal) -> Response {
    let snapshot = cache.get()
    guard let group = snapshot.groups.first(where: { $0.mainPID == mainPID }) else {
        return .actionResult(outcome: .noSuchProcess, message: "No group found with mainPID \(mainPID)")
    }

    if group.isProtected {
        return .actionResult(outcome: .blocked, message: "Group '\(group.displayName)' (mainPID \(mainPID)) contains a protected process and cannot be killed")
    }

    var failures: [String] = []
    for member in group.members {
        if let failure = killPID(member.pid, name: member.name, signal: signal) {
            failures.append("pid \(member.pid) (\(member.name)): \(describe(failure))")
        }
    }

    if failures.isEmpty {
        return .actionResult(outcome: .success, message: "Sent \(signal) to all \(group.members.count) member(s) of '\(group.displayName)'")
    } else {
        return .actionResult(outcome: .error, message: "Some members of '\(group.displayName)' could not be killed: " + failures.joined(separator: "; "))
    }
}

func response(for failure: KillError) -> Response {
    switch failure {
    case .blocked(let message):
        return .actionResult(outcome: .blocked, message: message)
    case .notPermitted:
        return .actionResult(outcome: .notPermitted, message: "Operation not permitted (EPERM)")
    case .noSuchProcess:
        return .actionResult(outcome: .noSuchProcess, message: "No such process (ESRCH)")
    case .other(let message):
        return .actionResult(outcome: .error, message: message)
    }
}

func describe(_ failure: KillError) -> String {
    switch failure {
    case .blocked(let message): return message
    case .notPermitted: return "not permitted"
    case .noSuchProcess: return "no such process"
    case .other(let message): return message
    }
}

func handle(request: Request) -> Response {
    switch request {
    case .getSnapshot:
        return .snapshot(cache.get())
    case .killProcess(let pid, let signal):
        return handleKillProcess(pid: pid, signal: signal)
    case .killGroup(let mainPID, let signal):
        return handleKillGroup(mainPID: mainPID, signal: signal)
    }
}

// MARK: - Unix domain socket server

final class SocketServer {
    private var listenFD: Int32 = -1
    private let socketPath: String

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func start() throws {
        // Remove any stale socket file from a previous run.
        if unlink(socketPath) == -1 && errno != ENOENT {
            logLine("warning: unlink(\(socketPath)) failed: \(String(cString: strerror(errno)))")
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError.fromErrno("socket")
        }
        listenFD = fd

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw POSIXError.custom("socket path too long: \(socketPath)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { rawPtr in
            let buffer = rawPtr.bindMemory(to: CChar.self)
            for (i, byte) in pathBytes.enumerated() {
                buffer[i] = CChar(bitPattern: byte)
            }
            buffer[pathBytes.count] = 0
        }

        let addrSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, addrSize)
            }
        }
        guard bindResult == 0 else {
            throw POSIXError.fromErrno("bind")
        }

        // Permissive permissions so a non-root UI app can connect.
        chmod(socketPath, 0o666)

        guard listen(fd, 16) == 0 else {
            throw POSIXError.fromErrno("listen")
        }

        logLine("listening on \(socketPath)")
    }

    func run() {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else {
                if errno == EINTR { continue }
                logLine("accept failed: \(String(cString: strerror(errno)))")
                continue
            }
            let thread = Thread {
                self.serviceClient(fd: clientFD)
            }
            thread.start()
        }
    }

    /// Services one client connection: reads newline-delimited JSON
    /// requests and writes newline-delimited JSON responses, reusing the
    /// connection for multiple round trips until EOF or a read error.
    private func serviceClient(fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        var readChunk = [UInt8](repeating: 0, count: 4096)

        while true {
            // Look for a newline already buffered before reading more.
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                processLine(lineData, fd: fd)
                continue
            }

            let bytesRead = readChunk.withUnsafeMutableBytes { ptr -> Int in
                read(fd, ptr.baseAddress, ptr.count)
            }
            if bytesRead <= 0 {
                // 0 == EOF, <0 == error: either way, this connection is done.
                return
            }
            buffer.append(readChunk, count: bytesRead)
        }
    }

    private func processLine(_ lineData: Data, fd: Int32) {
        guard !lineData.isEmpty else { return }
        do {
            let request = try jsonDecoder.decode(Request.self, from: lineData)
            let response = handle(request: request)
            var responseData = try jsonEncoder.encode(response)
            responseData.append(0x0A)
            responseData.withUnsafeBytes { ptr in
                _ = write(fd, ptr.baseAddress, ptr.count)
            }
        } catch {
            logLine("failed to decode/handle request: \(error)")
            let errorResponse = Response.actionResult(outcome: .error, message: "Malformed request: \(error)")
            if var data = try? jsonEncoder.encode(errorResponse) {
                data.append(0x0A)
                data.withUnsafeBytes { ptr in
                    _ = write(fd, ptr.baseAddress, ptr.count)
                }
            }
        }
    }

    func shutdown() {
        if listenFD >= 0 {
            close(listenFD)
        }
        if unlink(socketPath) == -1 && errno != ENOENT {
            logLine("warning: unlink on shutdown failed: \(String(cString: strerror(errno)))")
        }
    }
}

enum POSIXError: Error, CustomStringConvertible {
    case fromErrno(String)
    case custom(String)

    var description: String {
        switch self {
        case .fromErrno(let call):
            return "\(call) failed: \(String(cString: strerror(errno)))"
        case .custom(let message):
            return message
        }
    }
}

// MARK: - Signal handling

// The socket path is fixed at `IPC.socketPath` for production (LaunchDaemon)
// use. A debug-only override is honored for local dev/testing as a
// non-root user, since `/var/run` is not writable without root and the
// fixed path is a contract with RAMWatcherApp that must not change.
// Gated behind #if DEBUG so release builds always use the real path.
#if DEBUG
let effectiveSocketPath = Foundation.ProcessInfo.processInfo.environment["RAMWATCHER_SOCKET_PATH"] ?? IPC.socketPath
#else
let effectiveSocketPath = IPC.socketPath
#endif
let server = SocketServer(socketPath: effectiveSocketPath)

func installSignalHandlers() {
    // Without this, writing to a client socket whose peer has already
    // disconnected (e.g. the UI app times out or is killed mid-request)
    // raises SIGPIPE, whose default disposition is to terminate the
    // process -- i.e. it would take down the entire root daemon over a
    // single misbehaving client. Ignoring it makes the offending write(2)
    // simply return -1/EPIPE instead, which serviceClient already treats
    // as "connection done" on the next read.
    signal(SIGPIPE, SIG_IGN)

    signal(SIGTERM) { _ in
        server.shutdown()
        exit(0)
    }
    signal(SIGINT) { _ in
        server.shutdown()
        exit(0)
    }
}

// MARK: - Entry point

installSignalHandlers()

do {
    try server.start()
} catch {
    logLine("failed to start socket server: \(error)")
    exit(1)
}

server.run()
