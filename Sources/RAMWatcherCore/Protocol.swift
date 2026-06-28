import Foundation

/// A single process as reported by the sampler. Memory is always
/// `physFootprint` (matches Activity Monitor's "Memory" column),
/// never raw RSS.
public struct ProcessInfo: Codable, Identifiable, Hashable, Sendable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let ppid: Int32
    public let uid: UInt32
    public let name: String
    public let execPath: String?
    public let physFootprintBytes: UInt64
    public let isUserOwned: Bool
    public let responsiblePID: Int32?
    public let scriptPath: String?

    public init(pid: Int32, ppid: Int32, uid: UInt32, name: String, execPath: String?, physFootprintBytes: UInt64, isUserOwned: Bool, responsiblePID: Int32? = nil, scriptPath: String? = nil) {
        self.pid = pid
        self.ppid = ppid
        self.uid = uid
        self.name = name
        self.execPath = execPath
        self.physFootprintBytes = physFootprintBytes
        self.isUserOwned = isUserOwned
        self.responsiblePID = responsiblePID
        self.scriptPath = scriptPath
    }
}

/// A top-level "app" grouping: a main process plus all descendants/helpers
/// attributed to it via PPID-tree walk or shared bundle path.
public struct ProcessGroup: Codable, Identifiable, Hashable, Sendable {
    public var id: Int32 { mainPID }
    public let mainPID: Int32
    public let displayName: String
    public let bundlePath: String?
    public let isUserOwned: Bool
    public let totalFootprintBytes: UInt64
    public let members: [ProcessInfo]
    /// True if any member PID is in the unkillable blocklist.
    public let isProtected: Bool

    public init(mainPID: Int32, displayName: String, bundlePath: String?, isUserOwned: Bool, totalFootprintBytes: UInt64, members: [ProcessInfo], isProtected: Bool) {
        self.mainPID = mainPID
        self.displayName = displayName
        self.bundlePath = bundlePath
        self.isUserOwned = isUserOwned
        self.totalFootprintBytes = totalFootprintBytes
        self.members = members
        self.isProtected = isProtected
    }
}

public struct Snapshot: Codable, Sendable {
    public let takenAt: Date
    public let totalPhysicalMemoryBytes: UInt64
    /// Real system-wide memory used (active + wired + compressed pages),
    /// matching what Activity Monitor's pressure gauge and "Memory Used"
    /// figure show. This is always >= the sum of `groups[].totalFootprintBytes`
    /// (the per-app figure, Activity Monitor's "App Memory") because wired
    /// kernel/GPU/driver memory and the compressor's own bookkeeping aren't
    /// attributable to any single process.
    public let usedPhysicalMemoryBytes: UInt64
    public let groups: [ProcessGroup]

    public init(takenAt: Date, totalPhysicalMemoryBytes: UInt64, usedPhysicalMemoryBytes: UInt64, groups: [ProcessGroup]) {
        self.takenAt = takenAt
        self.totalPhysicalMemoryBytes = totalPhysicalMemoryBytes
        self.usedPhysicalMemoryBytes = usedPhysicalMemoryBytes
        self.groups = groups
    }
}

public enum KillSignal: String, Codable, Sendable {
    case terminate // SIGTERM, graceful
    case kill      // SIGKILL, force
}

/// Wire request, one JSON object per line over the unix socket.
public enum Request: Codable, Sendable {
    case getSnapshot
    case killProcess(pid: Int32, signal: KillSignal)
    case killGroup(mainPID: Int32, signal: KillSignal)

    private enum CodingKeys: String, CodingKey { case type, pid, mainPID, signal }
    private enum Kind: String, Codable { case getSnapshot, killProcess, killGroup }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .getSnapshot:
            self = .getSnapshot
        case .killProcess:
            self = .killProcess(pid: try c.decode(Int32.self, forKey: .pid), signal: try c.decode(KillSignal.self, forKey: .signal))
        case .killGroup:
            self = .killGroup(mainPID: try c.decode(Int32.self, forKey: .mainPID), signal: try c.decode(KillSignal.self, forKey: .signal))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .getSnapshot:
            try c.encode(Kind.getSnapshot, forKey: .type)
        case .killProcess(let pid, let signal):
            try c.encode(Kind.killProcess, forKey: .type)
            try c.encode(pid, forKey: .pid)
            try c.encode(signal, forKey: .signal)
        case .killGroup(let mainPID, let signal):
            try c.encode(Kind.killGroup, forKey: .type)
            try c.encode(mainPID, forKey: .mainPID)
            try c.encode(signal, forKey: .signal)
        }
    }
}

public enum ActionOutcome: String, Codable, Sendable {
    case success
    case blocked       // refused by blocklist
    case notPermitted  // EPERM from the OS
    case noSuchProcess
    case error
}

/// Wire response, one JSON object per line.
public enum Response: Codable, Sendable {
    case snapshot(Snapshot)
    case actionResult(outcome: ActionOutcome, message: String)

    private enum CodingKeys: String, CodingKey { case type, snapshot, outcome, message }
    private enum Kind: String, Codable { case snapshot, actionResult }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .snapshot:
            self = .snapshot(try c.decode(Snapshot.self, forKey: .snapshot))
        case .actionResult:
            self = .actionResult(outcome: try c.decode(ActionOutcome.self, forKey: .outcome), message: try c.decode(String.self, forKey: .message))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .snapshot(let snap):
            try c.encode(Kind.snapshot, forKey: .type)
            try c.encode(snap, forKey: .snapshot)
        case .actionResult(let outcome, let message):
            try c.encode(Kind.actionResult, forKey: .type)
            try c.encode(outcome, forKey: .outcome)
            try c.encode(message, forKey: .message)
        }
    }
}

/// Shared path for the unix domain socket the daemon listens on
/// and the app connects to.
public enum IPC {
    public static let socketPath = "/var/run/ramwatcher.sock"
}
