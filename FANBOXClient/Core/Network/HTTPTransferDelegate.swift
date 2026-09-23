import Foundation

/// Result of one URLSession task.
struct HTTPTransferOutcome: @unchecked Sendable {
    var response: URLResponse?
    var data: Data
    /// Downloads: the file moved out of URLSession's temporary location (caller owns it).
    var fileURL: URL?
    /// Bytes received (data / download).
    var bytesReceived: Int64
    /// Cookies set by redirect responses (the final response's Set-Cookie is parsed by the client).
    var redirectCookies: [StoredCookie]
}

/// Per-task state. Mutated on the session's serial delegate queue; completion is lock-protected.
final class HTTPTransferHandler: @unchecked Sendable {
    let progress: (@Sendable (Double) -> Void)?
    let downloadDirectory: URL?
    let requiresCSRF: Bool
    let callerHeaders: [String: String]
    var credential: SessionCredential?

    fileprivate var data = Data()
    fileprivate var fileURL: URL?
    fileprivate var fileError: Error?
    fileprivate var bytesReceived: Int64 = 0
    fileprivate var redirectCookies: [StoredCookie] = []

    private let lock = NSLock()
    private var result: Result<HTTPTransferOutcome, Error>?
    private var continuation: CheckedContinuation<HTTPTransferOutcome, Error>?

    init(credential: SessionCredential?, requiresCSRF: Bool, callerHeaders: [String: String],
         progress: (@Sendable (Double) -> Void)?, downloadDirectory: URL?) {
        self.credential = credential
        self.requiresCSRF = requiresCSRF
        self.callerHeaders = callerHeaders
        self.progress = progress
        self.downloadDirectory = downloadDirectory
    }

    /// Waits for completion (safe to call before or after the task finished).
    func wait() async throws -> HTTPTransferOutcome {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<HTTPTransferOutcome, Error>) in
            lock.lock()
            if let result {
                lock.unlock()
                c.resume(with: result)
            } else {
                continuation = c
                lock.unlock()
            }
        }
    }

    fileprivate func complete(_ r: Result<HTTPTransferOutcome, Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = r
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: r)
    }

    fileprivate func report(_ fraction: Double) {
        guard let progress, fraction.isFinite else { return }
        progress(min(1, max(0, fraction)))
    }
}

/// URLSession delegate of ONE account session. Routes callbacks to per-task handlers by task identifier.
final class HTTPTransferDelegate: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [Int: HTTPTransferHandler] = [:]

    func add(_ handler: HTTPTransferHandler, for task: URLSessionTask) {
        lock.lock()
        handlers[task.taskIdentifier] = handler
        lock.unlock()
    }

    private func handler(for task: URLSessionTask) -> HTTPTransferHandler? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[task.taskIdentifier]
    }

    private func removeHandler(for task: URLSessionTask) -> HTTPTransferHandler? {
        lock.lock()
        defer { lock.unlock() }
        return handlers.removeValue(forKey: task.taskIdentifier)
    }

    var activeTaskCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return handlers.count
    }

    // MARK: Data

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let h = handler(for: dataTask) else { return }
        h.data.append(data)
        h.bytesReceived += Int64(data.count)
    }

    // MARK: Upload progress

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0, let h = handler(for: task) else { return }
        h.report(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }

    // MARK: Download

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let h = handler(for: downloadTask) else { return }
        h.bytesReceived = totalBytesWritten
        if totalBytesExpectedToWrite > 0 {
            h.report(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let h = handler(for: downloadTask) else { return }
        // URLSession deletes `location` when this method returns: move it to our own temporary directory now.
        let fm = FileManager.default
        let directory = h.downloadDirectory ?? fm.temporaryDirectory
        let ext = downloadTask.originalRequest?.url?.pathExtension ?? ""
        let name = UUID().uuidString + (ext.isEmpty || ext.count > 8 ? ".download" : "." + ext)
        let destination = directory.appendingPathComponent(name, isDirectory: false)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try fm.moveItem(at: location, to: destination)
            h.fileURL = destination
            if let size = (try? fm.attributesOfItem(atPath: destination.path)[.size]) as? NSNumber {
                h.bytesReceived = size.int64Value
            }
        } catch {
            h.fileError = error
        }
    }

    // MARK: Redirects

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let h = handler(for: task) else {
            completionHandler(request)
            return
        }
        // Keep Set-Cookie from the redirect response (only for session hosts).
        if let responseURL = response.url, FanboxHostPolicy.isCookieEligible(url: responseURL) {
            let cookies = AccountHTTPClient.cookies(from: response, url: responseURL)
            if !cookies.isEmpty {
                h.redirectCookies.append(contentsOf: cookies)
                if h.credential != nil { h.credential?.merge(cookies) }
            }
        }
        // Recompute session headers for the new host: cookies / CSRF never follow a redirect off FANBOX / pixiv.
        var redirected = request
        do {
            try FanboxRequestHeaders.apply(to: &redirected, credential: h.credential, requiresCSRF: h.requiresCSRF,
                                           callerHeaders: h.callerHeaders)
        } catch {
            // CSRF-protected request redirected off FANBOX: follow without session headers.
            redirected.setValue(nil, forHTTPHeaderField: "Cookie")
            redirected.setValue(nil, forHTTPHeaderField: "X-CSRF-Token")
        }
        completionHandler(redirected)
    }

    // MARK: Completion

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let h = removeHandler(for: task) else { return }
        if let error {
            if let file = h.fileURL { try? FileManager.default.removeItem(at: file) }
            h.complete(.failure(error))
            return
        }
        if task is URLSessionDownloadTask, h.fileURL == nil {
            h.complete(.failure(h.fileError ?? URLError(.cannotCreateFile)))
            return
        }
        h.complete(.success(HTTPTransferOutcome(response: task.response, data: h.data, fileURL: h.fileURL,
                                                bytesReceived: h.bytesReceived, redirectCookies: h.redirectCookies)))
    }
}
