import Foundation

/// Per-account URLSession transport (SPEC §7.2 / §29 / §38). See `HTTPClient` for the contract.
final class AccountHTTPClient: HTTPClient, @unchecked Sendable {
    let credentials: CredentialStoring
    let scheduler: NetworkScheduler
    let recorder: ResearchRecorder

    init(credentials: CredentialStoring, scheduler: NetworkScheduler, recorder: ResearchRecorder) {
        self.credentials = credentials
        self.scheduler = scheduler
        self.recorder = recorder
    }

    func send(_ request: HTTPRequest, accountID: String?) async throws -> HTTPResponse {
        throw RemoteError.offline
    }

    func download(_ request: HTTPRequest, accountID: String?, progress: (@Sendable (Double) -> Void)?) async throws -> (URL, HTTPResponse) {
        throw RemoteError.offline
    }

    func upload(_ request: HTTPRequest, bodyFileURL: URL, accountID: String?,
                progress: (@Sendable (Double) -> Void)?) async throws -> HTTPResponse {
        throw RemoteError.offline
    }
}
