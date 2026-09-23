import XCTest
@testable import FANBOXClient

/// Edge-block classification (docs/API.md §1.6 / §1.7), request header policy (§1.2 / §1.3 / §1.9) and redirect safety.
final class FixTransportEdgeBlockTests: XCTestCase {
    private let html = ["Content-Type": "text/html; charset=UTF-8"]

    // MARK: EdgeBlockDetector

    func testCloudflareChallengeAndBlockPagesAreEdgeBlocks() {
        XCTAssertTrue(EdgeBlockDetector.isEdgeBlock(status: 403, headers: ["cf-mitigated": "challenge"], body: nil))
        XCTAssertTrue(EdgeBlockDetector.isEdgeBlock(status: 403, headers: html.merging(["Server": "cloudflare"]) { a, _ in a },
                                                    body: Data("<html></html>".utf8)))
        XCTAssertTrue(EdgeBlockDetector.isEdgeBlock(status: 403, headers: html,
                                                    body: Data("<!DOCTYPE html><title>Just a moment...</title>".utf8)))
        XCTAssertTrue(EdgeBlockDetector.isEdgeBlock(status: 403, headers: [:],
                                                    body: Data("<html><h1>ブロックされました</h1></html>".utf8)))
        XCTAssertTrue(EdgeBlockDetector.isEdgeBlock(status: 503, headers: html,
                                                    body: Data("<script src=\"/cdn-cgi/challenge-platform/x\"></script>".utf8)))
        XCTAssertTrue(EdgeBlockDetector.isEdgeBlock(status: 403, headers: [:], body: Data("Attention Required! | Cloudflare".utf8)))
    }

