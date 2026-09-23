import XCTest
@testable import FANBOXClient

/// DTO → Remote* mapping per endpoint group (pure `FanboxAdapter` functions, hand-written fixtures).
final class FanboxMappingTests: XCTestCase {
    // MARK: Timeline

    func testTimelineMapping() throws {
        let body = try FanboxFixtures.decodeBody(FanboxPostListBody.self, FanboxFixtures.homeTimeline)
        XCTAssertEqual(body.items.count, 3)
        let items = FanboxAdapter.postSummaries(body.items)
        XCTAssertEqual(items.map(\.id), ["5001", "5000"], "item without id is dropped")

        let first = items[0]
        XCTAssertEqual(first.creatorID, "alice")
        XCTAssertEqual(first.creatorName, "Alice")
        XCTAssertEqual(first.pixivUserID, "11")
        XCTAssertEqual(first.feeRequired, 500)
        XCTAssertEqual(first.likeCount, 12)
        XCTAssertEqual(first.commentCount, 3)
        XCTAssertTrue(first.isLiked)
        XCTAssertFalse(first.isRestricted)
        XCTAssertEqual(first.type, .unknown, "list items carry no type")
        XCTAssertEqual(first.tags, ["illust", "R"])
        XCTAssertEqual(first.excerpt, "本文冒頭")
        XCTAssertEqual(first.coverImageURL, "https://pixiv.pximg.net/c/1200x630_90_a2_g5/fanbox/public/images/post/5001/cover/x.jpeg")
        XCTAssertEqual(first.publishedAt, FanboxFixtures.date("2026-09-01T12:34:56+09:00"))
        XCTAssertEqual(first.updatedAt.timeIntervalSince(FanboxFixtures.date("2026-09-02T08:00:00+09:00")), 0.123, accuracy: 0.001)

        let second = items[1]
        XCTAssertEqual(second.feeRequired, 1000, "fee sent as a string")
        XCTAssertEqual(second.creatorName, "bob", "falls back to the creator id without user")
        XCTAssertTrue(second.isRestricted)
        XCTAssertNil(second.coverImageURL)
        XCTAssertEqual(second.updatedAt, second.publishedAt)
    }

