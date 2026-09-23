import SwiftData
import XCTest
@testable import FANBOXClient

/// Native media upload end to end: `DraftService` + `UploadQueue` over the real `FanboxRemoteDataSource` and the
/// scripted HTTP client (post.create → post.addImage / post.addFile / post.addUrlEmbed → post.update), and the same flow
/// with the demo data source. Nothing leaves the process.
@MainActor
final class NativeUploadTests: XCTestCase {
    private var h: FixCreatorFanboxHarness!

    override func setUp() async throws {
        h = try await FixCreatorFanboxHarness()
    }

    override func tearDown() async throws {
        h?.cleanUp()
        h = nil
    }

    // MARK: Helpers

    private static func image(_ id: String, post: String = "9100", ext: String = "png") -> String {
        #"{"body":{"id":"\#(id)","extension":"\#(ext)","width":640,"height":480,"originalUrl":"https://downloads.fanbox.cc/images/post/\#(post)/\#(id).\#(ext)","thumbnailUrl":"https://downloads.fanbox.cc/images/post/\#(post)/w/1200/\#(id).jpeg"}}"#
    }

    private static func file(_ id: String, name: String, ext: String, post: String = "9100") -> String {
        #"{"body":{"id":"\#(id)","name":"\#(name)","extension":"\#(ext)","size":10,"url":"https://downloads.fanbox.cc/files/post/\#(post)/\#(id).\#(ext)"}}"#
    }

    private static func urlEmbed(_ id: String, url: String) -> String {
        #"{"body":{"id":"\#(id)","type":"default","url":"\#(url)","host":"example.com"}}"#
    }

    /// Adds an image / file block backed by a real local file stored as "<uuid>.<ext>" with display name `name`.
    @discardableResult
    private func addMedia(_ kind: DraftBlockKind, name: String, to draft: Draft) throws -> DraftBlock {
        try h.mediaStore.ensureDirectory(draftID: draft.id)
        let ext = URL(fileURLWithPath: name).pathExtension
        let stored = "\(UUID().uuidString).\(ext)"
        try Data("bytes-\(name)".utf8).write(to: h.mediaStore.fileURL(draftID: draft.id, fileName: stored))
        let block = h.drafts.addBlock(kind, to: draft)
        block.localFileName = stored
        block.originalFileName = name
        block.fileSize = 10
        h.store.save()
        return block
    }

    private func addLink(_ url: String, to draft: Draft) -> DraftBlock {
        let block = h.drafts.addBlock(.url, to: draft)
        block.url = url
        return block
    }

    private var keys: [String] { h.http.requests.map(\.endpointKey).filter { $0 != "www.metadata" } }

    private var lastUpdateBody: String? { h.updateBodies.last }