    func testFanboxRefusalsAreNotEdgeBlocks() {
        let json = ["Content-Type": "application/json", "Server": "cloudflare", "cf-ray": "abc"]
        XCTAssertFalse(EdgeBlockDetector.isEdgeBlock(status: 403, headers: json, body: Data(#"{"error":"general_error"}"#.utf8)))
        XCTAssertFalse(EdgeBlockDetector.isEdgeBlock(status: 403, headers: ["Server": "cloudflare"],
                                                     body: Data(#"  {"error":"x"}"#.utf8)), "JSON body without a content type")
        XCTAssertFalse(EdgeBlockDetector.isEdgeBlock(status: 401, headers: html, body: Data("just a moment".utf8)))
        XCTAssertFalse(EdgeBlockDetector.isEdgeBlock(status: 429, headers: ["cf-mitigated": "challenge"], body: nil),
                       "429 is rate limiting, never a transport switch")
        XCTAssertFalse(EdgeBlockDetector.isEdgeBlock(status: 200, headers: html, body: Data("ブロックされました".utf8)))
        XCTAssertFalse(EdgeBlockDetector.isEdgeBlock(status: 503, headers: json, body: Data("{}".utf8)))
    }

    func testResponseHandlingMapsEdgeBlocksBeforeStatus() {
        let edge = FanboxResponseHandling.map(statusCode: 403, headers: html.merging(["Server": "cloudflare", "Retry-After": "30"]) { a, _ in a },
                                              errorCode: nil, body: Data("<html>x</html>".utf8))
        XCTAssertEqual(edge, .edgeBlocked(retryAfter: 30))
        XCTAssertEqual(FanboxResponseHandling.map(statusCode: 403, headers: ["Content-Type": "application/json"], errorCode: "general_error",
                                                  body: Data(#"{"error":"general_error"}"#.utf8)), .forbidden)
        guard case .invalidRequest = FanboxResponseHandling.map(statusCode: 307, headers: [:]) else { return XCTFail("3xx is a refusal") }
        XCTAssertTrue(RemoteError.edgeBlocked(retryAfter: nil).isTransient)
        XCTAssertTrue(RemoteError.csrfUnavailable.isTransient)
        XCTAssertFalse(RemoteError.forbidden.isTransient)
    }

    // MARK: Headers

    private func apply(_ url: String, credential: SessionCredential?, csrf: Bool = false, media: Bool = false,
                       caller: [String: String] = [:]) throws -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        for (k, v) in caller { request.setValue(v, forHTTPHeaderField: k) }
        try FanboxRequestHeaders.apply(to: &request, credential: credential, requiresCSRF: csrf, callerHeaders: caller, isMedia: media)
        return request
    }

    func testOriginOnlyForTheAPIAndMediaAccept() throws {
        let credential = SessionCredential(cookies: [StoredCookie(name: "FANBOXSESSID", value: "s", domain: ".fanbox.cc"),
                                                     StoredCookie(name: "PHPSESSID", value: "p", domain: ".pixiv.net")],
                                           userAgent: "UA", csrfToken: "t")
        let api = try apply("https://api.fanbox.cc/post.info?postId=1", credential: credential)
        XCTAssertEqual(api.value(forHTTPHeaderField: "Origin"), "https://www.fanbox.cc")
        XCTAssertEqual(api.value(forHTTPHeaderField: "Cookie"), "FANBOXSESSID=s")

        let download = try apply("https://downloads.fanbox.cc/images/post/1/a.jpeg", credential: credential, media: true,
                                 caller: ["Origin": "https://www.fanbox.cc"])
        XCTAssertNil(download.value(forHTTPHeaderField: "Origin"), "image GETs carry no Origin (browser-like)")
        XCTAssertEqual(download.value(forHTTPHeaderField: "Referer"), "https://www.fanbox.cc/")
        XCTAssertEqual(download.value(forHTTPHeaderField: "Cookie"), "FANBOXSESSID=s")
        XCTAssertEqual(download.value(forHTTPHeaderField: "Accept"), FanboxRequestHeaders.mediaAccept)

        let www = try apply("https://www.fanbox.cc/", credential: credential)
        XCTAssertNil(www.value(forHTTPHeaderField: "Origin"))

        let pximg = try apply("https://pixiv.pximg.net/c/1.jpeg", credential: credential, media: true)
        XCTAssertNil(pximg.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(pximg.value(forHTTPHeaderField: "Referer"), "https://www.fanbox.cc/")

        let pixiv = try apply("https://www.pixiv.net/ajax/x", credential: credential)
        XCTAssertNil(pixiv.value(forHTTPHeaderField: "Cookie"), "pixiv.net cookies are never sent by the native transport")
    }

    func testMissingCSRFIsCsrfUnavailableNotUnauthorized() {
        XCTAssertThrowsError(try apply("https://api.fanbox.cc/post.likePost", credential: SessionCredential(cookies: []), csrf: true)) {
            XCTAssertEqual($0 as? RemoteError, .csrfUnavailable)
        }
    }

    func testCookieEligibilityIsFanboxOnly() {
        XCTAssertTrue(FanboxHostPolicy.isCookieEligible(url: URL(string: "https://downloads.fanbox.cc/x")))
        XCTAssertFalse(FanboxHostPolicy.isCookieEligible(url: URL(string: "https://www.pixiv.net/")))
        XCTAssertFalse(FanboxHostPolicy.isCookieEligible(url: URL(string: "https://pixiv.pximg.net/x")))
        XCTAssertTrue(SessionCredential.isEdgeCookie(name: "cf_clearance"))
        XCTAssertTrue(SessionCredential.isEdgeCookie(name: "__cf_bm"))
        XCTAssertFalse(SessionCredential.isEdgeCookie(name: "FANBOXSESSID"))
        XCTAssertFalse(FanboxHostPolicy.defaultUserAgent.contains("Safari/"), "fallback UA looks like a WKWebView UA")
    }

    // MARK: Redirects

    func testRedirectsAreNeverFollowedForWritesAndCappedForReads() {
        XCTAssertTrue(HTTPTransferDelegate.mayFollowRedirect(method: "GET", hopsSoFar: 0))
        XCTAssertTrue(HTTPTransferDelegate.mayFollowRedirect(method: "GET", hopsSoFar: 4))
        XCTAssertFalse(HTTPTransferDelegate.mayFollowRedirect(method: "GET", hopsSoFar: 5))
        XCTAssertFalse(HTTPTransferDelegate.mayFollowRedirect(method: "POST", hopsSoFar: 0))
        XCTAssertFalse(HTTPTransferDelegate.mayFollowRedirect(method: "put", hopsSoFar: 0))
    }

    func testPostRedirectIsRefusedByTheDelegate() {
        let delegate = HTTPTransferDelegate()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var post = URLRequest(url: URL(string: "https://api.fanbox.cc/post.addComment")!)
        post.httpMethod = "POST"
        let task = session.dataTask(with: post)
        delegate.add(HTTPTransferHandler(credential: nil, requiresCSRF: false, callerHeaders: [:], progress: nil, downloadDirectory: nil),
                     for: task)
        let redirect = HTTPURLResponse(url: post.url!, statusCode: 307, httpVersion: "HTTP/1.1",
                                       headerFields: ["Location": "https://api.fanbox.cc/elsewhere"])!
        var followed: URLRequest? = URLRequest(url: URL(string: "about:blank")!)
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: redirect,
                            newRequest: URLRequest(url: URL(string: "https://api.fanbox.cc/elsewhere")!)) { followed = $0 }
        XCTAssertNil(followed, "a write is never re-sent to another location")
        task.cancel()
    }
}
