import Foundation

/// The three fixture accounts of the demo world. Every demo account maps to one of them. They all belong to one person,
/// like real accounts in this app: FANBOX lets one account join only one plan per creator, so supporting a creator more
/// than once takes several accounts.
/// - `viewerA` / `viewerB`: two reader accounts that support mostly the same creators on different plans. On some of
///   those creators one account stops, changes or loses its support while the other keeps it (`DemoFixtures.profiles`).
/// - `creator`: the account that owns the demo creator page `demo-creator-self`; it also supports `demo-aoi`, which all
///   three accounts support.
enum DemoProfile: Int, Sendable, CaseIterable, Hashable {
    case viewerA = 0
    case viewerB = 1
    case creator = 2

    var isViewer: Bool { self != .creator }

    /// Short stable tag used inside synthetic ids.
    var tag: String {
        switch self {
        case .viewerA: return "a"
        case .viewerB: return "b"
        case .creator: return "c"
        }
    }
}

/// Stable, platform-independent string hashing (Swift's `hashValue` is randomized per process and must not be used
/// for anything that should survive a relaunch).
enum DemoHash {
    /// 64-bit FNV-1a over the UTF-8 bytes of `string`.
    static func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// Lowercase hex prefix of the FNV-1a hash (for synthetic ids).
    static func hex(_ string: String, length: Int = 8) -> String {
        let full = String(format: "%016llx", fnv1a64(string))
        return String(full.prefix(max(1, min(16, length))))
    }
}

/// Small deterministic PRNG (SplitMix64) for fixture decoration (e.g. demo image shapes). Never seeded from time.
struct DemoRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }
    init(seed: String) { state = DemoHash.fnv1a64(seed) }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform value in 0..<1.
    mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
}

/// Pure profile rules. `DemoWorld` adds the per-session assignment registry on top.
enum DemoProfileRules {
    /// Identity used for per-user world state (likes, own comments, profile assignment).
    static func identityKey(_ account: AccountContext) -> String {
        if let id = account.pixivUserID, !id.isEmpty { return id }
        return account.accountID
    }

    /// Hash-preferred viewer profile for an identity key (FNV-1a parity). Stable across launches.
    static func preferredViewerProfile(for key: String) -> DemoProfile {
        DemoHash.fnv1a64(key) % 2 == 0 ? .viewerA : .viewerB
    }

    static func isSelfCreator(_ account: AccountContext) -> Bool {
        account.creatorID == DemoFixtures.selfCreatorID
    }
}
