import XCTest
@testable import FANBOXClient

/// Request building (URL, query, method, CSRF flag, JSON body, headers, task-local priority), data source flows with a
/// scripted HTTP client, cursors, error mapping, CSRF refresh and API Inspector invocation.
final class FanboxClientTests: XCTestCase {
    // MARK: Request building

    func testRequestBuildingForReadsAndWrites() throws {
        let h = FanboxTestHarness()
        let read = try h.api.makeRequest(.getComments(postID: "6001", offset: 0, limit: 20))
        XCTAssertEqual(read.method, "GET")
        XCTAssertEqual(read.url.absoluteString, "https://api.fanbox.cc/post.getComments?postId=6001&offset=0&limit=20")
        XCTAssertEqual(read.endpointKey, "post.getComments")
        XCTAssertFalse(read.requiresCSRF)
        XCTAssertNil(read.body)
        XCTAssertEqual(read.headers["Origin"], "https://www.fanbox.cc")
        XCTAssertEqual(read.headers["Referer"], "https://www.fanbox.cc/")
        XCTAssertEqual(read.headers["Accept"], "application/json, text/plain, */*")
        XCTAssertNil(read.headers["Cookie"], "cookies are added by the per-account transport only")
        XCTAssertEqual(read.priority, .backgroundSync, "default task-local priority")

        let write = try h.api.makeRequest(.addComment(postID: "6001", body: "こんにちは", rootCommentID: nil, parentCommentID: nil))
        XCTAssertEqual(write.method, "POST")
        XCTAssertEqual(write.url.absoluteString, "https://api.fanbox.cc/post.addComment")
        XCTAssertTrue(write.requiresCSRF)
        XCTAssertEqual(write.headers["Content-Type"], "application/json")
        XCTAssertEqual(try JSONValue.parse(write.body ?? Data()),
                       ["postId": "6001", "body": "こんにちは", "rootCommentId": "0", "parentCommentId": "0"])

        let reply = try h.api.makeRequest(.addComment(postID: "1", body: "b", rootCommentID: "c1", parentCommentID: "c2"))
        XCTAssertEqual(try JSONValue.parse(reply.body ?? Data())["rootCommentId"], "c1")
        XCTAssertEqual(try JSONValue.parse(reply.body ?? Data())["parentCommentId"], "c2")
        let replyToRoot = try h.api.makeRequest(.addComment(postID: "1", body: "b", rootCommentID: nil, parentCommentID: "c1"))
        XCTAssertEqual(try JSONValue.parse(replyToRoot.body ?? Data())["rootCommentId"], "c1")

        let follow = try h.api.makeRequest(.followCreate(creatorUserID: "11"))
        XCTAssertEqual(try JSONValue.parse(follow.body ?? Data()), ["creatorUserId": "11"], "id sent as a JSON string")
        XCTAssertTrue(follow.requiresCSRF)

        let legacy = try h.api.makeRequest(.supportCreator(creatorID: "alice"))
        XCTAssertEqual(legacy.url.absoluteString, "https://api.fanbox.cc/legacy/support/creator?creatorId=alice")
        XCTAssertEqual(legacy.endpointKey, "legacy.support.creator")
        XCTAssertEqual(try h.api.makeRequest(.pledgeMonthly(month: "2026-09")).url.absoluteString,
                       "https://api.fanbox.cc/legacy/manage/pledge/monthly?month=2026-09")
        XCTAssertEqual(try h.api.makeRequest(.bellList(page: 1)).url.absoluteString,
                       "https://api.fanbox.cc/bell.list?page=1&skipConvertUnreadNotification=1&commentOnly=0")

        let www = try h.api.makeRequest(.homepageMetadata())
        XCTAssertEqual(www.url.absoluteString, "https://www.fanbox.cc/")
        XCTAssertNil(www.headers["Origin"])
        XCTAssertTrue(www.headers["Accept"]?.hasPrefix("text/html") ?? false)
    }

    func testPriorityComesFromRequestContext() async throws {
        let h = FanboxTestHarness()
        let request = try RequestContext.$priority.withValue(.interactiveWrite) { try h.api.makeRequest(.likePost(postID: "1")) }
        XCTAssertEqual(request.priority, .interactiveWrite)

        h.http.stub("creator.get", json: FanboxFixtures.envelope(FanboxFixtures.creator))
        _ = try await RequestContext.$priority.withValue(.notificationPrefetch) {
            try await h.source.creator(id: "alice", account: FanboxTestHarness.fan)
        }
        XCTAssertEqual(h.http.requests.last?.priority, .notificationPrefetch)
        XCTAssertEqual(h.http.accountIDs.last, "acc-fan", "request is sent for the account's session")
    }

