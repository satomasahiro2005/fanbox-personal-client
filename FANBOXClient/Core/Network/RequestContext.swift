import Foundation

/// Task-local request context. `RemoteDataSource` methods have no priority parameter; callers set the priority
/// around a call and the FANBOX API client reads it when building `HTTPRequest`s:
///
///     try await RequestContext.$priority.withValue(.interactiveWrite) {
///         try await remote.addComment(...)
///     }
enum RequestContext {
    @TaskLocal static var priority: RequestPriority = .backgroundSync
}