    func testPinnedPostsMovedToEndAndDuplicatesDropped() throws {
        let body = try FanboxFixtures.decodeBody(FanboxCreatorPostListBody.self, #"""
        {"posts":[{"id":"1","isPinned":true,"publishedDatetime":"2020-01-01T00:00:00+09:00"},
                  {"id":"3","publishedDatetime":"2026-09-03T00:00:00+09:00"},{"id":"2","publishedDatetime":"2026-09-02T00:00:00+09:00"},
                  {"id":"3"}]}
        """#)
        let items = FanboxAdapter.postSummaries(body.items, fallbackCreatorID: "alice")
        XCTAssertEqual(items.map(\.id), ["3", "2", "1"])
        XCTAssertEqual(items.first?.creatorID, "alice", "fallback creator id")
    }

    // MARK: Post detail

    func testArticleMappingWithMaps() throws {
        let body = try FanboxFixtures.decodeBody(FanboxPostInfoBody.self, FanboxFixtures.articlePost)
        let detail = try XCTUnwrap(FanboxAdapter.postDetail(body.post))
        XCTAssertEqual(detail.summary.type, .article)
        XCTAssertEqual(detail.summary.coverImageURL, "https://pixiv.pximg.net/c/1200x630_90_a2_g5/fanbox/public/images/post/6001/cover/c.jpeg")
        XCTAssertEqual(detail.nextPostID, "6002")
        XCTAssertNil(detail.prevPostID)
        XCTAssertFalse(detail.summary.isRestricted)
        XCTAssertEqual(detail.blocks.map(\.kind),
                       [.header, .paragraph, .paragraph, .image, .audio, .file, .embed, .url, .url, .url, .unknown, .unknown])

        let b = detail.blocks
        XCTAssertEqual(b[0].text, "見出し")
        XCTAssertEqual(b[1].styles, [RemoteTextStyle(type: "bold", offset: 0, length: 2, size: nil),
                                     RemoteTextStyle(type: "link:https://example.com/", offset: 3, length: 3, size: nil)])
        XCTAssertEqual(b[2].text, "", "empty paragraphs are kept as spacing")

        let image = b[3]
        XCTAssertEqual(image.mediaID, "img1")
        XCTAssertNil(image.thumbnailURL, "FANBOX has no smaller feed thumbnail")
        XCTAssertEqual(image.displayURL, "https://downloads.fanbox.cc/images/post/6001/w/1200/img1.jpeg")
        XCTAssertEqual(image.originalURL, "https://downloads.fanbox.cc/images/post/6001/img1.png")
        XCTAssertEqual(image.width, 1200)
        XCTAssertEqual(image.height, 800)
        XCTAssertEqual(image.fileExtension, "png")

        XCTAssertEqual(b[4].fileName, "theme.mp3")
        XCTAssertEqual(b[4].fileSize, 123456)
        XCTAssertEqual(b[4].url, "https://downloads.fanbox.cc/files/post/6001/f1.mp3")
        XCTAssertEqual(b[5].fileName, "archive.zip")
        XCTAssertEqual(b[5].fileSize, 999)

        XCTAssertEqual(b[6].embedProvider, "youtube")
        XCTAssertEqual(b[6].embedContentID, "abc123", "videoId wins over contentId")
        XCTAssertEqual(b[6].url, "https://www.youtube.com/watch?v=abc123")

        XCTAssertEqual(b[7].url, "https://booth.pm/items/1")
        XCTAssertEqual(b[7].title, "booth.pm")
        XCTAssertEqual(b[8].url, "https://www.youtube.com/watch?v=zzz", "link extracted from untrusted html.card")
        XCTAssertEqual(b[8].embedProvider, "html.card")
        XCTAssertEqual(b[9].embedProvider, "fanbox.post")
        XCTAssertEqual(b[9].embedContentID, "5555")
        XCTAssertEqual(b[9].url, "https://www.fanbox.cc/@alice/posts/5555")
        XCTAssertEqual(b[9].title, "関連")
        XCTAssertEqual(b[10].mediaID, "missing", "unmatched map id ⇒ placeholder, not a failure")
        XCTAssertEqual(b[11].text, "未知ブロック")

        XCTAssertEqual(detail.plainText, "見出し\n太字とリンク\n")
        XCTAssertEqual(detail.summary.excerpt, String(detail.plainText.prefix(120)))
    }

    func testTextImageFileVideoEntryAndRestrictedPosts() throws {
        let legacy = try XCTUnwrap(FanboxAdapter.postDetail(try FanboxFixtures.decodeBody(FanboxPostInfoBody.self, FanboxFixtures.legacyTextPost).post))
        XCTAssertEqual(legacy.summary.type, .text)
        XCTAssertEqual(legacy.blocks.map(\.text), ["一行目\n二行目", "段落2"])
        XCTAssertEqual(legacy.plainText, "一行目\n二行目\n段落2")

        let image = try XCTUnwrap(FanboxAdapter.postDetail(try FanboxFixtures.decodeBody(FanboxPostInfoBody.self, FanboxFixtures.imagePost).post))
        XCTAssertEqual(image.blocks.map(\.kind), [.image, .image, .paragraph], "images first, then text; garbage element skipped")
        XCTAssertEqual(image.blocks[1].originalURL, "https://downloads.fanbox.cc/images/post/8/i2.gif")
        XCTAssertEqual(image.blocks[2].text, "説明文")

        let file = try XCTUnwrap(FanboxAdapter.postDetail(try FanboxFixtures.decodeBody(FanboxPostInfoBody.self, FanboxFixtures.filePost).post))
        XCTAssertEqual(file.blocks.map(\.kind), [.video, .audio, .file, .video, .audio])
        XCTAssertEqual(file.blocks[0].fileName, "clip.MP4")
        XCTAssertEqual(file.blocks[2].fileExtension, "pdf")

        let video = try XCTUnwrap(FanboxAdapter.postDetail(try FanboxFixtures.decodeBody(FanboxPostInfoBody.self, FanboxFixtures.videoPost).post))
        XCTAssertEqual(video.blocks.first?.kind, .embed)
        XCTAssertEqual(video.blocks.first?.embedProvider, "vimeo")
        XCTAssertEqual(video.blocks.first?.embedContentID, "42", "numeric video id ⇒ string")
        XCTAssertEqual(video.blocks.first?.url, "https://vimeo.com/42")
        XCTAssertEqual(video.blocks.last?.text, "見てね")

        let restricted = try XCTUnwrap(FanboxAdapter.postDetail(try FanboxFixtures.decodeBody(FanboxPostInfoBody.self, FanboxFixtures.restrictedPost).post))
        XCTAssertTrue(restricted.summary.isRestricted)
        XCTAssertTrue(restricted.blocks.isEmpty)
        XCTAssertEqual(restricted.summary.excerpt, "ちら見せ")
        XCTAssertEqual(restricted.summary.feeRequired, 1000)

        let entry = try XCTUnwrap(FanboxAdapter.postDetail(try FanboxFixtures.decodeBody(FanboxPostInfoBody.self, FanboxFixtures.entryPost).post))
        XCTAssertEqual(entry.blocks.map(\.kind), [.paragraph, .image, .paragraph])
        XCTAssertEqual(entry.blocks[0].text, "こんにちは&")
        XCTAssertEqual(entry.blocks[1].displayURL, "https://downloads.fanbox.cc/images/entry/1/w/1200/o.jpeg")
        XCTAssertEqual(entry.blocks[1].originalURL, "https://downloads.fanbox.cc/images/entry/1/o.png")
        XCTAssertEqual(entry.blocks[2].text, "end")
    }

    func testEmbedProviderURLs() {
        XCTAssertEqual(FanboxAdapter.embedURL(provider: "twitter", contentID: "123"), "https://x.com/i/web/status/123")
        XCTAssertEqual(FanboxAdapter.embedURL(provider: "soundcloud", contentID: "user/track"), "https://soundcloud.com/user/track")
        XCTAssertEqual(FanboxAdapter.embedURL(provider: "google_forms", contentID: "1FAIpQL"), "https://docs.google.com/forms/d/e/1FAIpQL/viewform")
        XCTAssertEqual(FanboxAdapter.embedURL(provider: "fanbox", contentID: "creator/1/post/99"), "https://www.pixiv.net/fanbox/creator/1/post/99")
        XCTAssertNil(FanboxAdapter.embedURL(provider: "myspace", contentID: "x"))
        XCTAssertEqual(FanboxAdapter.fileKind(forExtension: "OGG"), .audio)
        XCTAssertEqual(FanboxAdapter.fileKind(forExtension: "webm"), .video)
        XCTAssertEqual(FanboxAdapter.fileKind(forExtension: "avi"), .file)
        XCTAssertEqual(FanboxAdapter.fileKind(forExtension: nil), .file)
    }

    // MARK: Creator / plans / supports

    func testCreatorMapping() throws {
        let body = try FanboxFixtures.decodeBody(FanboxCreatorBody.self, FanboxFixtures.creator)
        XCTAssertEqual(body.creator.profileItems?.count, 3, "unknown profile item type still decodes")
        let creator = try XCTUnwrap(FanboxAdapter.creator(body.creator))
        XCTAssertEqual(creator.creatorID, "alice")
        XCTAssertEqual(creator.pixivUserID, "11")
        XCTAssertEqual(creator.name, "Alice")
        XCTAssertEqual(creator.iconURL, "https://pixiv.pximg.net/icon.jpeg")
        XCTAssertEqual(creator.coverImageURL, "https://pixiv.pximg.net/cover.jpeg")
        XCTAssertEqual(creator.profileText, "イラストを描いています")
        XCTAssertEqual(creator.profileLinks, ["https://twitter.com/alice", "https://alice.example"])
        XCTAssertEqual(creator.isFollowed, true)
        XCTAssertEqual(creator.isSupported, false)

        let minimal = try FanboxFixtures.decodeBody(FanboxCreatorBody.self, #"{"creatorId":"z"}"#)
        let mapped = try XCTUnwrap(FanboxAdapter.creator(minimal.creator))
        XCTAssertEqual(mapped.name, "z")
        XCTAssertNil(mapped.isFollowed, "unknown relationship stays nil")
    }

    func testPlansAndSupports() throws {
        let body = try FanboxFixtures.decodeBody(FanboxPlanListBody.self, FanboxFixtures.supportingPlansWrapped)
        let supports = body.items.compactMap(FanboxAdapter.support)
        XCTAssertEqual(supports.count, 2)
        XCTAssertEqual(supports[0].planID, "100")
        XCTAssertEqual(supports[0].creatorName, "Alice")
        XCTAssertEqual(supports[0].creatorIconURL, "https://pixiv.pximg.net/icon.jpeg")
        XCTAssertEqual(supports[0].pixivUserID, "11")
        XCTAssertEqual(supports[0].fee, 500)
        XCTAssertEqual(supports[0].paymentMethod, "PAYPAL", "raw payment method is kept")
        XCTAssertEqual(supports[0].planDescription, "ありがとう")
        XCTAssertEqual(supports[1].planID, "200")
        XCTAssertEqual(supports[1].fee, 1000)
        XCTAssertEqual(FanboxAdapter.paymentMethodFamily("gmo_card"), "card")
        XCTAssertEqual(FanboxAdapter.paymentMethodFamily("PAYPAL"), "paypal")
        XCTAssertEqual(FanboxAdapter.paymentMethodFamily("gmo_cvs"), "cvs")
        XCTAssertNil(FanboxAdapter.paymentMethodFamily("pixivcoban"))

        let creatorPlans = try FanboxFixtures.decodeBody(FanboxPlanListBody.self, #"""
        {"plans":[{"id":"2","title":"高","fee":"3000","description":"","coverImageUrl":"https://pixiv.pximg.net/plan.jpeg","hasAdultContent":true},
                  {"id":"1","title":"低","fee":100,"creatorId":"alice","paymentMethod":null}]}
        """#)
        let plans = FanboxAdapter.plans(creatorPlans.items, fallbackCreatorID: "alice")
        XCTAssertEqual(plans.map(\.planID), ["1", "2"], "sorted by fee")
        XCTAssertEqual(plans[1].creatorID, "alice", "fallback creator id")
        XCTAssertEqual(plans[1].fee, 3000)
        XCTAssertTrue(plans[1].hasAdultContent)
        XCTAssertEqual(plans[1].coverImageURL, "https://pixiv.pximg.net/plan.jpeg")
    }

    func testSupportDetailDecoding() throws {
        let body = try FanboxFixtures.decodeBody(FanboxSupportCreatorBody.self, #"""
        {"plan":{"id":"100","title":"応援","fee":500,"creatorId":"alice","paymentMethod":"card"},
         "supportStartDatetime":"2025-12-01T10:00:00+09:00","supporterCardImageUrl":"https://pixiv.pximg.net/card.jpeg",
         "supportReservations":[],
         "supportTransactions":[{"id":"t1","paidAmount":500,"targetMonth":"2026-09","transactionDatetime":"2026-09-02T10:00:00+09:00",
                                 "supporter":{"userId":"99","name":"Me"}}]}
        """#)
        XCTAssertEqual(body.plan?.paymentMethod, "card")
        XCTAssertEqual(body.supportTransactions.first?.targetMonth, "2026-09")
        XCTAssertEqual(body.supportStartDatetime, FanboxFixtures.date("2025-12-01T10:00:00+09:00"))
    }

    // MARK: Comments

    func testCommentsWithNestedReplies() throws {
        let body = try FanboxFixtures.decodeBody(FanboxCommentListBody.self, FanboxFixtures.comments)
        XCTAssertEqual(body.viewMode, "OPEN")
        let comments = FanboxAdapter.comments(body.items, postID: "6001")
        XCTAssertEqual(comments.map(\.id), ["c4", "c1"], "newest root first")
        let root = comments[1]
        XCTAssertNil(root.parentCommentID, "\"0\" ⇒ nil")
        XCTAssertNil(root.rootCommentID)
        XCTAssertEqual(root.postID, "6001")
        XCTAssertEqual(root.authorName, "Fan")
        XCTAssertEqual(root.likeCount, 2)
        XCTAssertEqual(root.replies.map(\.id), ["c2", "c3"], "replies sorted oldest first")
        XCTAssertEqual(root.replies[0].parentCommentID, "c1")
        XCTAssertEqual(root.replies[0].rootCommentID, "c1")
        XCTAssertEqual(root.replies[0].likeCount, 1)
        XCTAssertTrue(root.replies[0].isLiked)
        XCTAssertEqual(root.replies[1].parentCommentID, "c2", "reply to a reply keeps its parent")
        XCTAssertTrue(root.replies[1].isOwn)
        XCTAssertEqual(root.flattened.count, 3)
        XCTAssertEqual(comments[0].authorName, FanboxAdapter.deletedUserName)
        XCTAssertEqual(comments[0].authorUserID, "")

        let found = FanboxAdapter.findPostedComment(in: comments, body: " 返信の返信 ", parentCommentID: "c2",
                                                    notBefore: FanboxFixtures.date("2026-09-10T14:05:00+09:00"))
        XCTAssertEqual(found?.id, "c3")
        XCTAssertNil(FanboxAdapter.findPostedComment(in: comments, body: "返信の返信", parentCommentID: nil,
                                                     notBefore: FanboxFixtures.date("2026-09-10T14:05:00+09:00")))
    }

    // MARK: Bell

    func testBellTypeMapping() throws {
        XCTAssertEqual(FanboxAdapter.notificationType(rawType: "on_post_published", isRootComment: nil), .newPost)
        XCTAssertEqual(FanboxAdapter.notificationType(rawType: "post_comment", isRootComment: true), .comment)
        XCTAssertEqual(FanboxAdapter.notificationType(rawType: "post_comment", isRootComment: nil), .comment)
        XCTAssertEqual(FanboxAdapter.notificationType(rawType: "post_comment", isRootComment: false), .commentReply)
        XCTAssertEqual(FanboxAdapter.notificationType(rawType: "post_comment_like", isRootComment: nil), .other)
        XCTAssertEqual(FanboxAdapter.notificationType(rawType: "brand_new_type", isRootComment: nil), .other)

        let body = try FanboxFixtures.decodeBody(FanboxBellListBody.self, FanboxFixtures.bells)
        let items = body.items.compactMap(FanboxAdapter.notification)
        XCTAssertEqual(items.count, 6)
        XCTAssertEqual(items.map(\.type), [.newPost, .comment, .commentReply, .other, .other, .newPost])

        let newPost = items[0]
        XCTAssertEqual(newPost.remoteID, "b1")
        XCTAssertEqual(newPost.rawType, "on_post_published")
        XCTAssertEqual(newPost.postID, "5001")
        XCTAssertEqual(newPost.postTitle, "新作イラスト")
        XCTAssertEqual(newPost.creatorID, "alice")
        XCTAssertEqual(newPost.creatorName, "Alice")
        XCTAssertEqual(newPost.title, "Alice")
        XCTAssertEqual(newPost.isUnread, true)
        XCTAssertEqual(newPost.createdAt, FanboxFixtures.date("2026-09-20T10:00:00+09:00"))

        let comment = items[1]
        XCTAssertEqual(comment.postID, "5001")
        XCTAssertEqual(comment.actorName, "Fan")
        XCTAssertEqual(comment.actorIconURL, "https://pixiv.pximg.net/fan.jpeg")
        XCTAssertEqual(comment.message, "素敵です")
        XCTAssertNil(comment.commentID, "bell id is not a verified comment id")
        XCTAssertEqual(items[2].title, "Aliceさんが返信しました")
        XCTAssertEqual(items[3].rawType, "post_comment_like")
        XCTAssertEqual(items[3].title, "コメントに3件のいいね")
        XCTAssertEqual(items[4].rawType, "support_started_someday", "unknown raw type is kept")
        XCTAssertTrue(items[5].remoteID.hasPrefix("bell:on_post_published:4000:"), "synthesized stable id when id is missing")
        XCTAssertEqual(body.nextUrl, "https://api.fanbox.cc/bell.list?page=2&skipConvertUnreadNotification=1&commentOnly=0")
    }

    // MARK: Newsletters / payments

    func testNewslettersAndPayments() throws {
        let newsletters = try FanboxFixtures.decodeBody(FanboxNewsletterListBody.self, FanboxFixtures.newsletters)
        let mapped = newsletters.items.compactMap(FanboxAdapter.newsletter)
        XCTAssertEqual(mapped.count, 2)
        XCTAssertEqual(mapped[0].creatorName, "Alice")
        XCTAssertEqual(mapped[0].creatorIconURL, "https://pixiv.pximg.net/icon.jpeg")
        XCTAssertFalse(mapped[0].isRead)
        XCTAssertNil(mapped[0].title)
        XCTAssertEqual(mapped[1].creatorName, "bob")
        XCTAssertTrue(mapped[1].isRead)

        let payments = try FanboxFixtures.decodeBody(FanboxPaymentListBody.self, FanboxFixtures.payments)
        let records = FanboxAdapter.payments(payments.items)
        XCTAssertEqual(records.map(\.id), ["3002", "3001"], "newest first; record without date dropped")
        XCTAssertEqual(records[0].amount, 1000)
        XCTAssertEqual(records[0].paymentMethod, "PAYPAL")
        XCTAssertEqual(records[1].creatorID, "alice")
        XCTAssertEqual(records[1].creatorName, "Alice")
        XCTAssertEqual(records[1].paidAt, FanboxFixtures.date("2026-08-02T10:00:00+09:00"))
    }

    // MARK: Session

    func testCurrentUserMapping() throws {
        let metadata = try FanboxMetadataParser.parse(html: FanboxFixtures.metadataHTML)
        let user = try FanboxAdapter.user(metadata)
        XCTAssertEqual(user.pixivUserID, "11")
        XCTAssertEqual(user.fanboxUserID, "11")
        XCTAssertEqual(user.creatorID, "alice")
        XCTAssertEqual(user.name, "Alice & Co > 1")
        XCTAssertNil(user.iconURL)
    }

    // MARK: Creator side

    func testManagedAndEditablePosts() throws {
        let month = FanboxDateParser.monthKey(.now)
        let body = try FanboxFixtures.decodeBody(FanboxManagedPostListBody.self, FanboxFixtures.managedPosts.replacingOccurrences(of: "MONTH", with: month))
        XCTAssertEqual(body.items.count, 3)
        let summaries = FanboxAdapter.managedPostSummaries(body.items, creatorID: "alice", creatorName: "Alice", creatorIconURL: nil)
        XCTAssertEqual(summaries.map(\.id), ["m2", "m1", "m3"], "newest activity first")
        XCTAssertEqual(summaries[0].excerpt, "下書き本文")
        XCTAssertEqual(summaries[0].feeRequired, 500)
        XCTAssertEqual(summaries[0].creatorName, "Alice")
        XCTAssertFalse(summaries[0].isRestricted)
        XCTAssertEqual(FanboxAdapter.publishedPostCount(body.items, month: month), 1)

        let editableBody = try FanboxFixtures.decodeBody(FanboxEditablePostBody.self, FanboxFixtures.editablePost)
        let editable = try XCTUnwrap(FanboxAdapter.editablePost(editableBody.post))
        XCTAssertEqual(editable.status, .draft)
        XCTAssertNil(editable.publishedAt, "drafts have no publish date")
        XCTAssertEqual(editable.tags, ["tag1"])
        XCTAssertEqual(editable.blocks.map(\.kind), [.paragraph, .image, .url])
        XCTAssertEqual(editable.blocks[1].mediaID, "im1")
        XCTAssertEqual(editable.blocks[2].mediaID, "ue1", "url_embed id kept for round-trip")
        XCTAssertEqual(FanboxAdapter.postStatus("published"), .published)
        XCTAssertEqual(FanboxAdapter.postStatus("weird"), .unknown)
    }

    func testFansFilterOptionsAndPledges() throws {
        let fans = try FanboxFixtures.decodeBody(FanboxFanListBody.self, FanboxFixtures.fans)
        let plan = RemotePlan(planID: "100", creatorID: "alice", title: "応援プラン", fee: 500, description: "", coverImageURL: nil, hasAdultContent: false)
        let mapped = fans.items.compactMap { FanboxAdapter.fan($0, plans: ["100": plan]) }
        XCTAssertEqual(mapped.count, 3, "fan without user dropped")
        XCTAssertEqual(mapped[0].state, .supporting)
        XCTAssertEqual(mapped[0].planTitle, "応援プラン")
        XCTAssertEqual(mapped[0].fee, 500)
        XCTAssertEqual(mapped[0].supportStartedAt, FanboxFixtures.date("2026-01-15T10:00:00+09:00"))
        XCTAssertNil(mapped[0].supportMonths, "no JSON field for total months")
        XCTAssertNil(mapped[1].planTitle, "unknown plan id")
        XCTAssertEqual(mapped[1].supportStartedAt, FanboxFixtures.date("2026-08-15T10:00:00+09:00"), "activedAt typo accepted")
        XCTAssertEqual(mapped[2].state, .following)

        let options = try FanboxFixtures.decodeBody(FanboxFanFilterOptionListBody.self, FanboxFixtures.filterOptions)
        XCTAssertEqual(FanboxAdapter.supporterCount(options.items), 12, "sum of plan buckets")
        let withTotal = try FanboxFixtures.decodeBody(FanboxFanFilterOptionListBody.self, #"[{"type":"supporter","planId":null,"count":9},{"type":"supporter","planId":"1","count":4}]"#)
        XCTAssertEqual(FanboxAdapter.supporterCount(withTotal.items), 9)
        XCTAssertNil(FanboxAdapter.supporterCount([]))

        let pledges = try FanboxFixtures.decodeBody(FanboxPledgeMonthlyBody.self, FanboxFixtures.pledgeMonthly(month: "2026-09"))
        XCTAssertEqual(FanboxAdapter.earnings(pledges, month: "2026-09"), 1500, "other target months excluded")
        XCTAssertEqual(pledges.previousMonth, "2026-08")
        XCTAssertNil(pledges.nextMonth)
    }

    // MARK: post.update form

    func testPostUpdateFormForTextDraft() throws {
        let draft = RemotePostDraft(title: "タイトル", feeRequired: 500, planID: nil, tags: ["a", "b"], hasAdultContent: false,
                                    blocks: [RemoteDraftBlock(kind: .header, text: "見出し", mediaID: nil, url: nil, embedProvider: nil, embedContentID: nil),
                                             RemoteDraftBlock(kind: .text, text: "一行目\n二行目", mediaID: nil, url: nil, embedProvider: nil, embedContentID: nil)],
                                    publish: false)
        let form = try FanboxPostUpdateForm.make(postID: "9001", draft: draft, csrfToken: "tok", existing: .init(), boundary: "B")
        let text = String(data: try form.encodedData(), encoding: .utf8) ?? ""
        func field(_ name: String) -> String? {
            // Note: "\r\n" is a single Character in Swift, so search for the CRLF substring.
            guard let range = text.range(of: "name=\"\(name)\"\r\n\r\n") else { return nil }
            let rest = text[range.upperBound...]
            guard let end = rest.range(of: "\r\n") else { return nil }
            return String(rest[..<end.lowerBound])
        }
        XCTAssertEqual(field("postId"), "9001")
        XCTAssertEqual(field("status"), "draft")
        XCTAssertEqual(field("feeRequired"), "500")
        XCTAssertEqual(field("title"), "タイトル")
        XCTAssertEqual(field("commentingPermissionScope"), "supporters")
        XCTAssertEqual(field("tt"), "tok")
        XCTAssertEqual(field("body"), #"[{"text":"見出し","type":"header"},{"text":"一行目","type":"p"},{"text":"二行目","type":"p"}]"#)
        // Updated for the review of native uploads: one field holding the JSON array, as FANBOX's web client sends it.
        XCTAssertEqual(text.components(separatedBy: "name=\"tags\"").count - 1, 1, "tags as ONE field")
        XCTAssertEqual(field("tags"), #"["a","b"]"#)
        // No tags: still sent, as an empty array.
        var untagged = draft
        untagged.tags = []
        let bare = String(data: try FanboxPostUpdateForm.make(postID: "9001", draft: untagged, csrfToken: "tok", existing: .init(),
                                                               boundary: "B").encodedData(), encoding: .utf8) ?? ""
        XCTAssertTrue(bare.contains("name=\"tags\"\r\n\r\n[]\r\n"))
        // Status: a draft stays a draft; a live (or already taken down) post is taken down with `archived`.
        XCTAssertEqual(FanboxPostUpdateForm.statusValue(publish: false, currentStatus: "draft"), "draft")
        XCTAssertEqual(FanboxPostUpdateForm.statusValue(publish: false, currentStatus: nil), "draft")
        XCTAssertEqual(FanboxPostUpdateForm.statusValue(publish: false, currentStatus: "published"), "archived")
        XCTAssertEqual(FanboxPostUpdateForm.statusValue(publish: false, currentStatus: "archived"), "archived")
        XCTAssertEqual(FanboxPostUpdateForm.statusValue(publish: true, currentStatus: "archived"), "published")
        XCTAssertFalse(text.contains("styles"), "no empty styles key")

        let withImage = RemotePostDraft(title: "t", feeRequired: 0, planID: nil, tags: [], hasAdultContent: false,
                                        blocks: [RemoteDraftBlock(kind: .image, text: "", mediaID: "local-1", url: nil, embedProvider: nil, embedContentID: nil)],
                                        publish: true)
        XCTAssertThrowsError(try FanboxPostUpdateForm.validateForCreate(withImage)) { error in
            guard case .unsupported? = error as? RemoteError else { return XCTFail("\(error)") }
        }
        let existing = FanboxPostUpdateForm.ExistingMedia(imageIDs: ["local-1"])
        let json = try FanboxPostUpdateForm.blocksJSON(withImage.blocks, existing: existing)
        XCTAssertEqual(json, [["type": "image", "imageId": "local-1"]])
        XCTAssertEqual(FanboxPostUpdateForm.commentingScope(feeRequired: 0), "everyone")
    }
}