    func testQueryEncodingAndCursorURLValidation() throws {
        let plus = FanboxEndpoint(key: "post.listCreator", query: [.init(name: "firstPublishedDatetime", value: "2026-09-01T00:00:00+09:00")])
        XCTAssertEqual(plus.url.absoluteString, "https://api.fanbox.cc/post.listCreator?firstPublishedDatetime=2026-09-01T00:00:00%2B09:00")
        let tag = FanboxEndpoint.listTagged(tag: "オリジナル", creatorID: "alice", page: 0)
        XCTAssertEqual(URLComponents(url: tag.url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "オリジナル")

        let next = "https://api.fanbox.cc/post.listHome?limit=10&maxPublishedDatetime=2026-08-30%2009%3A00%3A00&maxId=4999"
        let followed = try XCTUnwrap(FanboxEndpoint.followURL(next, key: "post.listHome", expectedPath: "/post.listHome"))
        XCTAssertEqual(followed.url.absoluteString, next, "nextUrl replayed byte-for-byte")
        XCTAssertNil(FanboxEndpoint.followURL("https://evil.example/post.listHome?x=1", key: "k", expectedPath: "/post.listHome"))
        XCTAssertNil(FanboxEndpoint.followURL("http://api.fanbox.cc/post.listHome", key: "k", expectedPath: "/post.listHome"))
        XCTAssertNil(FanboxEndpoint.followURL("https://api.fanbox.cc/post.delete?postId=1", key: "k", expectedPath: "/post.listHome"))
        XCTAssertNotNil(FanboxEndpoint.followURL("/post.listHome?limit=10", key: "k", expectedPath: "/post.listHome"))
    }

    // MARK: Timelines / cursors

    func testHomeTimelinePagingAndInspector() async throws {
        let h = FanboxTestHarness()
        h.http.stub("post.listHome", json: FanboxFixtures.envelope(FanboxFixtures.homeTimeline))
        let page = try await h.source.homeTimeline(account: FanboxTestHarness.fan, cursor: nil)
        XCTAssertEqual(page.items.map(\.id), ["5001", "5000"])
        XCTAssertEqual(h.http.requests.last?.url.absoluteString, "https://api.fanbox.cc/post.listHome?limit=10")
        let cursor = try XCTUnwrap(page.nextCursor)
        XCTAssertFalse(cursor.contains("api.fanbox.cc"), "cursor is opaque")

        h.http.stub("post.listHome", json: FanboxFixtures.envelope(#"{"items":[],"nextUrl":null}"#))
        let second = try await h.source.homeTimeline(account: FanboxTestHarness.fan, cursor: cursor)
        XCTAssertEqual(h.http.requests.last?.url.absoluteString,
                       "https://api.fanbox.cc/post.listHome?limit=10&maxPublishedDatetime=2026-08-30%2009%3A00%3A00&maxId=4999")
        XCTAssertNil(second.nextCursor)
        XCTAssertTrue(second.items.isEmpty)

        let call = try XCTUnwrap(h.spy.calls.first { $0.key == "post.listHome" })
        XCTAssertTrue(call.known["body"]?.contains("nextUrl") ?? false)
        XCTAssertTrue(call.known["body.items[]"]?.isSuperset(of: ["id", "title", "feeRequired", "isRestricted", "cover"]) ?? false)
        XCTAssertFalse(call.known["body.items[]"]?.contains("brandNewField") ?? true, "unknown field is reported, not known")
        XCTAssertEqual(try JSONValue.parse(call.raw)["body"]?["items"]?[0]?["brandNewField"]?["nested"], .bool(true))

        do {
            _ = try await h.source.homeTimeline(account: FanboxTestHarness.fan, cursor: FanboxCursor.offset(3).encoded)
            XCTFail("wrong cursor kind must be rejected")
        } catch let error as RemoteError {
            guard case .invalidRequest = error else { return XCTFail("\(error)") }
        }
    }

    func testCreatorPostsUsePaginateCreatorPages() async throws {
        let h = FanboxTestHarness()
        let page1 = "https://api.fanbox.cc/post.listCreator?creatorId=alice&firstPublishedDatetime=2026-09-10T10%3A00%3A00%2B09%3A00&firstId=6001&sort=newest&limit=10"
        let page2 = "https://api.fanbox.cc/post.listCreator?creatorId=alice&firstPublishedDatetime=2026-08-01T10%3A00%3A00%2B09%3A00&firstId=5000&sort=newest&limit=10"
        h.http.stub("post.paginateCreator", json: FanboxFixtures.envelope(#"{"pageUrls":["\#(page1)","\#(page2)"]}"#))
        h.http.stub("post.listCreator", json: FanboxFixtures.envelope(#"""
        {"posts":[{"id":"1","isPinned":true,"creatorId":"alice","publishedDatetime":"2020-01-01T00:00:00+09:00"},
                  {"id":"6001","creatorId":"alice","publishedDatetime":"2026-09-10T10:00:00+09:00"}]}
        """#))
        h.http.stub("post.listCreator", json: FanboxFixtures.envelope(#"[{"id":"5000","creatorId":"alice"}]"#))

        let first = try await h.source.creatorPosts(creatorID: "alice", account: FanboxTestHarness.fan, cursor: nil)
        XCTAssertEqual(first.items.map(\.id), ["6001", "1"], "pinned post moved behind newer posts")
        XCTAssertEqual(h.http.requests(for: "post.paginateCreator").first?.url.absoluteString,
                       "https://api.fanbox.cc/post.paginateCreator?creatorId=alice")
        XCTAssertEqual(h.http.requests(for: "post.listCreator").first?.url.absoluteString, page1)

        let second = try await h.source.creatorPosts(creatorID: "alice", account: FanboxTestHarness.fan, cursor: first.nextCursor)
        XCTAssertEqual(second.items.map(\.id), ["5000"], "legacy bare array still decodes")
        XCTAssertEqual(h.http.requests(for: "post.listCreator").last?.url.absoluteString, page2)
        XCTAssertEqual(h.http.requests(for: "post.paginateCreator").count, 1, "page list reused from cache for 'load more'")
        XCTAssertNil(second.nextCursor)

        _ = try await h.source.creatorPosts(creatorID: "alice", account: FanboxTestHarness.fan, cursor: nil)
        XCTAssertEqual(h.http.requests(for: "post.paginateCreator").count, 2, "first page always refetches the page list")

        let empty = FanboxTestHarness()
        empty.http.stub("post.paginateCreator", json: FanboxFixtures.envelope(#"{"pageUrls":[]}"#))
        let none = try await empty.source.creatorPosts(creatorID: "nobody", account: FanboxTestHarness.fan, cursor: nil)
        XCTAssertTrue(none.items.isEmpty)
        XCTAssertTrue(empty.http.requests(for: "post.listCreator").isEmpty, "no listCreator call for an empty page list")
    }

    func testPostDetailCallsInspectorWithKnownFields() async throws {
        let h = FanboxTestHarness()
        h.http.stub("post.info", json: FanboxFixtures.envelope(FanboxFixtures.articlePost))
        let detail = try await h.source.post(id: "6001", account: FanboxTestHarness.fan)
        XCTAssertEqual(detail.summary.id, "6001")
        XCTAssertEqual(h.http.requests.last?.url.absoluteString, "https://api.fanbox.cc/post.info?postId=6001")
        let call = try XCTUnwrap(h.spy.calls.first { $0.key == "post.info" })
        XCTAssertEqual(call.known["body"], ["post"])
        XCTAssertTrue(call.known["body.post"]?.contains("title") ?? false)
        XCTAssertFalse(call.known["body.post"]?.contains("someNewFlag") ?? true)
        XCTAssertTrue(call.known["body.post.body.imageMap{}"]?.contains("originalUrl") ?? false)
        XCTAssertFalse(call.known["body.post.body.imageMap{}"]?.contains("newImageField") ?? true)
    }

    func testCommentsCursorAndAddComment() async throws {
        let h = FanboxTestHarness()
        h.http.stub("post.getComments", json: FanboxFixtures.envelope(FanboxFixtures.comments))
        let page = try await h.source.comments(postID: "6001", account: FanboxTestHarness.fan, cursor: nil)
        XCTAssertEqual(page.items.count, 2)
        _ = try await h.source.comments(postID: "6001", account: FanboxTestHarness.fan, cursor: page.nextCursor)
        XCTAssertEqual(h.http.requests(for: "post.getComments").last?.url.absoluteString,
                       "https://api.fanbox.cc/post.getComments?postId=6001&offset=20&limit=20")

        // addComment: undocumented response ⇒ the posted comment is found by re-reading the first page.
        try await h.saveCredential(accountID: "acc-fan", csrf: "tok")
        h.http.stub("post.addComment", json: #"{"body":null}"#)
        let posted = try await RequestContext.$priority.withValue(.interactiveWrite) {
            try await h.source.addComment(postID: "6001", body: "返信の返信", parentCommentID: "c2", rootCommentID: "c1", account: FanboxTestHarness.fan)
        }
        // The fixture's own reply is dated 2026-09-10, far before "now", so it is not accepted as the new comment.
        XCTAssertTrue(posted.id.hasPrefix("pending:"))
        XCTAssertEqual(posted.parentCommentID, "c2")
        XCTAssertEqual(posted.rootCommentID, "c1")
        XCTAssertTrue(posted.isOwn)
        let addRequest = try XCTUnwrap(h.http.requests(for: "post.addComment").first)
        XCTAssertEqual(addRequest.priority, .interactiveWrite)
        XCTAssertTrue(addRequest.requiresCSRF)
        XCTAssertEqual(try JSONValue.parse(addRequest.body ?? Data())["parentCommentId"], "c2")

        // When FANBOX returns the comment, it is used directly.
        h.http.stub("post.addComment", json: #"{"body":{"id":"c9","parentCommentId":"0","rootCommentId":"0","body":"新規","createdDatetime":"2026-09-24T10:00:00+09:00","user":{"userId":"99","name":"Me"}}}"#)
        let direct = try await h.source.addComment(postID: "6001", body: "新規", parentCommentID: nil, rootCommentID: nil, account: FanboxTestHarness.fan)
        XCTAssertEqual(direct.id, "c9")
        XCTAssertTrue(direct.isOwn)

        h.http.stub("post.deleteComment", json: #"{"body":null}"#)
        try await h.source.deleteComment(commentID: "c9", postID: "6001", account: FanboxTestHarness.fan)
        XCTAssertEqual(try JSONValue.parse(h.http.requests(for: "post.deleteComment").last?.body ?? Data()), ["commentId": "c9"])
    }

    func testNotificationsPagingKeepsUnread() async throws {
        let h = FanboxTestHarness()
        h.http.stub("bell.list", json: FanboxFixtures.envelope(FanboxFixtures.bells))
        let page = try await h.source.notifications(account: FanboxTestHarness.fan, cursor: nil)
        XCTAssertEqual(page.items.count, 6)
        XCTAssertEqual(h.http.requests.last?.url.absoluteString,
                       "https://api.fanbox.cc/bell.list?page=1&skipConvertUnreadNotification=1&commentOnly=0")
        _ = try await h.source.notifications(account: FanboxTestHarness.fan, cursor: page.nextCursor)
        XCTAssertEqual(h.http.requests.last?.url.absoluteString,
                       "https://api.fanbox.cc/bell.list?page=2&skipConvertUnreadNotification=1&commentOnly=0")
    }

    func testListsNewslettersPaymentsAndPlans() async throws {
        let h = FanboxTestHarness()
        h.http.stub("newsletter.list", json: FanboxFixtures.envelope(FanboxFixtures.newsletters))
        h.http.stub("payment.listPaid", json: FanboxFixtures.envelope(FanboxFixtures.payments))
        h.http.stub("plan.listSupporting", json: FanboxFixtures.envelope(FanboxFixtures.supportingPlansWrapped))
        h.http.stub("plan.listCreator", json: FanboxFixtures.envelope(FanboxFixtures.supportingPlansBare))
        h.http.stub("creator.listFollowing", json: FanboxFixtures.envelope(#"{"creators":[\#(FanboxFixtures.creator),{"broken":true}]}"#))

        let letters = try await h.source.newsletters(account: FanboxTestHarness.fan)
        XCTAssertEqual(letters.map(\.id), ["n2", "n1"], "newest first")
        let one = try await h.source.newsletter(id: "n1", account: FanboxTestHarness.fan)
        XCTAssertEqual(one.body, "いつも応援ありがとうございます")
        do {
            _ = try await h.source.newsletter(id: "missing", account: FanboxTestHarness.fan)
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? RemoteError, .notFound)
        }
        let paid = try await h.source.paidRecords(account: FanboxTestHarness.fan)
        XCTAssertEqual(paid.count, 2)
        let supports = try await h.source.supportingPlans(account: FanboxTestHarness.fan)
        XCTAssertEqual(supports.map(\.creatorID), ["alice", "bob"])
        let plans = try await h.source.creatorPlans(creatorID: "alice", account: FanboxTestHarness.fan)
        XCTAssertEqual(plans.first?.planID, "100")
        XCTAssertEqual(h.http.requests(for: "plan.listCreator").last?.url.absoluteString, "https://api.fanbox.cc/plan.listCreator?creatorId=alice")
        let following = try await h.source.followingCreators(account: FanboxTestHarness.fan)
        XCTAssertEqual(following.map(\.creatorID), ["alice"])
    }

    // MARK: Session / CSRF

    func testCurrentUserReadsMetadataStoresCSRFAndRedactsInspectorCopy() async throws {
        let h = FanboxTestHarness()
        try await h.saveCredential(accountID: "acc-creator", csrf: nil)
        h.http.stub("www.metadata", data: Data(FanboxFixtures.metadataHTML.utf8), headers: ["Content-Type": "text/html"])
        let user = try await h.source.currentUser(account: FanboxTestHarness.creator)
        XCTAssertEqual(user.pixivUserID, "11")
        XCTAssertEqual(user.creatorID, "alice")
        let stored = await h.credentials.credential(for: "acc-creator")
        XCTAssertEqual(stored?.csrfToken, "tok-fresh-123")

        let call = try XCTUnwrap(h.spy.calls.first { $0.key == "www.metadata" })
        let raw = String(data: call.raw, encoding: .utf8) ?? ""
        XCTAssertFalse(raw.contains("tok-fresh-123"), "CSRF token never reaches the inspector")
        XCTAssertTrue(raw.contains("<REDACTED>"))
        XCTAssertTrue(call.known["body.context.user"]?.contains("creatorId") ?? false)

        let loggedOut = FanboxTestHarness()
        loggedOut.http.stub("www.metadata", data: Data(FanboxFixtures.loggedOutMetadataHTML.utf8))
        do {
            _ = try await loggedOut.source.currentUser(account: FanboxTestHarness.fan)
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? RemoteError, .unauthorized)
        }
    }

    func testCSRFRefreshRetriesRejectedWriteOnce() async throws {
        let h = FanboxTestHarness()
        try await h.saveCredential(accountID: "acc-fan", csrf: "stale")
        h.http.stub("post.likePost", status: 403, json: #"{"error":"general_error"}"#)
        h.http.stub("post.likePost", json: #"{"body":null}"#)
        h.http.stub("www.metadata", data: Data(FanboxFixtures.metadataHTML.utf8))
        try await h.source.setLike(postID: "5001", liked: true, account: FanboxTestHarness.fan)
        XCTAssertEqual(h.http.requests(for: "post.likePost").count, 2)
        XCTAssertEqual(h.http.requests(for: "www.metadata").count, 1)
        let stored = await h.credentials.credential(for: "acc-fan")
        XCTAssertEqual(stored?.csrfToken, "tok-fresh-123")

        // A token that does not change is not retried again (no loops).
        let same = FanboxTestHarness()
        try await same.saveCredential(accountID: "acc-fan", csrf: "tok-fresh-123")
        same.http.stub("post.likePost", status: 403, json: #"{"error":"general_error"}"#)
        same.http.stub("www.metadata", data: Data(FanboxFixtures.metadataHTML.utf8))
        do {
            try await same.source.setLike(postID: "5001", liked: true, account: FanboxTestHarness.fan)
            XCTFail("expected forbidden")
        } catch {
            XCTAssertEqual(error as? RemoteError, .forbidden)
        }
        XCTAssertEqual(same.http.requests(for: "post.likePost").count, 1)
    }

    func testMissingCSRFTokenIsFetchedBeforeWrite() async throws {
        let h = FanboxTestHarness()
        try await h.saveCredential(accountID: "acc-fan", csrf: nil)
        h.http.stub("www.metadata", data: Data(FanboxFixtures.metadataHTML.utf8))
        h.http.stub("follow.create", json: #"{"body":null}"#)
        try await h.source.setFollow(creatorUserID: "11", follow: true, account: FanboxTestHarness.fan)
        XCTAssertEqual(h.http.requests.map(\.endpointKey), ["www.metadata", "follow.create"])
    }

    // MARK: Errors

    func testErrorMappingThroughClient() async throws {
        let h = FanboxTestHarness()
        h.http.stub("post.listHome", status: 401, json: #"{"error":"general_error"}"#)
        h.http.stub("post.listSupporting", status: 429, json: "", headers: ["Retry-After": "90"])
        h.http.stub("creator.get", json: #"{"error":"general_error"}"#)
        h.http.stub("post.info", status: 403, data: Data("<html>ブロックされました</html>".utf8),
                    headers: ["Content-Type": "text/html", "Server": "cloudflare"])
        h.http.stub("newsletter.list", json: FanboxFixtures.envelope(#"{"unexpected":{}}"#))

        await assertThrows(.unauthorized) { _ = try await h.source.homeTimeline(account: FanboxTestHarness.fan, cursor: nil) }
        await assertThrows(.rateLimited(retryAfter: 90)) { _ = try await h.source.supportingTimeline(account: FanboxTestHarness.fan, cursor: nil) }
        // Updated for the transport fix: a Cloudflare HTML 403 is an edge block, not a FANBOX refusal (docs/API.md §1.6).
        await assertThrows(.edgeBlocked(retryAfter: nil)) { _ = try await h.source.post(id: "1", account: FanboxTestHarness.fan) }
        do {
            _ = try await h.source.creator(id: "x", account: FanboxTestHarness.fan)
            XCTFail("expected error")
        } catch let error as RemoteError {
            guard case .invalidRequest = error else { return XCTFail("\(error)") }
        }
        do {
            _ = try await h.source.newsletters(account: FanboxTestHarness.fan)
            XCTFail("expected decoding error")
        } catch let error as RemoteError {
            guard case .decoding(let endpoint, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(endpoint, "newsletter.list")
        }
        XCTAssertNotNil(h.spy.calls.first { $0.key == "newsletter.list" }, "schema changes are still reported to the inspector")
    }

    func testUnsupportedOperationsFallBackToWeb() async throws {
        let h = FanboxTestHarness()
        await assertUnsupported { try await h.source.setLike(postID: "1", liked: false, account: FanboxTestHarness.fan) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("x.png")
        await assertUnsupported { _ = try await h.source.uploadImage(fileURL: file, account: FanboxTestHarness.creator, progress: { _ in }) }
        await assertUnsupported { _ = try await h.source.uploadFile(fileURL: file, account: FanboxTestHarness.creator, progress: { _ in }) }
        let imageDraft = RemotePostDraft(title: "t", feeRequired: 0, planID: nil, tags: [], hasAdultContent: false,
                                         blocks: [RemoteDraftBlock(kind: .image, text: "", mediaID: "local", url: nil, embedProvider: nil, embedContentID: nil)],
                                         publish: false)
        await assertUnsupported { _ = try await h.source.createPost(imageDraft, account: FanboxTestHarness.creator) }
        XCTAssertTrue(h.http.requests.isEmpty, "nothing is created on FANBOX when the draft needs uploads")

        let disabled = FanboxRemoteDataSource(api: h.api, pageCache: FanboxPageURLCache(), nativePostWritesEnabled: false)
        await assertUnsupported { _ = try await disabled.createPost(imageDraft, account: FanboxTestHarness.creator) }
        do {
            _ = try await h.source.managedPosts(account: FanboxTestHarness.fan, cursor: nil)
            XCTFail("fan account has no creator page")
        } catch let error as RemoteError {
            guard case .invalidRequest = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: Creator side

    func testCreatePostSendsCreateThenMultipartUpdate() async throws {
        let h = FanboxTestHarness()
        try await h.saveCredential(accountID: "acc-creator", csrf: "tok-abc")
        h.http.stub("post.create", json: #"{"body":{"postId":"9001"}}"#)
        h.http.stub("post.update", json: #"{"body":{"id":"9001","status":"draft"}}"#)
        let draft = RemotePostDraft(title: "新しい記事", feeRequired: 0, planID: nil, tags: [], hasAdultContent: false,
                                    blocks: [RemoteDraftBlock(kind: .text, text: "本文", mediaID: nil, url: nil, embedProvider: nil, embedContentID: nil)],
                                    publish: false)
        let id = try await RequestContext.$priority.withValue(.interactiveWrite) {
            try await h.source.createPost(draft, account: FanboxTestHarness.creator)
        }
        XCTAssertEqual(id, "9001")
        XCTAssertEqual(h.http.requests.map(\.endpointKey), ["post.create", "post.update"])
        let create = h.http.requests[0]
        XCTAssertEqual(try JSONValue.parse(create.body ?? Data()), ["type": "article"])
        XCTAssertTrue(create.requiresCSRF)
        let update = h.http.requests[1]
        XCTAssertEqual(update.method, "POST")
        XCTAssertEqual(update.priority, .interactiveWrite)
        XCTAssertTrue(update.headers["Content-Type"]?.hasPrefix("multipart/form-data; boundary=") ?? false)
        // Updated for the transport fix: a field-only form is sent from memory (`send`), never via a temp file.
        XCTAssertTrue(h.http.uploadBodies.isEmpty, "post.update is not uploaded from a file")
        let body = String(data: update.body ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("name=\"tt\"\r\n\r\ntok-abc\r\n"))
        XCTAssertTrue(body.contains("name=\"postId\"\r\n\r\n9001\r\n"))
        XCTAssertTrue(body.contains(#"[{"text":"本文","type":"p"}]"#))
        XCTAssertTrue(body.contains("name=\"status\"\r\n\r\ndraft\r\n"))
    }

    func testUpdatePostRoundTripsExistingMediaOnly() async throws {
        let h = FanboxTestHarness()
        try await h.saveCredential(accountID: "acc-creator", csrf: "tok-abc")
        h.http.stub("post.getEditable", json: FanboxFixtures.envelope(FanboxFixtures.editablePost))
        h.http.stub("post.update", json: #"{"body":{"id":"m2"}}"#)
        let editable = try await h.source.editablePost(id: "m2", account: FanboxTestHarness.creator)
        let blocks = editable.blocks.map { b -> RemoteDraftBlock in
            switch b.kind {
            case .image: return RemoteDraftBlock(kind: .image, text: "", mediaID: b.mediaID, url: nil, embedProvider: nil, embedContentID: nil)
            case .url: return RemoteDraftBlock(kind: .url, text: "", mediaID: b.mediaID, url: b.url, embedProvider: nil, embedContentID: nil)
            default: return RemoteDraftBlock(kind: .text, text: b.text, mediaID: nil, url: nil, embedProvider: nil, embedContentID: nil)
            }
        }
        let draft = RemotePostDraft(title: "更新", feeRequired: 500, planID: nil, tags: editable.tags, hasAdultContent: false, blocks: blocks, publish: true)
        try await h.source.updatePost(id: "m2", draft, account: FanboxTestHarness.creator)
        let body = String(data: h.http.requests(for: "post.update").last?.body ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains(#"[{"text":"本文","type":"p"},{"imageId":"im1","type":"image"},{"type":"url_embed","urlEmbedId":"ue1"}]"#))
        XCTAssertTrue(body.contains("name=\"status\"\r\n\r\npublished\r\n"))

        var withNewImage = draft
        withNewImage.blocks.append(RemoteDraftBlock(kind: .image, text: "", mediaID: "new-upload", url: nil, embedProvider: nil, embedContentID: nil))
        let updatesBefore = h.http.requests(for: "post.update").count
        await assertUnsupported { try await h.source.updatePost(id: "m2", withNewImage, account: FanboxTestHarness.creator) }
        XCTAssertEqual(h.http.requests(for: "post.update").count, updatesBefore, "no update is sent for unsupported content")
    }

    func testManagedPostsFansDashboardAndCreatorComments() async throws {
        let h = FanboxTestHarness()
        let month = FanboxDateParser.monthKey(.now)
        h.http.stub("post.listManaged", json: FanboxFixtures.envelope(FanboxFixtures.managedPosts.replacingOccurrences(of: "MONTH", with: month)))
        h.http.stub("creator.get", json: FanboxFixtures.envelope(FanboxFixtures.creator))
        h.http.stub("relationship.listFans", json: FanboxFixtures.envelope(FanboxFixtures.fans))
        h.http.stub("plan.listCreator", json: FanboxFixtures.envelope(#"{"plans":[{"id":"100","title":"応援プラン","fee":500,"creatorId":"alice"}]}"#))
        h.http.stub("relationship.listFilterOptions", json: FanboxFixtures.envelope(FanboxFixtures.filterOptions))
        h.http.stub("legacy.manage.pledge.monthly", status: 500, json: #"{"error":"general_error"}"#)

        let managed = try await h.source.managedPosts(account: FanboxTestHarness.creator, cursor: nil)
        XCTAssertEqual(managed.items.map(\.id), ["m2", "m1", "m3"])
        XCTAssertEqual(managed.items.first?.creatorName, "Alice")
        XCTAssertNil(managed.nextCursor)

        let fans = try await h.source.fans(account: FanboxTestHarness.creator, cursor: nil)
        XCTAssertEqual(fans.items.map(\.userID), ["51", "50", "52"], "newest supporter first")
        XCTAssertEqual(fans.items.first { $0.userID == "50" }?.planTitle, "応援プラン")
        XCTAssertEqual(h.http.requests(for: "relationship.listFans").last?.url.absoluteString,
                       "https://api.fanbox.cc/relationship.listFans?status=supporter")

        let dashboard = try await h.source.creatorDashboard(account: FanboxTestHarness.creator)
        XCTAssertEqual(dashboard.month, month)
        XCTAssertEqual(dashboard.supporterCount, 12)
        XCTAssertNil(dashboard.earnings, "failed source ⇒ unavailable, never guessed")
        XCTAssertEqual(dashboard.postCount, 1)
        XCTAssertNil(dashboard.commentCount, "no reliable source")
        XCTAssertEqual(h.http.requests(for: "legacy.manage.pledge.monthly").last?.url.absoluteString,
                       "https://api.fanbox.cc/legacy/manage/pledge/monthly?month=\(month)")

        h.http.stub("post.paginateCreator", json: FanboxFixtures.envelope(#"{"pageUrls":["https://api.fanbox.cc/post.listCreator?creatorId=alice&limit=10"]}"#))
        h.http.stub("post.listCreator", json: FanboxFixtures.envelope(#"{"posts":[{"id":"6001","creatorId":"alice","commentCount":2},{"id":"6000","creatorId":"alice","commentCount":0}]}"#))
        h.http.stub("post.getComments", json: FanboxFixtures.envelope(FanboxFixtures.comments))
        let comments = try await h.source.creatorComments(account: FanboxTestHarness.creator, cursor: nil)
        XCTAssertEqual(comments.items.map(\.id), ["c4", "c1"])
        XCTAssertEqual(h.http.requests(for: "post.getComments").count, 1, "posts without comments are skipped")
        XCTAssertNil(comments.nextCursor)
    }

    func testExtraReadsAndCredentialDiscovery() async throws {
        let h = FanboxTestHarness()
        h.http.stub("post.get", json: FanboxFixtures.envelope(#"{"post":{"id":"5001","title":"t","creatorId":"alice","isRestricted":false,"cover":{"url":"https://pixiv.pximg.net/c.jpeg"}}}"#))
        let meta = try await h.source.postMetadata(id: "5001", account: FanboxTestHarness.fan)
        XCTAssertEqual(meta.coverImageURL, "https://pixiv.pximg.net/c.jpeg")
        XCTAssertFalse(meta.isRestricted, "missing body on post.get is not a restriction")

        h.http.stub("post.listTagged", json: FanboxFixtures.envelope(#"{"count":1,"items":[{"id":"1","creatorId":"alice"}],"nextUrl":"https://api.fanbox.cc/post.listTagged?tag=x&creatorId=alice&page=1"}"#))
        let tagged = try await h.source.taggedPosts(tag: "x", creatorID: "alice", account: FanboxTestHarness.fan, cursor: nil)
        XCTAssertEqual(tagged.items.map(\.id), ["1"])
        XCTAssertEqual(h.http.requests.last?.url.absoluteString, "https://api.fanbox.cc/post.listTagged?tag=x&creatorId=alice&page=0")
        _ = try await h.source.taggedPosts(tag: "x", creatorID: "alice", account: FanboxTestHarness.fan, cursor: tagged.nextCursor)
        XCTAssertEqual(h.http.requests.last?.url.absoluteString, "https://api.fanbox.cc/post.listTagged?tag=x&creatorId=alice&page=1")

        h.http.stub("creator.search", json: FanboxFixtures.envelope(#"{"creators":[\#(FanboxFixtures.creator)],"count":51,"nextPage":1}"#))
        let search = try await h.source.searchCreators(query: "alice", account: FanboxTestHarness.fan, cursor: nil)
        XCTAssertEqual(search.items.first?.creatorID, "alice")
        XCTAssertEqual(FanboxCursor(encoded: search.nextCursor), .page(1))

        h.http.stub("www.metadata", data: Data(FanboxFixtures.metadataHTML.utf8))
        let summary = try await h.source.sessionSummary(account: FanboxTestHarness.creator)
        XCTAssertTrue(summary.isCreator)
        XCTAssertEqual(summary.hasUnpaidPayments, false)
        XCTAssertEqual(summary.planCount, 2)

        // Without explicit wiring, the API client uses the transport's own credential store.
        let store = InMemoryCredentialStore()
        let transport = AccountHTTPClient(credentials: store, scheduler: NetworkScheduler(policy: NetworkPolicyStore()), recorder: ResearchRecorder())
        let api = FanboxAPIClient(http: transport, inspector: SchemaInspector())
        XCTAssertTrue((api.credentials as? InMemoryCredentialStore) === store)
    }

    func testDashboardThrowsWhenEverySourceFails() async {
        let h = FanboxTestHarness()
        h.http.stub("relationship.listFilterOptions", status: 401, json: "{}")
        h.http.stub("legacy.manage.pledge.monthly", status: 401, json: "{}")
        h.http.stub("post.listManaged", status: 401, json: "{}")
        await assertThrows(.unauthorized) { _ = try await h.source.creatorDashboard(account: FanboxTestHarness.creator) }
    }

    // MARK: Helpers

    private func assertThrows(_ expected: RemoteError, file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? RemoteError, expected, file: file, line: line)
        }
    }

    private func assertUnsupported(file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected unsupported", file: file, line: line)
        } catch {
            guard case .unsupported? = error as? RemoteError else { return XCTFail("\(error)", file: file, line: line) }
        }
    }
}
