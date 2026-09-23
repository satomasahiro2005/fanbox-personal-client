import XCTest
@testable import FANBOXClient

/// Native media upload through the FANBOX adapter: post.addImage / post.addFile / post.addUrlEmbed (docs/API.md §15).
/// Scripted HTTP (and the real `AccountHTTPClient` over a URLProtocol stub) only; nothing is sent anywhere.
final class FanboxUploadTests: XCTestCase {
    private var workDir: URL!
    private let token = "tok-SECRET-upload-123"

    override func setUp() async throws {
        try await super.setUp()
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("FanboxUploadTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        NetModStubProtocol.reset()
        try? FileManager.default.removeItem(at: workDir)
        try await super.tearDown()
    }

    // MARK: Fixtures

    static let imageBody = #"""
    {"body":{"id":"img-1","extension":"png","width":800,"height":600,
     "originalUrl":"https://downloads.fanbox.cc/images/post/9001/img-1.png",
     "thumbnailUrl":"https://downloads.fanbox.cc/images/post/9001/w/1200/img-1.jpeg"}}
    """#
    static let fileBody = #"{"body":{"id":"file-1","name":"資料","extension":"pdf","size":11,"url":"https://downloads.fanbox.cc/files/post/9001/file-1.pdf"}}"#
    static let urlEmbedBody = #"{"body":{"id":"ue-1","type":"default","url":"https://example.com/a","host":"example.com"}}"#

    private func file(_ name: String, bytes: String = "hello-bytes") throws -> URL {
        let url = workDir.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: url)
        return url
    }

    /// A sparse file of `size` bytes (nothing is actually written).
    private func sparseFile(_ name: String, size: UInt64) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: size)
        try handle.close()
        return url
    }

    private func multipartBodyFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])
            .filter { $0.hasPrefix(MultipartFormData.temporaryFilePrefix) }
    }

    private func expectInvalidRequest(file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void) async -> String? {
        do {
            try await body()
            XCTFail("expected invalidRequest", file: file, line: line)
        } catch let error as RemoteError {
            guard case .invalidRequest(let message) = error else {
                XCTFail("unexpected \(error)", file: file, line: line)
                return nil
            }
            return message
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
        return nil
    }

    // MARK: Request building

    func testImageUploadIsMultipartWithoutTheTokenAndTheBodyFileIsRemoved() async throws {
        let h = FanboxTestHarness()
        try await h.saveCredential(accountID: FanboxTestHarness.creator.accountID, csrf: token)
        h.http.stub("post.addImage", json: Self.imageBody)
        let image = try file("イラスト 1.png", bytes: "PNG-BYTES")
        let progress = ProgressRecorder()

        let result = try await RequestContext.$priority.withValue(.foregroundMedia) {
            try await h.source.uploadImage(fileURL: image, postID: "9001", account: FanboxTestHarness.creator) { progress.append($0) }
        }

        let request = try XCTUnwrap(h.http.requests(for: "post.addImage").first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://api.fanbox.cc/post.addImage")
        XCTAssertTrue(request.requiresCSRF, "the transport adds X-CSRF-Token")
        XCTAssertEqual(request.priority, .foregroundMedia, "uploads are media: comment POSTs preempt them")
        XCTAssertTrue(request.headers["Content-Type"]?.hasPrefix("multipart/form-data; boundary=") ?? false)
        XCTAssertFalse(request.headers.values.contains(token), "the API layer never puts the token in a header itself")
        XCTAssertNil(request.body, "streamed from a temporary body file")

        let record = try XCTUnwrap(h.http.uploadRecords(for: "post.addImage").first)
        let body = String(decoding: record.body, as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"postId\"\r\n\r\n9001\r\n"), body)
        XCTAssertTrue(body.contains("name=\"image\"; filename=\"イラスト 1.png\"\r\nContent-Type: image/png\r\n\r\nPNG-BYTES\r\n"), body)
        XCTAssertFalse(body.contains("name=\"tt\""), "no tt field in the body file")
        XCTAssertFalse(record.body.range(of: Data(token.utf8)) != nil, "the CSRF token never reaches the disk")
        XCTAssertTrue(record.fileURL.lastPathComponent.hasPrefix(MultipartFormData.temporaryFilePrefix))
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.fileURL.path), "temporary body file removed after the request")

        XCTAssertEqual(result, RemoteUploadResult(mediaID: "img-1", url: "https://downloads.fanbox.cc/images/post/9001/img-1.png",
                                                  postID: "9001", thumbnailURL: "https://downloads.fanbox.cc/images/post/9001/w/1200/img-1.jpeg",
                                                  width: 800, height: 600, fileExtension: "png"))
        XCTAssertEqual(progress.values.last, 1)
        XCTAssertNotNil(h.spy.calls.first { $0.key == "post.addImage" }, "API Inspector sees the new endpoint")
    }

    func testFileUploadKeepsTheDisplayNameAndDecodesTheFile() async throws {
        let h = FanboxTestHarness()
        try await h.saveCredential(accountID: FanboxTestHarness.creator.accountID, csrf: token)
        h.http.stub("post.addFile", json: Self.fileBody)
        let pdf = try file("資料.pdf", bytes: "PDF-11bytes")

        let result = try await h.source.uploadFile(fileURL: pdf, postID: "9001", account: FanboxTestHarness.creator) { _ in }

        let record = try XCTUnwrap(h.http.uploadRecords(for: "post.addFile").first)
        let body = String(decoding: record.body, as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"postId\"\r\n\r\n9001\r\n"))
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"資料.pdf\"\r\nContent-Type: application/pdf\r\n\r\nPDF-11bytes\r\n"), body)
        XCTAssertFalse(body.contains("name=\"tt\""))
        XCTAssertNil(record.body.range(of: Data(token.utf8)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.fileURL.path))
        XCTAssertEqual(result.mediaID, "file-1")
        XCTAssertEqual(result.fileName, "資料")
        XCTAssertEqual(result.fileExtension, "pdf")
        XCTAssertEqual(result.fileSize, 11)
        XCTAssertEqual(result.url, "https://downloads.fanbox.cc/files/post/9001/file-1.pdf")
        XCTAssertEqual(result.postID, "9001")
    }

    func testURLEmbedIsASmallInMemoryForm() async throws {
        let h = FanboxTestHarness()
        try await h.saveCredential(accountID: FanboxTestHarness.creator.accountID, csrf: token)
        h.http.stub("post.addUrlEmbed", json: Self.urlEmbedBody)

        let result = try await RequestContext.$priority.withValue(.interactiveWrite) {
            try await h.source.addURLEmbed(url: "  https://example.com/a ", postID: "9001", account: FanboxTestHarness.creator)
        }

        let request = try XCTUnwrap(h.http.requests(for: "post.addUrlEmbed").first)
        XCTAssertTrue(request.requiresCSRF)
        XCTAssertEqual(request.priority, .interactiveWrite)
        let body = String(decoding: request.body ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"postId\"\r\n\r\n9001\r\n"))
        XCTAssertTrue(body.contains("name=\"url\"\r\n\r\nhttps://example.com/a\r\n"), "trimmed URL")
        XCTAssertFalse(body.contains("name=\"tt\""))
        XCTAssertTrue(h.http.uploadRecords.isEmpty, "no temporary file for a field-only form")
        XCTAssertEqual(result, RemoteUploadResult(mediaID: "ue-1", url: "https://example.com/a", postID: "9001"))
    }

    func testCreateEmptyPostSendsOnlyTheType() async throws {
        let h = FanboxTestHarness()
        try await h.saveCredential(accountID: FanboxTestHarness.creator.accountID, csrf: token)
        h.http.stub("post.create", json: #"{"body":{"postId":"9100"}}"#)
        let id = try await h.source.createEmptyPost(account: FanboxTestHarness.creator)
        XCTAssertEqual(id, "9100")
        XCTAssertEqual(h.http.requests.map(\.endpointKey), ["post.create"], "nothing else is saved yet")
        XCTAssertEqual(try JSONValue.parse(h.http.requests[0].body ?? Data()), ["type": "article"])
        XCTAssertTrue(h.http.requests[0].requiresCSRF)

        h.http.stub("post.create", json: #"{"body":{}}"#)
        do {
            _ = try await h.source.createEmptyPost(account: FanboxTestHarness.creator)
            XCTFail("expected decoding error")
        } catch let error as RemoteError {
            guard case .decoding = error else { return XCTFail("\(error)") }
        }
        do {
            _ = try await h.source.createEmptyPost(account: FanboxTestHarness.fan)
            XCTFail("a fan account has no creator page")
        } catch let error as RemoteError {
            guard case .invalidRequest = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: Validation before anything is sent

    func testLimitsAndInputsAreCheckedBeforeAnyRequest() async throws {
        let h = FanboxTestHarness()
        try await h.saveCredential(accountID: FanboxTestHarness.creator.accountID, csrf: token)
        let c = FanboxTestHarness.creator
        let before = multipartBodyFiles().count

        let bigImage = try sparseFile("big.jpg", size: UInt64(FanboxUploadForm.maxImageBytes) + 1)
        var message = await expectInvalidRequest { _ = try await h.source.uploadImage(fileURL: bigImage, postID: "1", account: c) { _ in } }
        XCTAssertTrue(message?.contains("50 MB") ?? false, message ?? "")
        let exactImage = try sparseFile("exact.png", size: UInt64(FanboxUploadForm.maxImageBytes))
        XCTAssertNoThrow(try FanboxUploadForm.validate(fileURL: exactImage, kind: .image), "50,000,000 bytes is still allowed")

        let webp = try file("photo.webp")
        message = await expectInvalidRequest { _ = try await h.source.uploadImage(fileURL: webp, postID: "1", account: c) { _ in } }
        XCTAssertTrue(message?.contains("jpeg") ?? false, message ?? "")

        let bigFile = try sparseFile("movie.mp4", size: UInt64(FanboxUploadForm.maxFileBytes) + 1)
        message = await expectInvalidRequest { _ = try await h.source.uploadFile(fileURL: bigFile, postID: "1", account: c) { _ in } }
        XCTAssertTrue(message?.contains("300 MB") ?? false, message ?? "")

        let docx = try file("memo.docx")
        message = await expectInvalidRequest { _ = try await h.source.uploadFile(fileURL: docx, postID: "1", account: c) { _ in } }
        XCTAssertTrue(message?.contains("memo.docx") ?? false, message ?? "")

        let empty = try file("empty.zip", bytes: "")
        _ = await expectInvalidRequest { _ = try await h.source.uploadFile(fileURL: empty, postID: "1", account: c) { _ in } }
        let missing = workDir.appendingPathComponent("missing.png")
        _ = await expectInvalidRequest { _ = try await h.source.uploadImage(fileURL: missing, postID: "1", account: c) { _ in } }
        let ok = try file("ok.png")
        _ = await expectInvalidRequest { _ = try await h.source.uploadImage(fileURL: ok, postID: " ", account: c) { _ in } }
        _ = await expectInvalidRequest { _ = try await h.source.addURLEmbed(url: "ftp://example.com/x", postID: "1", account: c) }
        _ = await expectInvalidRequest { _ = try await h.source.addURLEmbed(url: "   ", postID: "1", account: c) }

        XCTAssertTrue(h.http.requests.isEmpty, "nothing is sent for a file FANBOX's uploader would refuse")
        XCTAssertEqual(multipartBodyFiles().count, before, "no body file was written")

        // Every accepted extension passes; the whitelist is the web client's.
        for ext in ["txt", "psd", "pdf", "zip", "jpg", "jpeg", "png", "gif", "wav", "mp3", "flac", "mp4", "mov", "avi", "clip"] {
            XCTAssertNil(FanboxUploadForm.limits.problem(kind: .file, fileName: "a.\(ext.uppercased())", size: 10), ext)
        }
        XCTAssertNotNil(FanboxUploadForm.limits.problem(kind: .image, fileName: "a.heic", size: 10))
    }

    func testAFileFormCarryingTheTokenIsRefused() async throws {
        let h = FanboxTestHarness()
        try await h.saveCredential(accountID: FanboxTestHarness.creator.accountID, csrf: token)
        var form = MultipartFormData()
        form.addField(name: "tt", value: token)
        form.addFile(name: "image", fileURL: try file("a.png"))
        let before = multipartBodyFiles().count
        _ = await expectInvalidRequest {
            _ = try await h.api.sendMultipart(.postAddImage(), form: form, accountID: FanboxTestHarness.creator.accountID)
        }
        XCTAssertTrue(h.http.requests.isEmpty)
        XCTAssertEqual(multipartBodyFiles().count, before, "the token was never written to a temporary file")
    }

    // MARK: CSRF

    func testMissingTokenIsFetchedAndAStaleOneIsRefreshedOnce() async throws {
        let h = FanboxTestHarness()
        try await h.saveCredential(accountID: FanboxTestHarness.creator.accountID, csrf: nil)
        h.http.stub("www.metadata", data: Data(FanboxFixtures.metadataHTML.utf8))
        h.http.stub("post.addImage", json: Self.imageBody)
        _ = try await h.source.uploadImage(fileURL: try file("a.png"), postID: "9001", account: FanboxTestHarness.creator) { _ in }
        XCTAssertEqual(h.http.requests.map(\.endpointKey), ["www.metadata", "post.addImage"])

        let stale = FanboxTestHarness()
        try await stale.saveCredential(accountID: FanboxTestHarness.creator.accountID, csrf: "stale")
        stale.http.stub("post.addImage", status: 403, json: #"{"error":"general_error"}"#)
        stale.http.stub("post.addImage", json: Self.imageBody)
        stale.http.stub("www.metadata", data: Data(FanboxFixtures.metadataHTML.utf8))
        let result = try await stale.source.uploadImage(fileURL: try file("b.png"), postID: "9001", account: FanboxTestHarness.creator) { _ in }
        XCTAssertEqual(result.mediaID, "img-1")
        XCTAssertEqual(stale.http.requests.map(\.endpointKey), ["post.addImage", "www.metadata", "post.addImage"])
        let records = stale.http.uploadRecords(for: "post.addImage")
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].fileURL, records[1].fileURL, "the same token-free body file is re-sent")
        XCTAssertFalse(FileManager.default.fileExists(atPath: records[0].fileURL.path))
        let stored = await stale.credentials.credential(for: FanboxTestHarness.creator.accountID)
        XCTAssertEqual(stored?.csrfToken, "tok-fresh-123")
    }

    func testTheRealTransportSendsTheTokenAsTheHeaderOnly() async throws {
        let credentials = InMemoryCredentialStore()
        try await credentials.save(SessionCredential(cookies: [StoredCookie(name: "FANBOXSESSID", value: "11_s", domain: ".fanbox.cc")],
                                                     userAgent: "UA", csrfToken: token), for: "A")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NetModStubProtocol.self]
        let transport = AccountHTTPClient(credentials: credentials, scheduler: NetworkScheduler(policy: NetworkPolicyStore()),
                                          recorder: ResearchRecorder(), configuration: config)
        let source = FanboxRemoteDataSource(api: FanboxAPIClient(http: transport, inspector: SchemaInspector()))
        let account = AccountContext(accountID: "A", kind: .fanbox, pixivUserID: "11", fanboxUserID: nil, creatorID: "alice")
        NetModStubProtocol.install { request in
            request.url?.path == "/post.addImage"
                ? .init(status: 200, headers: ["Content-Type": "application/json"], body: Data(Self.imageBody.utf8))
                : .init(status: 404)
        }
        let before = multipartBodyFiles().count

        let result = try await source.uploadImage(fileURL: try file("real.png"), postID: "9001", account: account) { _ in }

        XCTAssertEqual(result.mediaID, "img-1")
        let sent = try XCTUnwrap(NetModStubProtocol.requests.first { $0.url?.path == "/post.addImage" })
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "X-CSRF-Token"), token, "the token travels in the header")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Origin"), "https://www.fanbox.cc")
        XCTAssertTrue(sent.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") ?? false)
        XCTAssertEqual(multipartBodyFiles().count, before, "the body file is removed after the request")
    }

    // MARK: Response decoding

    func testResponseDecodingIsLenientButNeedsAnID() throws {
        let wrapped = try FanboxResponseHandling.decodeBody(FanboxUploadedImageBody.self,
                                                            from: Data(#"{"body":{"image":{"id":"w1","extension":"jpg"}}}"#.utf8),
                                                            endpointKey: "post.addImage")
        XCTAssertEqual(wrapped.image.id, "w1")
        let file = try FanboxResponseHandling.decodeBody(FanboxUploadedFileBody.self, from: Data(Self.fileBody.utf8), endpointKey: "post.addFile")
        XCTAssertEqual(try FanboxUploadForm.result(file.file, postID: "9").fileName, "資料")
        let embed = try FanboxResponseHandling.decodeBody(FanboxAddedURLEmbedBody.self,
                                                          from: Data(#"{"body":{"id":"u1","type":"html.card","html":"<a href='x'>x</a>"}}"#.utf8),
                                                          endpointKey: "post.addUrlEmbed")
        XCTAssertEqual(try FanboxUploadForm.result(embed.urlEmbed, postID: "9", requestedURL: "https://e.example/").url, "https://e.example/",
                       "the requested URL when the card does not echo it")
        XCTAssertThrowsError(try FanboxResponseHandling.decodeBody(FanboxUploadedImageBody.self, from: Data(#"{"body":{"ok":true}}"#.utf8),
                                                                   endpointKey: "post.addImage"))
    }

    func testAnAnswerWithoutAnIDIsAResearchEvent() async throws {
        let h = FanboxTestHarness()
        try await h.saveCredential(accountID: FanboxTestHarness.creator.accountID, csrf: token)
        h.http.stub("post.addImage", json: #"{"body":{"status":"ok"}}"#)
        do {
            _ = try await h.source.uploadImage(fileURL: try file("a.png"), postID: "9001", account: FanboxTestHarness.creator) { _ in }
            XCTFail("expected decoding error")
        } catch let error as RemoteError {
            guard case .decoding(let endpoint, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(endpoint, "post.addImage")
        }
        XCTAssertNotNil(h.spy.calls.first { $0.key == "post.addImage" }, "the unexpected shape reaches the API Inspector")
    }

    // MARK: Capabilities and the post.update form

    func testFanboxCapabilities() {
        let caps = FanboxTestHarness().source.draftCapabilities
        XCTAssertEqual(caps, .fanbox)
        XCTAssertTrue(caps.uploadsMedia)
        XCTAssertTrue(caps.createsLinkCards)
        XCTAssertFalse(caps.createsEmbeds, "no add-embed endpoint in the current web client")
        XCTAssertFalse(caps.sendsAdultFlag, "post.update has no R-18 field")
        XCTAssertFalse(caps.sendsPlanID, "posts are gated by feeRequired only")
        XCTAssertTrue(caps.uploadsNeedPost)
        XCTAssertTrue(caps.updates(.image))
        XCTAssertTrue(caps.updates(.file))
        XCTAssertFalse(caps.updates(.video))
        XCTAssertFalse(caps.updates(.text))
        XCTAssertEqual(caps.allowedKinds(in: .image), [.image, .text])
        XCTAssertNil(caps.allowedKinds(in: .article))
        XCTAssertEqual(caps.mediaLimits, FanboxUploadForm.limits)
        let disabled = FanboxRemoteDataSource(api: FanboxTestHarness().api, pageCache: FanboxPageURLCache(), nativePostWritesEnabled: false)
        XCTAssertEqual(disabled.draftCapabilities, .webOnly)
    }

    func testUpdateFormReferencesMediaUploadedIntoThisPostOnly() throws {
        let uploaded = RemoteDraftBlock(kind: .image, text: "", mediaID: "new-1", url: nil, embedProvider: nil, embedContentID: nil,
                                        media: RemoteUploadResult(mediaID: "new-1", url: nil, postID: "9001"))
        let card = RemoteDraftBlock(kind: .url, text: "", mediaID: "ue-1", url: "https://example.com/", embedProvider: nil, embedContentID: nil,
                                    media: RemoteUploadResult(mediaID: "ue-1", url: "https://example.com/", postID: "9001"))
        let file = RemoteDraftBlock(kind: .file, text: "", mediaID: "f-1", url: nil, embedProvider: nil, embedContentID: nil,
                                    media: RemoteUploadResult(mediaID: "f-1", url: nil, postID: "9001"))
        let text = RemoteDraftBlock(kind: .text, text: "本文", mediaID: nil, url: nil, embedProvider: nil, embedContentID: nil)
        var existing = FanboxPostUpdateForm.ExistingMedia(imageIDs: ["old-1"])
        existing.addUploads(for: "9001", in: [uploaded, card, file])
        let old = RemoteDraftBlock(kind: .image, text: "", mediaID: "old-1", url: nil, embedProvider: nil, embedContentID: nil)
        let json = try FanboxPostUpdateForm.blocksJSON([text, uploaded, old, card, file], existing: existing)
        XCTAssertEqual(json, [["type": "p", "text": "本文"], ["type": "image", "imageId": "new-1"], ["type": "image", "imageId": "old-1"],
                              ["type": "url_embed", "urlEmbedId": "ue-1"], ["type": "file", "fileId": "f-1"]])

        // Media stored into ANOTHER post is never referenced.
        let foreign = RemoteDraftBlock(kind: .image, text: "", mediaID: "x-1", url: nil, embedProvider: nil, embedContentID: nil,
                                       media: RemoteUploadResult(mediaID: "x-1", url: nil, postID: "8000"))
        var other = FanboxPostUpdateForm.ExistingMedia()
        other.addUploads(for: "9001", in: [foreign])
        XCTAssertThrowsError(try FanboxPostUpdateForm.blocksJSON([foreign], existing: other)) { error in
            guard case .unsupported? = error as? RemoteError else { return XCTFail("\(error)") }
        }
    }

    func testImageAndFilePostBodies() throws {
        let editable = try FanboxFixtures.decodeBody(FanboxEditablePostBody.self, #"""
        {"id":"p9","type":"image","title":"T","status":"published","feeRequired":0,
         "body":{"text":"一段落目\n続き\n\n\n二段落目","images":[{"id":"i1","extension":"jpg","width":10,"height":20,
           "originalUrl":"https://downloads.fanbox.cc/images/post/p9/i1.jpg","thumbnailUrl":"https://downloads.fanbox.cc/images/post/p9/w/1200/i1.jpeg"}]}}
        """#)
        var existing = FanboxPostUpdateForm.ExistingMedia(editable: editable.post)
        let new = RemoteDraftBlock(kind: .image, text: "", mediaID: "i2", url: nil, embedProvider: nil, embedContentID: nil,
                                   media: RemoteUploadResult(mediaID: "i2", url: "https://downloads.fanbox.cc/images/post/p9/i2.png", postID: "p9",
                                                             thumbnailURL: "https://downloads.fanbox.cc/images/post/p9/w/1200/i2.jpeg",
                                                             width: 30, height: 40, fileExtension: "png"))
        existing.addUploads(for: "p9", in: [new])
        func text(_ t: String) -> RemoteDraftBlock {
            RemoteDraftBlock(kind: .text, text: t, mediaID: nil, url: nil, embedProvider: nil, embedContentID: nil, keepsLineBreaks: true)
        }
        let old = RemoteDraftBlock(kind: .image, text: "", mediaID: "i1", url: nil, embedProvider: nil, embedContentID: nil)
        // Unchanged paragraphs: the post's own text is sent back byte-for-byte.
        let body = try FanboxPostUpdateForm.bodyJSON([new, old, text("一段落目\n続き"), text("二段落目")], type: .image, existing: existing,
                                                     existingText: editable.post.body?.text)
        XCTAssertEqual(body["text"], "一段落目\n続き\n\n\n二段落目")
        XCTAssertEqual(body["images"], [
            ["id": "i2", "originalUrl": "https://downloads.fanbox.cc/images/post/p9/i2.png",
             "thumbnailUrl": "https://downloads.fanbox.cc/images/post/p9/w/1200/i2.jpeg", "width": 30, "height": 40, "extension": "png"],
            ["id": "i1", "originalUrl": "https://downloads.fanbox.cc/images/post/p9/i1.jpg",
             "thumbnailUrl": "https://downloads.fanbox.cc/images/post/p9/w/1200/i1.jpeg", "width": 10, "height": 20, "extension": "jpg"],
        ], "block order; full objects; no imageMap")
        XCTAssertNil(body["blocks"])
        // Edited text: paragraphs joined by an empty line.
        let edited = try FanboxPostUpdateForm.bodyJSON([old, text("新しい本文"), text("二段落目")], type: .image, existing: existing,
                                                       existingText: editable.post.body?.text)
        XCTAssertEqual(edited["text"], "新しい本文\n\n二段落目")
        // Other block kinds cannot be stored in an image post.
        let header = RemoteDraftBlock(kind: .header, text: "見出し", mediaID: nil, url: nil, embedProvider: nil, embedContentID: nil)
        XCTAssertThrowsError(try FanboxPostUpdateForm.bodyJSON([old, header], type: .image, existing: existing))
        XCTAssertThrowsError(try FanboxPostUpdateForm.bodyJSON([old], type: .video, existing: existing)) { error in
            guard case .unsupported? = error as? RemoteError else { return XCTFail("\(error)") }
        }

        // File post: {text, files} with {id, name, extension, size, url}.
        let upload = RemoteDraftBlock(kind: .file, text: "", mediaID: "f9", url: nil, embedProvider: nil, embedContentID: nil,
                                      media: RemoteUploadResult(mediaID: "f9", url: "https://downloads.fanbox.cc/files/post/p9/f9.zip", postID: "p9",
                                                                fileExtension: "zip", fileName: "素材", fileSize: 1234))
        var files = FanboxPostUpdateForm.ExistingMedia()
        files.addUploads(for: "p9", in: [upload])
        let fileBody = try FanboxPostUpdateForm.bodyJSON([upload, text("説明")], type: .file, existing: files)
        XCTAssertEqual(fileBody, ["text": "説明", "files": [["id": "f9", "name": "素材", "extension": "zip", "size": 1234,
                                                             "url": "https://downloads.fanbox.cc/files/post/p9/f9.zip"]]])
    }
}

/// Collects progress values from a `@Sendable` callback.
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    func append(_ value: Double) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return storage }
}