    /// The `body` field (JSON) of the last post.update form.
    private func lastUpdateBodyJSON() throws -> JSONValue {
        let form = try XCTUnwrap(lastUpdateBody)
        let start = try XCTUnwrap(form.range(of: "name=\"body\"\r\n\r\n"))
        let rest = form[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "\r\n"))
        return try JSONValue.parse(Data(rest[..<end.lowerBound].utf8))
    }

    // MARK: Full publish flow

    func testNewPostIsCreatedFirstThenMediaAndLinkCardsThenUpdatedWithTheirIDsInBlockOrder() async throws {
        h.http.stub("post.create", json: #"{"body":{"postId":"9100"}}"#)
        h.http.stub("post.addImage", json: Self.image("imgA"))
        h.http.stub("post.addImage", json: Self.image("imgB", ext: "jpeg"))
        h.http.stub("post.addFile", json: Self.file("f1", name: "資料", ext: "pdf"))
        h.http.stub("post.addUrlEmbed", json: Self.urlEmbed("ue1", url: "https://example.com/a"))
        h.http.stub("post.getEditable", json: FanboxFixtures.envelope(FixCreatorFixtures.editable(id: "9100")))
        h.http.stub("post.update", json: #"{"body":{"post":{"id":"9100","status":"published"}}}"#)

        let draft = h.drafts.createDraft(accountID: h.account.id)
        draft.title = "新作"
        draft.orderedBlocks[0].text = "本文"
        let a = try addMedia(.image, name: "1.png", to: draft)
        let link = addLink("https://example.com/a", to: draft)
        let b = try addMedia(.image, name: "2.jpeg", to: draft)
        let pdf = try addMedia(.file, name: "資料.pdf", to: draft)
        h.drafts.addBlock(.text, to: draft, text: "後書き")

        let plan = try XCTUnwrap(h.drafts.plan(draftID: draft.id, publish: true))
        XCTAssertTrue(plan.canSend)
        XCTAssertTrue(plan.webItems.isEmpty, "images, files and link cards are native for FANBOX now")
        XCTAssertTrue(plan.sendsPublished)
        XCTAssertTrue(plan.notes.contains { $0.contains("先に FANBOX に下書きを作成") }, "the confirmation explains the draft is created first")

        let receipt = try await h.drafts.send(draftID: draft.id, publish: true).get()

        XCTAssertEqual(receipt.postID, "9100")
        XCTAssertTrue(receipt.sentPublished)
        XCTAssertTrue(receipt.webItems.isEmpty)
        // post.create → the new post's revision (baseline) → uploads → link card → post.update (which re-reads the post)
        // → the revision after the save.
        XCTAssertEqual(keys, ["post.create", "post.getEditable", "post.addImage", "post.addImage", "post.addFile", "post.addUrlEmbed",
                              "post.getEditable", "post.update", "post.getEditable"])
        XCTAssertEqual(try lastUpdateBodyJSON(), [
            ["type": "p", "text": "本文"],
            ["type": "image", "imageId": "imgA"],
            ["type": "url_embed", "urlEmbedId": "ue1"],
            ["type": "image", "imageId": "imgB"],
            ["type": "file", "fileId": "f1"],
            ["type": "p", "text": "後書き"],
        ])
        let form = try XCTUnwrap(lastUpdateBody)
        XCTAssertTrue(form.contains("name=\"postId\"\r\n\r\n9100\r\n"))
        XCTAssertTrue(form.contains("name=\"status\"\r\n\r\npublished\r\n"))
        XCTAssertFalse(form.contains("imageMap"), "maps are never sent")
        XCTAssertFalse(form.contains("coverImage"), "the cover is left untouched")

        // Priorities: uploads are media (comment POSTs preempt them); create / link cards / update are interactive writes.
        XCTAssertTrue(h.http.requests(for: "post.addImage").allSatisfy { $0.priority == .foregroundMedia })
        XCTAssertTrue(h.http.requests(for: "post.addFile").allSatisfy { $0.priority == .foregroundMedia })
        XCTAssertEqual(h.http.requests(for: "post.create").first?.priority, .interactiveWrite)
        XCTAssertEqual(h.http.requests(for: "post.addUrlEmbed").first?.priority, .interactiveWrite)
        XCTAssertEqual(h.http.requests(for: "post.update").first?.priority, .interactiveWrite)

        // Upload bodies: postId + the display name + tt, streamed (no body file ever holds the token).
        let uploads = h.http.uploadRecords
        XCTAssertEqual(uploads.map(\.endpointKey), ["post.addImage", "post.addImage", "post.addFile"])
        for record in uploads {
            let body = String(decoding: record.body, as: UTF8.self)
            XCTAssertTrue(body.contains("name=\"postId\"\r\n\r\n9100\r\n"))
            XCTAssertTrue(body.contains("name=\"tt\"\r\n\r\ntok-abc\r\n"))
            XCTAssertNil(record.fileURL, "streamed: no body file")
        }
        XCTAssertTrue(String(decoding: uploads[2].body, as: UTF8.self).contains("filename=\"資料.pdf\""), "attachment keeps its name")

        // Local state: ids, results and the post id are kept; nothing left to upload.
        XCTAssertEqual(draft.remotePostID, "9100")
        XCTAssertEqual(draft.status, .published)
        XCTAssertEqual([a, b, pdf, link].map(\.remoteMediaID), ["imgA", "imgB", "f1", "ue1"])
        XCTAssertEqual(a.remoteMedia?.postID, "9100")
        XCTAssertEqual(a.remoteMedia?.thumbnailURL, "https://downloads.fanbox.cc/images/post/9100/w/1200/imgA.jpeg")
        XCTAssertEqual(pdf.remoteMedia?.fileName, "資料")
        XCTAssertEqual(link.remoteMedia?.postID, "9100")
        XCTAssertTrue(h.uploads.jobs(draftID: draft.id).allSatisfy { $0.state == .completed })
        let staging = (try? FileManager.default.contentsOfDirectory(atPath: h.mediaStore.uploadStagingDirectory.path)) ?? []
        XCTAssertTrue(staging.isEmpty, "per-job staging links are removed")
    }

    // MARK: Failures keep the draft, its post id and completed media

    func testRemotePostIDIsPersistedBeforeUploadsAndOnlyTheFailedUploadIsRetried() async throws {
        h.http.stub("post.create", json: #"{"body":{"postId":"9100"}}"#)
        h.http.stub("post.addImage", json: Self.image("imgA"))
        h.http.stub("post.addImage", status: 500, json: #"{"error":"general_error"}"#)
        h.http.stub("post.addImage", json: Self.image("imgB"))
        h.http.stub("post.addFile", json: Self.file("f1", name: "a", ext: "zip"))
        h.http.stub("post.getEditable", json: FanboxFixtures.envelope(FixCreatorFixtures.editable(id: "9100")))
        h.http.stub("post.update", json: #"{"body":{"post":{"id":"9100","status":"draft"}}}"#)

        let draft = h.drafts.createDraft(accountID: h.account.id)
        draft.title = "T"
        draft.orderedBlocks[0].text = "本文"
        let a = try addMedia(.image, name: "a.png", to: draft)
        let b = try addMedia(.image, name: "b.png", to: draft)
        let zip = try addMedia(.file, name: "a.zip", to: draft)

        let first = await h.drafts.send(draftID: draft.id, publish: false)
        guard case .failure(.invalidRequest) = first else { return XCTFail("expected the upload failure, got \(first)") }
        XCTAssertEqual(draft.remotePostID, "9100", "stored right after post.create, before any upload")
        XCTAssertEqual(draft.remoteStatus, .draft)
        XCTAssertEqual(draft.status, .failed)
        XCTAssertTrue(draft.lastError?.contains("作成済み") ?? false, draft.lastError ?? "")
        XCTAssertEqual(h.uploads.jobs(draftID: draft.id).map(\.state), [.completed, .failed, .completed])
        XCTAssertEqual(a.remoteMediaID, "imgA", "partial success keeps completed ids")
        XCTAssertNil(b.remoteMediaID)
        XCTAssertEqual(zip.remoteMediaID, "f1")
        XCTAssertTrue(h.http.requests(for: "post.update").isEmpty, "nothing is saved with a missing image")
        XCTAssertEqual(draft.blocks.count, 4, "the local draft is intact")

        let second = try await h.drafts.send(draftID: draft.id, publish: false).get()
        XCTAssertEqual(second.postID, "9100")
        XCTAssertEqual(h.http.requests(for: "post.create").count, 1, "never a second post.create (no orphan duplicates)")
        XCTAssertEqual(h.http.uploadRecords(for: "post.addImage").count, 3, "a.png once, b.png twice")
        XCTAssertEqual(h.http.uploadRecords(for: "post.addFile").count, 1, "completed uploads are not re-sent")
        XCTAssertEqual(b.remoteMediaID, "imgB")
        XCTAssertEqual(h.uploads.jobs(draftID: draft.id).map(\.state), [.completed, .completed, .completed])
        XCTAssertEqual(try lastUpdateBodyJSON(), [
            ["type": "p", "text": "本文"],
            ["type": "image", "imageId": "imgA"],
            ["type": "image", "imageId": "imgB"],
            ["type": "file", "fileId": "f1"],
        ])
        XCTAssertEqual(draft.status, .readyToPublish)
    }

    func testFailedLinkCardIsRetriedAloneAndFailedCreateSendsNothing() async throws {
        // post.create itself fails: nothing is uploaded, no id is stored.
        h.http.stub("post.create", status: 500, json: #"{"error":"general_error"}"#)
        let draft = h.drafts.createDraft(accountID: h.account.id)
        draft.title = "T"
        let first = addLink("https://example.com/one", to: draft)
        let second = addLink("https://example.com/two", to: draft)
        let failedCreate = await h.drafts.send(draftID: draft.id, publish: false)
        XCTAssertEqual(failedCreate.failureValue, .server(status: 500))
        XCTAssertNil(draft.remotePostID)
        XCTAssertEqual(keys, ["post.create"])

        // Create works; the second card fails once.
        h.http.stub("post.create", json: #"{"body":{"postId":"9200"}}"#)
        h.http.stub("post.addUrlEmbed", json: Self.urlEmbed("ue1", url: "https://example.com/one"))
        h.http.stub("post.addUrlEmbed", status: 500, json: #"{"error":"general_error"}"#)
        h.http.stub("post.addUrlEmbed", json: Self.urlEmbed("ue2", url: "https://example.com/two"))
        h.http.stub("post.getEditable", json: FanboxFixtures.envelope(FixCreatorFixtures.editable(id: "9200")))
        h.http.stub("post.update", json: #"{"body":{"post":{"id":"9200","status":"draft"}}}"#)
        let partial = await h.drafts.send(draftID: draft.id, publish: false)
        guard case .failure(.invalidRequest(let message)) = partial else { return XCTFail("\(partial)") }
        XCTAssertTrue(message.contains("リンクカード"))
        XCTAssertEqual(draft.remotePostID, "9200")
        XCTAssertEqual(first.remoteMediaID, "ue1")
        XCTAssertNil(second.remoteMediaID)

        _ = try await h.drafts.send(draftID: draft.id, publish: false).get()
        let embedURLs = h.http.requests(for: "post.addUrlEmbed").map { String(decoding: $0.body ?? Data(), as: UTF8.self) }
        XCTAssertEqual(embedURLs.filter { $0.contains("https://example.com/one") }.count, 1, "a registered card is never registered again")
        XCTAssertEqual(embedURLs.filter { $0.contains("https://example.com/two") }.count, 2)
        XCTAssertEqual(h.http.requests(for: "post.create").count, 2, "one failed + one successful create; the retry reused 9200")
        XCTAssertEqual(try lastUpdateBodyJSON(), [["type": "url_embed", "urlEmbedId": "ue1"], ["type": "url_embed", "urlEmbedId": "ue2"]])
    }

    func testUpdateFailureAfterUploadsNeverReuploads() async throws {
        h.http.stub("post.create", json: #"{"body":{"postId":"9300"}}"#)
        h.http.stub("post.addImage", json: Self.image("imgA", post: "9300"))
        h.http.stub("post.getEditable", json: FanboxFixtures.envelope(FixCreatorFixtures.editable(id: "9300")))
        h.http.stub("post.update", status: 500, json: #"{"error":"general_error"}"#)
        h.http.stub("post.update", json: #"{"body":{"post":{"id":"9300","status":"published"}}}"#)
        let draft = h.drafts.createDraft(accountID: h.account.id)
        draft.title = "T"
        try addMedia(.image, name: "a.png", to: draft)

        let first = await h.drafts.send(draftID: draft.id, publish: true)
        XCTAssertEqual(first.failureValue, .server(status: 500))
        XCTAssertTrue(draft.lastError?.contains("同じ下書きを更新") ?? false, draft.lastError ?? "")
        XCTAssertEqual(draft.remotePostID, "9300")

        _ = try await h.drafts.send(draftID: draft.id, publish: true).get()
        XCTAssertEqual(h.http.requests(for: "post.create").count, 1)
        XCTAssertEqual(h.http.uploadRecords(for: "post.addImage").count, 1, "the uploaded image is referenced again by id")
        XCTAssertEqual(try lastUpdateBodyJSON(), [["type": "image", "imageId": "imgA"]])
        XCTAssertEqual(draft.status, .published)
    }

    // MARK: Manual start for a new post

    func testManualUploadOfANewPostWaitsForTheSendInsteadOfCreatingAPost() async throws {
        let draft = h.drafts.createDraft(accountID: h.account.id)
        draft.title = "T"
        try addMedia(.image, name: "a.png", to: draft)
        h.uploads.enqueue(draftID: draft.id)
        await h.uploads.run()

        XCTAssertTrue(h.http.requests.isEmpty, "no FANBOX post is created by tapping upload")
        let job = try XCTUnwrap(h.uploads.jobs(draftID: draft.id).first)
        XCTAssertEqual(job.state, .paused)
        XCTAssertEqual(job.lastError, UploadQueue.awaitingPostMessage)
        XCTAssertEqual(h.uploads.retryFailed(draftID: draft.id, autoStart: false), 0, "waiting is not a failure")

        // The send creates the post and resumes the waiting job.
        h.http.stub("post.create", json: #"{"body":{"postId":"9400"}}"#)
        h.http.stub("post.addImage", json: Self.image("imgA", post: "9400"))
        h.http.stub("post.getEditable", json: FanboxFixtures.envelope(FixCreatorFixtures.editable(id: "9400")))
        h.http.stub("post.update", json: #"{"body":{"post":{"id":"9400","status":"draft"}}}"#)
        _ = try await h.drafts.send(draftID: draft.id, publish: false).get()
        XCTAssertEqual(keys, ["post.create", "post.getEditable", "post.addImage", "post.getEditable", "post.update", "post.getEditable"])
        XCTAssertEqual(h.uploads.jobs(draftID: draft.id).map(\.state), [.completed])

        // Once the post exists, a manual start uploads straight into it after checking the post's revision, and adopts
        // the revision the upload produced.
        try addMedia(.image, name: "b.png", to: draft)
        h.http.stub("post.addImage", json: Self.image("imgB", post: "9400"))
        let before = h.http.requests.count
        h.uploads.enqueue(draftID: draft.id)
        await h.uploads.run()
        XCTAssertEqual(h.uploads.jobs(draftID: draft.id).map(\.state), [.completed, .completed])
        XCTAssertEqual(h.http.requests.dropFirst(before).map(\.endpointKey), ["post.getEditable", "post.addImage", "post.getEditable"])
        XCTAssertEqual(h.http.requests(for: "post.create").count, 1)
    }

    func testPlanRejectsFilesFANBOXWouldRefuseBeforeAnythingIsCreated() async throws {
        let draft = h.drafts.createDraft(accountID: h.account.id)
        draft.title = "T"
        let doc = try addMedia(.file, name: "memo.docx", to: draft)
        let plan = try XCTUnwrap(h.drafts.plan(draftID: draft.id, publish: true))
        XCTAssertFalse(plan.canSend)
        XCTAssertTrue(plan.blockers.first?.contains("memo.docx") ?? false, plan.blockers.joined())
        let refused = await h.drafts.send(draftID: draft.id, publish: true)
        guard case .failure(.invalidRequest) = refused else { return XCTFail("\(refused)") }
        XCTAssertTrue(h.http.requests.isEmpty, "no post.create for a draft that cannot be uploaded")

        h.drafts.deleteBlock(doc)
        let big = try addMedia(.image, name: "huge.png", to: draft)
        big.fileSize = FanboxUploadForm.maxImageBytes + 1
        XCTAssertTrue(h.drafts.plan(draftID: draft.id, publish: true)?.blockers.first?.contains("50 MB") ?? false)
        h.drafts.deleteBlock(big)
        _ = addLink("javascript:alert(1)", to: draft)
        XCTAssertFalse(h.drafts.plan(draftID: draft.id, publish: true)?.canSend ?? true, "only http(s) link cards")
    }

    // MARK: Imported image-type post

    func testImportedImagePostKeepsItsTypeAndListsImages() async throws {
        h.http.stub("post.getEditable", json: FanboxFixtures.envelope(#"""
        {"id":"p9","type":"image","title":"イラスト","status":"published","feeRequired":0,"tags":[],"commentingPermissionScope":"everyone",
         "updatedAt":"2026-09-06T10:00:00+09:00","publishedAt":"2026-09-06T10:00:00+09:00",
         "body":{"text":"一枚目の説明\n\n二段落目","images":[{"id":"i1","extension":"jpg","width":10,"height":20,
           "originalUrl":"https://downloads.fanbox.cc/images/post/p9/i1.jpg","thumbnailUrl":"https://downloads.fanbox.cc/images/post/p9/w/1200/i1.jpeg"}]}}
        """#))
        h.http.stub("post.addImage", json: Self.image("i2", post: "p9"))
        h.http.stub("post.update", json: #"{"body":{"post":{"id":"p9","status":"published"}}}"#)
        let draft = try await h.drafts.importRemotePost(postID: "p9", accountID: h.account.id)
        XCTAssertNil(draft.nativeUpdateBlocker)
        XCTAssertEqual(draft.remotePostType, .image)
        XCTAssertEqual(draft.orderedBlocks.map(\.kind), [.image, .text, .text])

        // A header cannot be stored in an image post: refused in the plan.
        let header = h.drafts.addBlock(.header, to: draft, text: "見出し")
        XCTAssertFalse(h.drafts.plan(draftID: draft.id, publish: true)?.canSend ?? true)
        h.drafts.deleteBlock(header)

        try addMedia(.image, name: "2.png", to: draft)
        let plan = try XCTUnwrap(h.drafts.plan(draftID: draft.id, publish: true))
        XCTAssertTrue(plan.canSend)
        XCTAssertTrue(plan.notes.contains { $0.contains("「画像」形式") })
        _ = try await h.drafts.send(draftID: draft.id, publish: true).get()

        XCTAssertTrue(h.http.requests(for: "post.create").isEmpty)
        XCTAssertEqual(h.http.uploadRecords(for: "post.addImage").count, 1)
        XCTAssertTrue(String(decoding: h.http.uploadRecords[0].body, as: UTF8.self).contains("name=\"postId\"\r\n\r\np9\r\n"))
        let body = try lastUpdateBodyJSON()
        XCTAssertEqual(body["text"], "一枚目の説明\n\n二段落目", "unchanged text is sent back as it was")
        XCTAssertEqual(body["images"]?.arrayValue?.compactMap { $0["id"]?.stringValue }, ["i1", "i2"])
        XCTAssertEqual(body["images"]?[1], ["id": "i2", "originalUrl": "https://downloads.fanbox.cc/images/post/p9/i2.png",
                                            "thumbnailUrl": "https://downloads.fanbox.cc/images/post/p9/w/1200/i2.jpeg",
                                            "width": 640, "height": 480, "extension": "png"])
        XCTAssertNil(body["blocks"])
        XCTAssertEqual(draft.orderedBlocks.filter { $0.kind == .text }.map(\.text), ["一枚目の説明", "二段落目"],
                       "text blocks stay paragraphs (never split by line) in an image post")
    }

    // MARK: Revision baseline (the app's own writes are not edits made elsewhere)

    /// Editable article `id` at revision `updatedAt` (status draft).
    private static func editable(_ id: String, updatedAt: String, status: String = "draft", type: String = "article") -> String {
        FanboxFixtures.envelope(#"{"id":"\#(id)","type":"\#(type)","title":"T","status":"\#(status)","feeRequired":0,"tags":[],"#
            + #""commentingPermissionScope":"everyone","updatedAt":"\#(updatedAt)","body":{"blocks":[{"type":"p","text":"本文"}],"#
            + #""imageMap":{},"urlEmbedMap":{}}}"#)
    }

    func testRetryAfterOwnUploadsBumpedTheRevisionIsNotAConflict() async throws {
        // FANBOX may bump updatedAt for every asset stored into the post: 10:00 → 10:05 after the first send's uploads.
        h.http.stub("post.getEditable", json: Self.editable("p7", updatedAt: "2026-09-06T10:00:00+09:00"))   // import
        h.http.stub("post.getEditable", json: Self.editable("p7", updatedAt: "2026-09-06T10:00:00+09:00"))   // send 1 check
        h.http.stub("post.getEditable", json: Self.editable("p7", updatedAt: "2026-09-06T10:05:00+09:00"))   // after the uploads
        h.http.stub("post.addImage", json: Self.image("imgA", post: "p7"))
        h.http.stub("post.addImage", status: 500, json: #"{"error":"general_error"}"#)
        h.http.stub("post.addImage", json: Self.image("imgB", post: "p7"))
        h.http.stub("post.update", json: #"{"body":{"post":{"id":"p7","status":"draft"}}}"#)
        let draft = try await h.drafts.importRemotePost(postID: "p7", accountID: h.account.id)
        try addMedia(.image, name: "a.png", to: draft)
        try addMedia(.image, name: "b.png", to: draft)

        let first = await h.drafts.send(draftID: draft.id, publish: false)
        guard case .failure(.invalidRequest) = first else { return XCTFail("expected the upload failure, got \(first)") }
        XCTAssertEqual(draft.remoteUpdatedAt, FanboxFixtures.date("2026-09-06T10:05:00+09:00"),
                       "the revision after the send's own uploads becomes the baseline")

        let receipt = try await h.drafts.send(draftID: draft.id, publish: false).get()
        XCTAssertEqual(receipt.postID, "p7")
        XCTAssertEqual(h.http.uploadRecords(for: "post.addImage").count, 3, "a.png once, b.png twice")
        XCTAssertEqual(try lastUpdateBodyJSON(), [["type": "p", "text": "本文"], ["type": "image", "imageId": "imgA"],
                                                  ["type": "image", "imageId": "imgB"]])
    }

    func testCreatedPostGetsABaselineSoAWebEditBetweenRetriesIsDetected() async throws {
        h.http.stub("post.create", json: #"{"body":{"postId":"9500"}}"#)
        h.http.stub("post.getEditable", json: Self.editable("9500", updatedAt: "2026-09-06T10:00:00+09:00"))
        h.http.stub("post.addImage", status: 500, json: #"{"error":"general_error"}"#)
        let draft = h.drafts.createDraft(accountID: h.account.id)
        draft.title = "T"
        try addMedia(.image, name: "a.png", to: draft)

        let first = await h.drafts.send(draftID: draft.id, publish: false)
        guard case .failure = first else { return XCTFail("\(first)") }
        XCTAssertEqual(draft.remotePostID, "9500")
        XCTAssertEqual(draft.remoteUpdatedAt, FanboxFixtures.date("2026-09-06T10:00:00+09:00"), "read right after post.create")

        // The creator edits the FANBOX draft in the web editor before retrying.
        h.http.stub("post.getEditable", json: Self.editable("9500", updatedAt: "2026-09-06T11:00:00+09:00"))
        let second = await h.drafts.send(draftID: draft.id, publish: false)
        XCTAssertEqual(second.failureValue, .invalidRequest(DraftService.conflictMessage))
        XCTAssertEqual(h.http.uploadRecords(for: "post.addImage").count, 1, "nothing is uploaded over an edit made elsewhere")
        XCTAssertTrue(h.http.requests(for: "post.update").isEmpty)
    }

    func testQueuePausesUploadsIntoAPostEditedElsewhere() async throws {
        h.http.stub("post.getEditable", json: Self.editable("p8", updatedAt: "2026-09-06T10:00:00+09:00"))
        let draft = try await h.drafts.importRemotePost(postID: "p8", accountID: h.account.id)
        try addMedia(.image, name: "a.png", to: draft)
        h.http.stub("post.getEditable", json: Self.editable("p8", updatedAt: "2026-09-07T09:00:00+09:00"))
        h.uploads.enqueue(draftID: draft.id)
        await h.uploads.run()

        let job = try XCTUnwrap(h.uploads.jobs(draftID: draft.id).first)
        XCTAssertEqual(job.state, .paused, "never a failure; the send reports the conflict")
        XCTAssertEqual(job.lastError, UploadQueue.conflictMessage)
        XCTAssertTrue(h.http.uploadRecords.isEmpty)
        XCTAssertEqual(draft.remoteUpdatedAt, FanboxFixtures.date("2026-09-06T10:00:00+09:00"), "the baseline is kept")
    }

    // MARK: Uploads the app could never save

    func testQueueNeverUploadsIntoAPostItCannotSave() async throws {
        // A video post is blocked from native updates: its uploads would stay behind on FANBOX unused.
        h.http.stub("post.getEditable", json: Self.editable("v1", updatedAt: "2026-09-06T10:00:00+09:00", type: "video"))
        let video = try await h.drafts.importRemotePost(postID: "v1", accountID: h.account.id)
        XCTAssertNotNil(video.nativeUpdateBlocker)
        try addMedia(.image, name: "a.png", to: video)
        h.uploads.enqueue(draftID: video.id)
        await h.uploads.run()
        XCTAssertEqual(h.uploads.jobs(draftID: video.id).map(\.state), [.paused])
        XCTAssertEqual(h.uploads.jobs(draftID: video.id).first?.lastError, UploadQueue.webOnlyMessage)

        // An image-type post holds images, never files: the file waits, the image uploads.
        h.http.stub("post.getEditable", json: Self.editable("i1", updatedAt: "2026-09-06T10:00:00+09:00", type: "image"))
        let imagePost = try await h.drafts.importRemotePost(postID: "i1", accountID: h.account.id)
        XCTAssertNil(imagePost.nativeUpdateBlocker)
        try addMedia(.file, name: "a.zip", to: imagePost)
        try addMedia(.image, name: "b.png", to: imagePost)
        h.http.stub("post.addImage", json: Self.image("i2", post: "i1"))
        h.uploads.enqueue(draftID: imagePost.id)
        await h.uploads.run()
        let jobs = h.uploads.jobs(draftID: imagePost.id)
        XCTAssertEqual(jobs.map(\.state), [.paused, .completed])
        XCTAssertTrue(jobs[0].lastError?.contains("「画像」形式の投稿にはファイルを保存できません") ?? false, jobs[0].lastError ?? "")
        XCTAssertTrue(h.http.uploadRecords(for: "post.addFile").isEmpty)
        XCTAssertEqual(h.http.uploadRecords(for: "post.addImage").count, 1)
    }

    // MARK: Input refused before a FANBOX draft is created

    func testMissingLocalFileAndOverlongLinkAreRefusedBeforePostCreate() async throws {
        let draft = h.drafts.createDraft(accountID: h.account.id)
        draft.title = "T"
        let image = try addMedia(.image, name: "a.png", to: draft)
        h.mediaStore.removeFile(draftID: draft.id, fileName: try XCTUnwrap(image.localFileName))
        let plan = try XCTUnwrap(h.drafts.plan(draftID: draft.id, publish: false))
        XCTAssertFalse(plan.canSend)
        XCTAssertTrue(plan.blockers.first?.contains("a.png") ?? false, plan.blockers.joined())
        let refused = await h.drafts.send(draftID: draft.id, publish: false)
        guard case .failure(.invalidRequest) = refused else { return XCTFail("\(refused)") }
        XCTAssertTrue(h.http.requests.isEmpty, "no post.create for a file that cannot be uploaded")
        h.drafts.deleteBlock(image)

        let long = addLink("https://example.com/" + String(repeating: "x", count: DraftPostMapping.maxLinkCardURLLength), to: draft)
        XCTAssertTrue(h.drafts.plan(draftID: draft.id, publish: false)?.blockers.first?.contains("長すぎます") ?? false)
        let refusedLink = await h.drafts.send(draftID: draft.id, publish: false)
        guard case .failure(.invalidRequest) = refusedLink else { return XCTFail("\(refusedLink)") }
        XCTAssertTrue(h.http.requests.isEmpty)
        long.url = "https://example.com/" + String(repeating: "x", count: DraftPostMapping.maxLinkCardURLLength - 20)
        XCTAssertTrue(h.drafts.plan(draftID: draft.id, publish: false)?.canSend ?? false, "2048 characters are fine")
    }

    func testOfflineLinkCardFailureStillSaysADraftWasCreated() async throws {
        h.http.stub("post.create", json: #"{"body":{"postId":"9600"}}"#)
        h.http.stub("post.getEditable", json: Self.editable("9600", updatedAt: "2026-09-06T10:00:00+09:00"))
        h.http.failTransport("post.addUrlEmbed", with: URLError(.notConnectedToInternet))
        let draft = h.drafts.createDraft(accountID: h.account.id)
        draft.title = "T"
        _ = addLink("https://example.com/a", to: draft)

        let result = await h.drafts.send(draftID: draft.id, publish: false)
        XCTAssertEqual(result.failureValue, .offline)
        XCTAssertEqual(draft.remotePostID, "9600")
        XCTAssertTrue(draft.lastError?.contains(DraftService.createdDraftNote) ?? false, draft.lastError ?? "")
    }

    // MARK: Cleanup after failed / paused uploads

    private var multipartBodyFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])
            .filter { $0.hasPrefix(MultipartFormData.temporaryFilePrefix) }
    }

    private var stagingEntries: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: h.mediaStore.uploadStagingDirectory.path)) ?? []
    }

    func testFailedUploadRemovesItsStagingLinkAndWritesNoBodyFile() async throws {
        h.http.stub("post.getEditable", json: Self.editable("p9", updatedAt: "2026-09-06T10:00:00+09:00"))
        h.http.stub("post.addFile", status: 500, json: #"{"error":"general_error"}"#)
        let draft = try await h.drafts.importRemotePost(postID: "p9", accountID: h.account.id)
        try addMedia(.file, name: "a.zip", to: draft)
        let before = multipartBodyFiles.count
        h.uploads.enqueue(draftID: draft.id)
        await h.uploads.run()

        XCTAssertEqual(h.uploads.jobs(draftID: draft.id).map(\.state), [.failed])
        XCTAssertEqual(h.http.uploadRecords(for: "post.addFile").count, 1, "a 500 is not retried")
        XCTAssertTrue(stagingEntries.isEmpty, "the per-job staging link is removed after the failure")
        XCTAssertEqual(multipartBodyFiles.count, before, "no body file was written")
    }

    func testPausingAnUploadMidwayLeavesItPausedAndCleansUp() async throws {
        h.http.stub("post.getEditable", json: Self.editable("p10", updatedAt: "2026-09-06T10:00:00+09:00"))
        let draft = try await h.drafts.importRemotePost(postID: "p10", accountID: h.account.id)
        try addMedia(.image, name: "a.png", to: draft)
        let before = multipartBodyFiles.count
        h.http.holdsUploads = true
        let job = try XCTUnwrap(h.uploads.enqueue(draftID: draft.id).first)
        let run = Task { await h.uploads.run() }

        await h.http.waitForHeldUpload()
        XCTAssertEqual(job.state, .uploading)
        XCTAssertFalse(stagingEntries.isEmpty, "the staging link exists while the upload runs")
        h.uploads.pause(jobID: job.id)
        await run.value

        XCTAssertEqual(job.state, .paused, "paused, not failed")
        XCTAssertEqual(job.progress, 0)
        XCTAssertTrue(stagingEntries.isEmpty, "the staging link is removed when the upload is cancelled")
        XCTAssertEqual(multipartBodyFiles.count, before, "no body file was written")
        XCTAssertEqual(h.http.uploadRecords(for: "post.addImage").count, 1)
    }

    func testEnqueueReusesACompletedUploadOnlyForTheSamePost() throws {
        /// A draft on `post` whose image was uploaded into `uploadedInto`, but whose block lost the write-back (app killed
        /// at the wrong moment).
        func draftWithLostWriteBack(post: String, uploadedInto: String) throws -> (Draft, DraftBlock) {
            let draft = h.drafts.createDraft(accountID: h.account.id)
            draft.title = "T"
            draft.remotePostID = post
            let block = try addMedia(.image, name: "a.png", to: draft)
            let done = UploadJob(draftID: draft.id, draftBlockID: block.id, accountID: h.account.id, fileName: "a.png",
                                 localFileName: try XCTUnwrap(block.localFileName), kind: .image, bytesTotal: 10, order: block.order)
            done.state = .completed
            done.remoteMediaID = "img-\(uploadedInto)"
            done.remoteMedia = RemoteUploadResult(mediaID: "img-\(uploadedInto)", url: nil, postID: uploadedInto)
            h.store.context.insert(done)
            h.store.save()
            return (draft, block)
        }

        // Same post: the completed upload is reused, nothing is queued.
        let (same, sameBlock) = try draftWithLostWriteBack(post: "A", uploadedInto: "A")
        XCTAssertEqual(h.uploads.enqueue(draftID: same.id).map(\.state), [.completed])
        XCTAssertEqual(sameBlock.remoteMediaID, "img-A")

        // Another post: an asset stored into A can never be referenced by B's save, so the image is uploaded again.
        let (other, otherBlock) = try draftWithLostWriteBack(post: "B", uploadedInto: "A")
        let jobs = h.uploads.enqueue(draftID: other.id)
        XCTAssertEqual(Set(jobs.map(\.state)), [.completed, .queued])
        XCTAssertNil(otherBlock.remoteMediaID, "not reused across posts")
    }

    // MARK: Demo parity

    func testDemoRunsTheSameCreateUploadUpdateFlow() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = LocalStore(container: container)
        let settings = AppSettings(defaults: UserDefaults(suiteName: "native-upload-demo-\(UUID().uuidString)")!)
        settings.networkModePreference = .normal
        let network = NetworkModeController(settings: settings, policyStore: NetworkPolicyStore())
        network.recompute()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeUploadDemo-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = DraftMediaStore(rootDirectory: root)
        let world = DemoWorld(now: Date(timeIntervalSince1970: 1_790_000_000), latencyScale: 0)
        let demo = DemoRemoteDataSource(policy: nil, world: world)
        let provider = FixCreatorProvider(source: demo)
        let uploads = UploadQueue(store: store, remote: provider, network: network, mediaStore: media)
        let drafts = DraftService(store: store, uploads: uploads, remote: provider, web: WebBridge())
        let account = Account(kind: .demo, displayName: "Demo Creator", pixivUserID: "demo-cr0001", creatorID: DemoFixtures.selfCreatorID)
        store.context.insert(account)
        store.save()

        let draft = drafts.createDraft(accountID: account.id)
        draft.title = "Demo 投稿"
        draft.orderedBlocks[0].text = "本文"
        func add(_ kind: DraftBlockKind, _ name: String) throws -> DraftBlock {
            try media.ensureDirectory(draftID: draft.id)
            let stored = "\(UUID().uuidString).\(URL(fileURLWithPath: name).pathExtension)"
            try Data("bytes".utf8).write(to: media.fileURL(draftID: draft.id, fileName: stored))
            let block = drafts.addBlock(kind, to: draft)
            block.localFileName = stored
            block.originalFileName = name
            block.fileSize = 5
            return block
        }
        let image = try add(.image, "1.png")
        let failing = try add(.file, "fail.zip")
        let link = drafts.addBlock(.url, to: draft)
        link.url = "https://example.com/demo"

        let first = await drafts.send(draftID: draft.id, publish: true)
        guard case .failure(.invalidRequest) = first else { return XCTFail("the \"fail\" file must fail, got \(first)") }
        let postID = try XCTUnwrap(draft.remotePostID, "the demo creates the post first too")
        XCTAssertTrue(postID.hasPrefix("demo-post-new-"))
        XCTAssertNotNil(image.remoteMediaID)
        XCTAssertEqual(image.remoteMedia?.postID, postID)
        XCTAssertEqual(uploads.jobs(draftID: draft.id).map(\.state), [.completed, .failed])

        // Replace the failing file; only it is uploaded, then the link card is registered and the post saved.
        drafts.deleteBlock(failing)
        let zip = try add(.file, "ok.zip")
        let receipt = try await drafts.send(draftID: draft.id, publish: true).get()
        XCTAssertEqual(receipt.postID, postID)
        XCTAssertNotNil(zip.remoteMediaID)
        XCTAssertTrue(link.remoteMediaID?.hasPrefix("demo-urlembed-") ?? false)
        let stored = try await demo.editablePost(id: postID, account: account.context)
        XCTAssertEqual(stored.status, .published)
        XCTAssertEqual(stored.title, "Demo 投稿")
        XCTAssertEqual(stored.blocks.map(\.kind), [.paragraph, .image, .url, .file])
        XCTAssertEqual(stored.blocks[1].mediaID, image.remoteMediaID)
        XCTAssertEqual(stored.blocks[2].mediaID, link.remoteMediaID)
        XCTAssertEqual(stored.blocks[2].url, "https://example.com/demo")
        XCTAssertEqual(stored.blocks[3].mediaID, zip.remoteMediaID)

        // Demo uploads into a post of someone else are refused.
        do {
            _ = try await demo.addURLEmbed(url: "https://example.com", postID: "demo-post-101", account: account.context)
            XCTFail("not the self creator's post")
        } catch let error as RemoteError {
            XCTAssertEqual(error, .notFound)
        }
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
