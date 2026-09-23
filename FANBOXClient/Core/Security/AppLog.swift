import Foundation
import os

/// Unified logging. Never interpolate secrets; any request/response data must go through `SecretRedactor` first.
enum AppLog {
    static let subsystem = "ai.nemut.FANBOXClient"
    static let network = Logger(subsystem: subsystem, category: "network")
    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let database = Logger(subsystem: subsystem, category: "database")
    static let notifications = Logger(subsystem: subsystem, category: "notifications")
    static let media = Logger(subsystem: subsystem, category: "media")
    static let web = Logger(subsystem: subsystem, category: "web")
    static let auth = Logger(subsystem: subsystem, category: "auth")
    static let creator = Logger(subsystem: subsystem, category: "creator")
}
