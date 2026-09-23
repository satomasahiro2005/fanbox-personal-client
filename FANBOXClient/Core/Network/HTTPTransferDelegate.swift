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
    /// docs/API.md §1.6: GET redirects are capped at this many hops.
    static let maxRedirects = 5

    let progress: (@Sendable (Double) -> Void)?
    let downloadDirectory: URL?
    let requiresCSRF: Bool
    let callerHeaders: [String: String]
    let isMedia: Bool
    /// Body of a streamed upload (`uploadTask(withStreamedRequest:)`): a new producer feeds every stream URLSession asks for.
    let streamedBody: HTTPStreamedBody?
    var credential: SessionCredential?
    /// The task this handler belongs to (cancelled when the streamed body cannot be produced).
    weak var task: URLSessionTask?
    /// Redirect hops followed so far (delegate queue only).
    fileprivate var redirectCount = 0

    fileprivate var data = Data()
    fileprivate var fileURL: URL?
    fileprivate var fileError: Error?
    fileprivate var bytesReceived: Int64 = 0
    fileprivate var redirectCookies: [StoredCookie] = []

    private let lock = NSLock()
    private var result: Result<HTTPTransferOutcome, Error>?
    private var continuation: CheckedContinuation<HTTPTransferOutcome, Error>?
    private var producers: [HTTPBodyStreamProducer] = []
    private var bodyFailure: Error?

    init(credential: SessionCredential?, requiresCSRF: Bool, callerHeaders: [String: String],
         progress: (@Sendable (Double) -> Void)?, downloadDirectory: URL?, isMedia: Bool = false,
         streamedBody: HTTPStreamedBody? = nil) {
        self.credential = credential
        self.requiresCSRF = requiresCSRF
        self.callerHeaders = callerHeaders
        self.isMedia = isMedia
        self.progress = progress
        self.downloadDirectory = downloadDirectory
        self.streamedBody = streamedBody
    }

    /// A fresh body stream for URLSession (first send, or a re-send after a redirect / reconnect). Earlier producers stop.
    fileprivate func makeBodyStream() -> InputStream? {
        guard let streamedBody else { return nil }
        let producer = HTTPBodyStreamProducer(body: streamedBody) { [weak self] error in self?.bodyStreamFailed(error) }
        lock.lock()
        let previous = producers
        producers = [producer]
        lock.unlock()
        previous.forEach { $0.stop() }
        producer.start()
        return producer.inputStream
    }

    /// Stops every producer (the task finished). Returns the error of a body that could not be produced, if any.
    fileprivate func finishBodyStreams() -> Error? {
        lock.lock()
        let stopping = producers
        producers = []
        let failure = bodyFailure
        lock.unlock()
        stopping.forEach { $0.stop() }
        return failure
    }

    private func bodyStreamFailed(_ error: Error) {
        lock.lock()
        if bodyFailure == nil { bodyFailure = error }
        lock.unlock()
        // The request can no longer carry the announced Content-Length: end it now instead of waiting for a timeout.
        task?.cancel()
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

    // MARK: Streamed upload body

    func urlSession(_ session: URLSession, task: URLSessionTask, needNewBodyStream completionHandler: @escaping (InputStream?) -> Void) {
        completionHandler(handler(for: task)?.makeBodyStream())
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

    /// Whether a redirect may be followed: never for writes (a 307 / 308 would re-send the body elsewhere), and at most
    /// `HTTPTransferHandler.maxRedirects` hops for reads (docs/API.md §1.6). A refused redirect returns the 3xx response
    /// to the caller, which maps it to an error.
    static func mayFollowRedirect(method: String?, hopsSoFar: Int) -> Bool {
        let m = (method ?? "GET").uppercased()
        guard m == "GET" || m == "HEAD" else { return false }
        return hopsSoFar < HTTPTransferHandler.maxRedirects
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let method = task.originalRequest?.httpMethod ?? task.currentRequest?.httpMethod
        guard let h = handler(for: task) else {
            completionHandler(Self.mayFollowRedirect(method: method, hopsSoFar: 0) ? request : nil)
            return
        }
        guard Self.mayFollowRedirect(method: method, hopsSoFar: h.redirectCount) else {
            completionHandler(nil)
            return
        }
        h.redirectCount += 1
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
                                           callerHeaders: h.callerHeaders, isMedia: h.isMedia)
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
        if h.finishBodyStreams() != nil {
            // The streamed body could not be read to the end (a file vanished or shrank): never report an answer to it.
            h.complete(.failure(URLError(.cannotOpenFile)))
            return
        }
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

/// Writes an `HTTPStreamedBody` into a bound stream pair from its own thread; URLSession reads the other end
/// (`uploadTask(withStreamedRequest:)` → `urlSession(_:task:needNewBodyStream:)`). Files are read in 64 KB chunks as the
/// connection drains, so the body never exists as one file or one buffer (a multipart form may hold the CSRF token,
/// SPEC §39, next to a 300 MB attachment).
///
/// The producer runs an event-driven write loop on a dedicated thread's run loop (never a blocking write), so `stop()`
/// always ends it: when the body is complete, when the reader goes away, or when the task finishes for any reason.
final class HTTPBodyStreamProducer: NSObject, StreamDelegate, @unchecked Sendable {
    static let chunkSize = 64 * 1024

    let inputStream: InputStream
    private let outputStream: OutputStream
    private let onFailure: @Sendable (Error) -> Void

    // Producer thread only.
    private var remaining: [HTTPStreamedBody.Segment]
    private var chunk = Data()
    private var chunkOffset = 0
    private var file: (handle: FileHandle, left: Int64)?
    private var finished = false

    // Guarded by `lock`.
    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var stopRequested = false

    init(body: HTTPStreamedBody, onFailure: @escaping @Sendable (Error) -> Void) {
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: Self.chunkSize, inputStream: &input, outputStream: &output)
        guard let input, let output else { preconditionFailure("bound stream pair unavailable") }
        inputStream = input
        outputStream = output
        remaining = body.segments
        self.onFailure = onFailure
        super.init()
    }

    func start() {
        let thread = Thread { [self] in self.run() }
        thread.name = "HTTPBodyStreamProducer"
        thread.qualityOfService = .utility
        thread.start()
    }

    /// Ends production (closing the write side). Safe from any thread, before or after `start`.
    func stop() {
        lock.lock()
        stopRequested = true
        let loop = runLoop
        lock.unlock()
        guard let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [self] in self.finish() }
        CFRunLoopWakeUp(loop)
    }

    private func run() {
        lock.lock()
        runLoop = CFRunLoopGetCurrent()
        let stopEarly = stopRequested
        lock.unlock()
        if !stopEarly {
            outputStream.delegate = self
            outputStream.schedule(in: .current, forMode: .default)
            outputStream.open()
            while !finished {
                _ = RunLoop.current.run(mode: .default, before: .distantFuture)
            }
        }
        finish()
        lock.lock()
        runLoop = nil
        lock.unlock()
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        if eventCode.contains(.errorOccurred) || eventCode.contains(.endEncountered) {
            finish()
            return
        }
        if eventCode.contains(.hasSpaceAvailable) { writeAvailable() }
    }

    private func writeAvailable() {
        while !finished && outputStream.hasSpaceAvailable {
            if chunkOffset >= chunk.count {
                do {
                    guard let next = try nextChunk() else {
                        finish()   // body complete: closing the write side is the end of the stream for the reader
                        return
                    }
                    chunk = next
                    chunkOffset = 0
                } catch {
                    onFailure(error)
                    finish()
                    return
                }
            }
            let written = chunk.withUnsafeBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return outputStream.write(base + chunkOffset, maxLength: chunk.count - chunkOffset)
            }
            guard written > 0 else {
                finish()   // the reader went away
                return
            }
            chunkOffset += written
        }
    }

    /// Next bytes to write, nil at the end of the body. A file shorter than announced throws.
    private func nextChunk() throws -> Data? {
        while true {
            if let current = file {
                if current.left > 0 {
                    let data = try current.handle.read(upToCount: Int(min(Int64(Self.chunkSize), current.left))) ?? Data()
                    guard !data.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                    file = (current.handle, current.left - Int64(data.count))
                    return data
                }
                try? current.handle.close()
                file = nil
            }
            guard !remaining.isEmpty else { return nil }
            switch remaining.removeFirst() {
            case .data(let data):
                if !data.isEmpty { return data }
            case .file(let url, let length):
                file = (try FileHandle(forReadingFrom: url), length)
            }
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        outputStream.delegate = nil
        outputStream.remove(from: .current, forMode: .default)
        outputStream.close()
        if let file { try? file.handle.close() }
        file = nil
        chunk = Data()
        remaining = []
    }
}
