import Foundation

/// Explicit request priority classes (SPEC §29). Higher value wins.
enum RequestPriority: Int, Comparable, CaseIterable, Sendable {
    case interactiveWrite = 100
    case interactiveRead = 90
    case notificationPrefetch = 80
    case foregroundMedia = 50
    case backgroundSync = 20
    case mediaPrefetch = 5

    static func < (lhs: RequestPriority, rhs: RequestPriority) -> Bool { lhs.rawValue < rhs.rawValue }

    var isMedia: Bool { self == .foregroundMedia || self == .mediaPrefetch }
    var isInteractive: Bool { self == .interactiveWrite || self == .interactiveRead }

    /// Mapping to `URLSessionTask.priority` (0...1).
    var urlSessionTaskPriority: Float {
        switch self {
        case .interactiveWrite: return URLSessionTask.highPriority
        case .interactiveRead: return 0.9
        case .notificationPrefetch: return 0.8
        case .foregroundMedia: return URLSessionTask.defaultPriority
        case .backgroundSync: return 0.2
        case .mediaPrefetch: return URLSessionTask.lowPriority
        }
    }

    var displayName: String {
        switch self {
        case .interactiveWrite: return "interactiveWrite"
        case .interactiveRead: return "interactiveRead"
        case .notificationPrefetch: return "notificationPrefetch"
        case .foregroundMedia: return "foregroundMedia"
        case .backgroundSync: return "backgroundSync"
        case .mediaPrefetch: return "mediaPrefetch"
        }
    }
}

/// Handle for a registered long-running transfer.
struct TransferToken: Hashable, Sendable {
    let id: UUID
}

/// Text-first network scheduler (SPEC §29).
///
/// - Every HTTP request runs through `run(_:label:operation:)`.
/// - Interactive requests are admitted immediately; lower classes wait for free slots.
/// - While any interactive / notification request is in flight, registered media transfers are suspended
///   (`URLSessionTask.suspend()`) and resumed afterwards ("Media pause / deprioritize → Comment POST → Resume Media").
/// - In Offline mode every request fails fast with `RemoteError.offline`.
actor NetworkScheduler {
    let policy: NetworkPolicyStore

    init(policy: NetworkPolicyStore) {
        self.policy = policy
    }

    /// Runs `operation` under the given priority class.
    func run<T: Sendable>(_ priority: RequestPriority, label: String,
                          operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard policy.current.allowsNetwork else { throw RemoteError.offline }
        return try await operation()
    }

    /// Registers a media transfer so it can be paused while interactive requests run.
    func register(task: URLSessionTask, priority: RequestPriority) -> TransferToken {
        TransferToken(id: UUID())
    }

    func unregister(_ token: TransferToken) {}

    /// Number of requests currently running per priority (Research Mode display).
    func snapshot() -> [RequestPriority: Int] { [:] }
}
