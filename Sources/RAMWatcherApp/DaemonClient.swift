import Darwin
import Foundation
import RAMWatcherCore

/// Errors surfaced by `DaemonClient` to the UI layer. Always carries a
/// human-readable message suitable for direct display.
struct DaemonClientError: Error, CustomStringConvertible, LocalizedError {
    let description: String
    var errorDescription: String? { description }

    static let notRunning = DaemonClientError(description: "RAMWatcher daemon is not running.")
    static let connectionLost = DaemonClientError(description: "Lost connection to the RAMWatcher daemon.")

    static func wrongResponse(_ response: Response) -> DaemonClientError {
        DaemonClientError(description: "Daemon returned an unexpected response for this request.")
    }

    static func system(_ call: String, errno code: Int32) -> DaemonClientError {
        DaemonClientError(description: "RAMWatcher daemon is not running. (\(call) failed: \(String(cString: strerror(code))))")
    }
}

/// A client for the RAMWatcher daemon's Unix domain socket. Speaks
/// newline-delimited JSON `Request`/`Response` pairs over a persistent
/// stream connection, matching `RAMWatcherDaemon`'s `SocketServer`.
///
/// Connects lazily and reconnects on demand: every call checks whether the
/// socket is alive and (re)connects if not. This is the expected steady
/// state during development, since the daemon is typically not installed
/// as a LaunchDaemon yet -- callers should expect `DaemonClientError` to be
/// thrown frequently and show a friendly "daemon not running" UI state
/// rather than treating it as exceptional.
actor DaemonClient {
    private let socketPath: String
    private var fd: Int32 = -1

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// `socketPath` defaults to the production `IPC.socketPath`, but honors
    /// `RAMWATCHER_SOCKET_PATH` for local dev/testing against a
    /// non-root-launched daemon, mirroring the daemon's own debug override.
    init(socketPath: String = Foundation.ProcessInfo.processInfo.environment["RAMWATCHER_SOCKET_PATH"] ?? IPC.socketPath) {
        self.socketPath = socketPath
    }

    deinit {
        if fd >= 0 {
            close(fd)
        }
    }

    // MARK: - Public API

    func fetchSnapshot() async throws -> Snapshot {
        let response = try await send(.getSnapshot)
        guard case .snapshot(let snapshot) = response else {
            throw DaemonClientError.wrongResponse(response)
        }
        return snapshot
    }

    func kill(pid: Int32, signal: KillSignal) async throws -> (ActionOutcome, String) {
        let response = try await send(.killProcess(pid: pid, signal: signal))
        guard case .actionResult(let outcome, let message) = response else {
            throw DaemonClientError.wrongResponse(response)
        }
        return (outcome, message)
    }

    func killGroup(mainPID: Int32, signal: KillSignal) async throws -> (ActionOutcome, String) {
        let response = try await send(.killGroup(mainPID: mainPID, signal: signal))
        guard case .actionResult(let outcome, let message) = response else {
            throw DaemonClientError.wrongResponse(response)
        }
        return (outcome, message)
    }

    // MARK: - Connection management

    private func ensureConnected() throws {
        if fd >= 0 { return }

        let newFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard newFD >= 0 else {
            throw DaemonClientError.notRunning
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(newFD)
            throw DaemonClientError(description: "RAMWatcher daemon is not running. (socket path too long: \(socketPath))")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { rawPtr in
            let buffer = rawPtr.bindMemory(to: CChar.self)
            for (i, byte) in pathBytes.enumerated() {
                buffer[i] = CChar(bitPattern: byte)
            }
            buffer[pathBytes.count] = 0
        }

        let addrSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(newFD, sockPtr, addrSize)
            }
        }

        guard connectResult == 0 else {
            let savedErrno = errno
            close(newFD)
            // ECONNREFUSED (socket file exists, nobody listening) and
            // ENOENT (socket file doesn't exist at all -- daemon never
            // installed) both mean "no daemon": surface a single friendly
            // message rather than leaking raw errno text in the common
            // case.
            if savedErrno == ECONNREFUSED || savedErrno == ENOENT {
                throw DaemonClientError.notRunning
            }
            throw DaemonClientError.system("connect", errno: savedErrno)
        }

        fd = newFD
    }

    /// Tears down the current connection so the next call reconnects from
    /// scratch. Used whenever a read/write fails on an established socket.
    private func disconnect() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    // MARK: - Request/response framing

    private func send(_ request: Request) async throws -> Response {
        try ensureConnected()

        var requestData: Data
        do {
            requestData = try encoder.encode(request)
        } catch {
            throw DaemonClientError(description: "Failed to encode request: \(error.localizedDescription)")
        }
        requestData.append(0x0A)

        do {
            try writeAll(requestData)
            return try readLine()
        } catch let error as DaemonClientError {
            // Any framing failure on a previously-good connection likely
            // means the daemon went away mid-session; drop the socket so
            // the next call attempts a fresh connect instead of repeatedly
            // failing on a dead fd.
            disconnect()
            throw error
        }
    }

    private func writeAll(_ data: Data) throws {
        var remaining = data
        while !remaining.isEmpty {
            let bytesWritten = remaining.withUnsafeBytes { ptr -> Int in
                write(fd, ptr.baseAddress, ptr.count)
            }
            if bytesWritten <= 0 {
                if errno == EINTR { continue }
                throw DaemonClientError.connectionLost
            }
            remaining.removeFirst(bytesWritten)
        }
    }

    private func readLine() throws -> Response {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)

        while true {
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                do {
                    return try decoder.decode(Response.self, from: lineData)
                } catch {
                    throw DaemonClientError(description: "Failed to decode daemon response: \(error.localizedDescription)")
                }
            }

            let bytesRead = chunk.withUnsafeMutableBytes { ptr -> Int in
                read(fd, ptr.baseAddress, ptr.count)
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw DaemonClientError.connectionLost
            }
            if bytesRead == 0 {
                // EOF: daemon closed the connection.
                throw DaemonClientError.connectionLost
            }
            buffer.append(chunk, count: bytesRead)
        }
    }
}
