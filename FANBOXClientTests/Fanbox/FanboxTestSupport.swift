import Foundation
import XCTest
@testable import FANBOXClient

/// Scripted `HTTPClient` for the FANBOX module tests. Responses are queued per `endpointKey` and consumed in order;
/// the last one repeats. Stubbing a key whose only (already used) response is repeating replaces it.
/// Every request (and multipart upload body) is recorded.
///
/// Mirrors the production `HTTPClient` contract (`AccountHTTPClient` / `RoutingHTTPClient`): non-2xx answers are
/// RETURNED as `HTTPResponse`s (never thrown), so `FanboxAPIClient.validate` sees the same status / headers / body as in
/// the app. `FixTransportIntegrationTests` runs the same error paths over the real `AccountHTTPClient`.
final class FanboxFakeHTTPClient: HTTPClient, @unchecked Sendable {
    struct Stub {
        var status: Int
        var body: Data
        var headers: [String: String]
        var used = false
    }

    private let lock = NSLock()
    private var stubs: [String: [Stub]] = [:]
    private var _requests: [HTTPRequest] = []
    private var _uploadBodies: [Data] = []
    private var _accountIDs: [String?] = []

    var requests: [HTTPRequest] { lock.withLock { _requests } }
    var uploadBodies: [Data] { lock.withLock { _uploadBodies } }
    var accountIDs: [String?] { lock.withLock { _accountIDs } }

    func requests(for key: String) -> [HTTPRequest] { requests.filter { $0.endpointKey == key } }

    func stub(_ key: String, status: Int = 200, json: String, headers: [String: String] = ["Content-Type": "application/json"]) {
        stub(key, status: status, data: Data(json.utf8), headers: headers)
    }

    func stub(_ key: String, status: Int = 200, data: Data, headers: [String: String] = [:]) {
        lock.withLock {
            var queue = stubs[key] ?? []
            if queue.count == 1, queue[0].used { queue.removeAll() }
            queue.append(Stub(status: status, body: data, headers: headers))
            stubs[key] = queue
        }
    }

    private func respond(to request: HTTPRequest, accountID: String?, uploadBody: Data? = nil) -> HTTPResponse {
        lock.withLock {
            _requests.append(request)
            _accountIDs.append(accountID)
            if let uploadBody { _uploadBodies.append(uploadBody) }
            var queue = stubs[request.endpointKey] ?? []
            let stub: Stub
            if queue.count > 1 {
                stub = queue.removeFirst()
            } else if !queue.isEmpty {
                queue[0].used = true
                stub = queue[0]
            } else {
                stub = Stub(status: 404, body: Data(#"{"error":"not_stubbed"}"#.utf8), headers: [:])
            }
            stubs[request.endpointKey] = queue
            return HTTPResponse(statusCode: stub.status, headers: stub.headers, data: stub.body, url: request.url, duration: 0.01)
        }
    }

    func send(_ request: HTTPRequest, accountID: String?) async throws -> HTTPResponse {
        respond(to: request, accountID: accountID)
    }

    func download(_ request: HTTPRequest, accountID: String?, progress: (@Sendable (Double) -> Void)?) async throws -> (URL, HTTPResponse) {
        throw RemoteError.unsupported(operation: "download (fake)")
    }

    func upload(_ request: HTTPRequest, bodyFileURL: URL, accountID: String?,
                progress: (@Sendable (Double) -> Void)?) async throws -> HTTPResponse {
        let body = (try? Data(contentsOf: bodyFileURL)) ?? Data()
        progress?(1)
        return respond(to: request, accountID: accountID, uploadBody: body)
    }
}

/// Records `observe(endpointKey:rawJSON:known:)` calls made by `FanboxAPIClient`.
final class FanboxSchemaSpy: @unchecked Sendable {
    struct Call {
        var key: String
        var raw: Data
        var known: [String: Set<String>]
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { lock.withLock { _calls } }

    var observer: FanboxSchemaObserver {
        { [weak self] key, raw, known in
            guard let self else { return }
            self.lock.withLock { self._calls.append(Call(key: key, raw: raw, known: known)) }
        }
    }
}

/// Wiring helpers shared by the FANBOX test classes.
struct FanboxTestHarness {
    let http = FanboxFakeHTTPClient()
    let spy = FanboxSchemaSpy()
    let credentials = InMemoryCredentialStore()
    let api: FanboxAPIClient
    let source: FanboxRemoteDataSource

    init(wireCredentials: Bool = true) {
        api = FanboxAPIClient(http: http, inspector: SchemaInspector(), credentials: wireCredentials ? credentials : nil,
                              schemaObserver: spy.observer)
        source = FanboxRemoteDataSource(api: api, pageCache: FanboxPageURLCache(), nativePostWritesEnabled: true)
    }

    static let fan = AccountContext(accountID: "acc-fan", kind: .fanbox, pixivUserID: "99", fanboxUserID: "99", creatorID: nil)
    static let creator = AccountContext(accountID: "acc-creator", kind: .fanbox, pixivUserID: "11", fanboxUserID: "11", creatorID: "alice")

    func saveCredential(accountID: String, csrf: String?) async throws {
        try await credentials.save(SessionCredential(cookies: [StoredCookie(name: "FANBOXSESSID", value: "secret_value", domain: ".fanbox.cc")],
                                                     userAgent: "UA", csrfToken: csrf), for: accountID)
    }
}

enum FanboxFixtures {
    /// Wraps a body JSON literal in the `{ "body": ... }` envelope.
    static func envelope(_ body: String) -> String { #"{"body":"# + body + "}" }

    static func decodeBody<T: Decodable>(_ type: T.Type, _ body: String, key: String = "test") throws -> T {
        try FanboxResponseHandling.decodeBody(T.self, from: Data(envelope(body).utf8), endpointKey: key)
    }

    static func date(_ iso: String) -> Date { FanboxDateParser.parse(iso)! }

    // MARK: Timeline

    static let homeTimeline = #"""
    {"items":[
      {"id":"5001","title":"新作イラスト","feeRequired":500,"publishedDatetime":"2026-09-01T12:34:56+09:00",
       "updatedDatetime":"2026-09-02T08:00:00.123+09:00","tags":["illust","R"],"isLiked":true,"likeCount":"12",
       "isCommentingRestricted":false,"commentCount":3,"isRestricted":false,
       "user":{"userId":11,"name":"Alice","iconUrl":"https://pixiv.pximg.net/c/160x160_90_a2_g5/fanbox/public/images/user/11/icon/a.jpeg"},
       "creatorId":"alice","hasAdultContent":false,
       "cover":{"type":"cover_image","url":"https://pixiv.pximg.net/c/1200x630_90_a2_g5/fanbox/public/images/post/5001/cover/x.jpeg"},
       "excerpt":"本文冒頭","brandNewField":{"nested":true}},
      {"id":5000,"title":"限定","feeRequired":"1000","publishedDatetime":"2026-08-30T00:00:00Z","isRestricted":true,
       "creatorId":"bob","user":null,"cover":null,"excerpt":""},
      {"title":"no id item"}
    ],
    "nextUrl":"https://api.fanbox.cc/post.listHome?limit=10&maxPublishedDatetime=2026-08-30%2009%3A00%3A00&maxId=4999",
    "extraTop":1}
    """#

    // MARK: Post detail

    static let articlePost = #"""
    {"post":{
      "id":"6001","title":"ブログ","feeRequired":0,"publishedDatetime":"2026-09-10T10:00:00+09:00",
      "updatedDatetime":"2026-09-10T11:00:00+09:00","tags":[],"isLiked":false,"likeCount":0,"commentCount":2,"isRestricted":false,
      "user":{"userId":"11","name":"Alice","iconUrl":null},"creatorId":"alice","hasAdultContent":false,"type":"article",
      "coverImageUrl":"https://pixiv.pximg.net/c/1200x630_90_a2_g5/fanbox/public/images/post/6001/cover/c.jpeg","excerpt":"",
      "body":{
        "blocks":[
          {"type":"header","text":"見出し"},
          {"type":"p","text":"太字とリンク","styles":[{"type":"bold","offset":0,"length":2}],
           "links":[{"offset":3,"length":3,"url":"https://example.com/"}]},
          {"type":"p","text":""},
          {"type":"image","imageId":"img1","text":null,"fileId":null},
          {"type":"file","fileId":"f1"},
          {"type":"file","fileId":"f2"},
          {"type":"embed","embedId":"e1"},
          {"type":"url_embed","urlEmbedId":"u1"},
          {"type":"url_embed","urlEmbedId":"u2"},
          {"type":"url_embed","urlEmbedId":"u3"},
          {"type":"image","imageId":"missing"},
          {"type":"sparkle","text":"未知ブロック"}
        ],
        "imageMap":{"img1":{"id":"img1","extension":"png","width":1200,"height":"800",
          "originalUrl":"https://downloads.fanbox.cc/images/post/6001/img1.png",
          "thumbnailUrl":"https://downloads.fanbox.cc/images/post/6001/w/1200/img1.jpeg","newImageField":"x"}},
        "fileMap":{
          "f1":{"id":"f1","name":"theme","extension":"mp3","size":123456,"url":"https://downloads.fanbox.cc/files/post/6001/f1.mp3"},
          "f2":{"id":"f2","name":"archive","extension":"zip","size":"999","url":"https://downloads.fanbox.cc/files/post/6001/f2.zip"}},
        "embedMap":{"e1":{"id":"e1","serviceProvider":"youtube","contentId":"ignored","videoId":"abc123"}},
        "urlEmbedMap":{
          "u1":{"id":"u1","type":"default","url":"https://booth.pm/items/1","host":"booth.pm"},
          "u2":{"id":"u2","type":"html.card","html":"<div><a href=\"https://www.youtube.com/watch?v=zzz\" data-iframely-url=\"//cdn.iframe.ly/x\"></a></div>"},
          "u3":{"id":"u3","type":"fanbox.post","postInfo":{"id":"5555","title":"関連","creatorId":"alice","feeRequired":"300",
                "coverImageUrl":null,"user":{"userId":"11","name":"Alice"}}}}
      },
      "nextPost":{"id":"6002","title":"次","publishedDatetime":"2026-09-11T10:00:00+09:00"},"prevPost":null,
      "imageForShare":"https://pixiv.pximg.net/x.jpeg","isPinned":false,"someNewFlag":true
    }}
    """#

    /// Legacy (pre 2026-07-13) bare PostDetail, text type, missing optional fields.
    static let legacyTextPost = #"""
    {"id":"7","title":"テキスト","type":"text","creatorId":"bob","publishedDatetime":"2025-12-31T23:59:59+09:00",
     "body":{"text":"一行目\n二行目\n\n\n段落2\n"}}
    """#

    static let imagePost = #"""
    {"post":{"id":"8","title":"画像","type":"image","creatorId":"alice","feeRequired":100,"isRestricted":false,
     "publishedDatetime":"2026-09-12T09:00:00+09:00",
     "body":{"text":"説明文","images":[
       {"id":"i1","extension":"jpeg","width":800,"height":600,"originalUrl":"https://downloads.fanbox.cc/images/post/8/i1.jpeg","thumbnailUrl":"https://downloads.fanbox.cc/images/post/8/w/1200/i1.jpeg"},
       {"id":"i2","extension":"gif","width":10,"height":10,"originalUrl":"https://downloads.fanbox.cc/images/post/8/i2.gif","thumbnailUrl":"https://downloads.fanbox.cc/images/post/8/w/1200/i2.jpeg"},
       "garbage"
     ]}}}
    """#

    static let filePost = #"""
    {"post":{"id":"9","title":"ファイル","type":"file","creatorId":"alice","publishedDatetime":"2026-09-12T09:00:00+09:00",
     "body":{"text":"","files":[
       {"id":"a","name":"clip","extension":"MP4","size":1,"url":"https://downloads.fanbox.cc/files/post/9/a.mp4"},
       {"id":"b","name":"voice","extension":"wav","size":2,"url":"https://downloads.fanbox.cc/files/post/9/b.wav"},
       {"id":"c","name":"doc","extension":"pdf","size":3,"url":"https://downloads.fanbox.cc/files/post/9/c.pdf"},
       {"id":"d","name":"movie","extension":"m4v","size":4,"url":"https://downloads.fanbox.cc/files/post/9/d.m4v"},
       {"id":"e","name":"song","extension":"flac","size":5,"url":"https://downloads.fanbox.cc/files/post/9/e.flac"}
     ]}}}
    """#

    static let videoPost = #"""
    {"post":{"id":"10","title":"動画","type":"video","creatorId":"alice","publishedDatetime":"2026-09-12T09:00:00+09:00",
     "body":{"text":"見てね","video":{"serviceProvider":"vimeo","videoId":42}}}}
    """#

    static let restrictedPost = #"""
    {"post":{"id":"11","title":"限定","type":"image","creatorId":"alice","feeRequired":1000,"isRestricted":true,"body":null,
     "publishedDatetime":"2026-09-12T09:00:00+09:00","excerpt":"ちら見せ"}}
    """#

    static let entryPost = #"""
    {"post":{"id":"12","title":"旧記事","type":"entry","creatorId":"alice","publishedDatetime":"2019-01-01T00:00:00+09:00",
     "body":{"html":"<p>こんにちは&amp;</p><a href=\"https://downloads.fanbox.cc/images/entry/1/o.png\"><img src=\"https://downloads.fanbox.cc/images/entry/1/w/1200/o.jpeg\"></a><p>end</p>"}}}
    """#

    // MARK: Creator / plans

    static let creator = #"""
    {"user":{"userId":"11","name":"Alice","iconUrl":"https://pixiv.pximg.net/icon.jpeg"},"creatorId":"alice",
     "description":"イラストを描いています","hasAdultContent":false,"coverImageUrl":"https://pixiv.pximg.net/cover.jpeg",
     "profileLinks":["https://twitter.com/alice","https://alice.example"],
     "profileItems":[{"id":"p1","type":"image","imageUrl":"https://pixiv.pximg.net/p1.jpeg","thumbnailUrl":"https://pixiv.pximg.net/c/400x400/p1.jpeg"},
                     {"id":"p2","type":"video","serviceProvider":"youtube","videoId":"vid"},{"id":"p3","type":"hologram"}],
     "isFollowed":true,"isSupported":false,"isStopped":false,"isAcceptingRequest":true,"hasBoothShop":false,"hasPublishedPost":true,
     "category":null,"fanCount":123}
    """#

    static let supportingPlansWrapped = #"""
    {"plans":[
      {"id":"100","title":"応援プラン","fee":500,"description":"ありがとう","coverImageUrl":null,
       "user":{"userId":"11","name":"Alice","iconUrl":"https://pixiv.pximg.net/icon.jpeg"},"creatorId":"alice","hasAdultContent":false,
       "paymentMethod":"PAYPAL","perks":[]},
      {"id":200,"title":"スタンダード","fee":"1000","creatorId":"bob","paymentMethod":"gmo_card","user":{"userId":"22","name":"Bob"}},
      {"title":"broken plan without ids"}
    ]}
    """#

    static let supportingPlansBare = #"""
    [{"id":"100","title":"応援プラン","fee":500,"creatorId":"alice","paymentMethod":null}]
    """#

    // MARK: Comments

    static let comments = #"""
    {"viewMode":"OPEN","commentList":{"items":[
      {"id":"c1","parentCommentId":"0","rootCommentId":"0","body":"最初のコメント","createdDatetime":"2026-09-10T12:00:00+09:00",
       "likeCount":2,"isLiked":false,"isOwn":false,"user":{"userId":"50","name":"Fan","iconUrl":null},
       "replies":[
         {"id":"c3","parentCommentId":"c2","rootCommentId":"c1","body":"返信の返信","createdDatetime":"2026-09-10T14:00:00+09:00",
          "likeCount":0,"isLiked":false,"isOwn":true,"user":{"userId":"99","name":"Me"},"replies":[]},
         {"id":"c2","parentCommentId":"c1","rootCommentId":"c1","body":"返信","createdDatetime":"2026-09-10T13:00:00+09:00",
          "likeCount":"1","isLiked":true,"isOwn":false,"user":{"userId":"11","name":"Alice"},"replies":[]}
       ]},
      {"id":"c4","parentCommentId":"0","rootCommentId":"0","body":"退会者のコメント","createdDatetime":"2026-09-11T09:00:00+09:00",
       "likeCount":0,"isLiked":false,"isOwn":false,"user":null,"replies":[],"reactionCount":5}
    ],"nextUrl":"https://api.fanbox.cc/post.getComments?postId=6001&offset=20&limit=20"}}
    """#

    // MARK: Bell

    static let bells = #"""
    {"items":[
      {"id":"b1","type":"on_post_published","notifiedDatetime":"2026-09-20T10:00:00+09:00","isUnread":true,
       "post":{"id":"5001","title":"新作イラスト","feeRequired":500,"publishedDatetime":"2026-09-20T10:00:00+09:00",
               "creatorId":"alice","user":{"userId":"11","name":"Alice","iconUrl":"https://pixiv.pximg.net/icon.jpeg"},
               "cover":{"type":"cover_image","url":"https://pixiv.pximg.net/cover.jpeg"},"excerpt":"…","isRestricted":false}},
      {"id":"b2","type":"post_comment","notifiedDatetime":"2026-09-20T09:00:00+09:00","isUnread":false,"post":null,
       "postCommentBody":"素敵です","isRootComment":true,"creatorId":"alice","postId":"5001","postTitle":"新作イラスト",
       "userName":"Fan","userProfileImg":"https://pixiv.pximg.net/fan.jpeg"},
      {"id":"b3","type":"post_comment","notifiedDatetime":"2026-09-20T08:00:00+09:00","isUnread":true,
       "postCommentBody":"返信ありがとう","isRootComment":false,"creatorId":"alice","postId":"5001","postTitle":"新作イラスト","userName":"Alice"},
      {"id":"b4","type":"post_comment_like","notifiedDatetime":"2026-09-19T08:00:00+09:00","isUnread":false,
       "postCommentBody":"素敵です","creatorId":"alice","postId":"5001","count":3,"postTitle":null,"userName":null,"userProfileImg":null},
      {"id":"b5","type":"support_started_someday","notifiedDatetime":"2026-09-18T08:00:00+09:00","isUnread":true,"mystery":{"a":1}},
      {"type":"on_post_published","notifiedDatetime":"2026-09-17T08:00:00+09:00","post":{"id":"4000","title":"古い","creatorId":"bob"}}
    ],"nextUrl":"https://api.fanbox.cc/bell.list?page=2&skipConvertUnreadNotification=1&commentOnly=0"}
    """#

    // MARK: Newsletters / payments

    static let newsletters = #"""
    [
      {"id":"n1","body":"いつも応援ありがとうございます","createdAt":"2026-09-01T20:00:00+09:00",
       "creator":{"creatorId":"alice","user":{"userId":"11","name":"Alice","iconUrl":"https://pixiv.pximg.net/icon.jpeg"}},"isRead":false,
       "attachmentCount":0},
      {"id":"n2","body":"お知らせ","createdAt":"2026-09-05T20:00:00+09:00","creator":{"creatorId":"bob"},"isRead":true}
    ]
    """#

    static let payments = #"""
    {"payments":[
      {"id":3001,"paidAmount":500,"paymentDatetime":"2026-08-02T10:00:00+09:00","paymentMethod":"card",
       "creator":{"creatorId":"alice","user":{"userId":"11","name":"Alice","iconUrl":null},"isActive":true}},
      {"id":"3002","paidAmount":"1000","paymentDatetime":"2026-09-02T10:00:00+09:00","paymentMethod":"PAYPAL",
       "creator":{"creatorId":"bob","user":{"userId":"22","name":"Bob"}}},
      {"id":"3003","paidAmount":100}
    ]}
    """#

    // MARK: Creator side

    static let managedPosts = #"""
    [
      {"id":"m1","title":"公開済み","status":"published","permalink":"https://www.fanbox.cc/@alice/posts/m1","feeRequired":0,
       "updatedAt":"MONTH-05T10:00:00+09:00","publishedAt":"MONTH-05T10:00:00+09:00"},
      {"id":"m2","title":"下書き","status":"draft","feeRequired":500,"updatedAt":"MONTH-06T10:00:00+09:00","publishedAt":null,
       "body":{"blocks":[{"type":"p","text":"下書き本文"}],"imageMap":{},"urlEmbedMap":{}}},
      {"id":"m3","title":"先月","status":"published","feeRequired":0,"updatedAt":"2020-01-01T10:00:00+09:00",
       "publishedAt":"2020-01-01T10:00:00+09:00"}
    ]
    """#

    static let editablePost = #"""
    {"id":"m2","title":"下書き","status":"draft","permalink":"https://www.fanbox.cc/@alice/posts/m2","feeRequired":500,
     "updatedAt":"2026-09-06T10:00:00+09:00","publishedAt":"2026-09-06T10:00:00+09:00","tags":["tag1"],
     "body":{"blocks":[{"type":"p","text":"本文"},{"type":"image","imageId":"im1"},{"type":"url_embed","urlEmbedId":"ue1"}],
             "imageMap":{"im1":{"id":"im1","extension":"png","originalUrl":"https://downloads.fanbox.cc/images/post/m2/im1.png",
                                "thumbnailUrl":"https://downloads.fanbox.cc/images/post/m2/w/1200/im1.jpeg"}},
             "urlEmbedMap":{"ue1":{"id":"ue1","type":"default","url":"https://example.com/"}}}}
    """#

    static let fans = #"""
    [
      {"status":"supporter","user":{"userId":"50","name":"Fan","iconUrl":null},"planId":"100","activatedAt":"2026-01-15T10:00:00+09:00","note":"古参"},
      {"status":"supporter","user":{"userId":"51","name":"Fan2"},"planId":"999","activedAt":"2026-08-15T10:00:00+09:00","note":""},
      {"status":"follower","user":{"userId":"52","name":"Follower"},"planId":null},
      {"status":"supporter","user":null}
    ]
    """#

    static let filterOptions = #"""
    [
      {"type":"all","planId":null,"planTitle":null,"count":30},
      {"type":"supporter","planId":"100","planTitle":"応援プラン","count":7},
      {"type":"supporter","planId":"200","planTitle":"スタンダード","count":"5"},
      {"type":"follower","planId":null,"planTitle":null,"count":18}
    ]
    """#

    static func pledgeMonthly(month: String) -> String {
        #"""
        {"supportTransactions":[
          {"id":"t1","supporter":{"userId":"50","name":"Fan"},"paidAmount":500,"paymentMethod":"card",
           "transactionDatetime":"MONTH-02T10:00:00+09:00","targetMonth":"MONTH"},
          {"id":"t2","supporter":{"userId":"51","name":"Fan2"},"paidAmount":"1000","transactionDatetime":"MONTH-03T10:00:00+09:00",
           "targetMonth":"MONTH"},
          {"id":"t3","paidAmount":300,"targetMonth":"1999-01"}
        ],"nextMonth":null,"previousMonth":"2026-08"}
        """#.replacingOccurrences(of: "MONTH", with: month)
    }

    // MARK: Metadata

    static let metadataHTML = #"""
    <!DOCTYPE html><html><head><meta charset="utf-8"><meta name="description" content="pixivFANBOX">
    <meta name="metadata" id="metadata" content="{&quot;apiUrl&quot;:&quot;https:\/\/api.fanbox.cc&quot;,&quot;csrfToken&quot;:&quot;tok-fresh-123&quot;,&quot;context&quot;:{&quot;privacyPolicy&quot;:{&quot;policyUrl&quot;:&quot;\/privacy&quot;},&quot;user&quot;:{&quot;userId&quot;:&quot;11&quot;,&quot;creatorId&quot;:&quot;alice&quot;,&quot;name&quot;:&quot;Alice &amp; Co &gt; 1&quot;,&quot;iconUrl&quot;:null,&quot;isCreator&quot;:true,&quot;isSupporter&quot;:true,&quot;hasUnpaidPayments&quot;:false,&quot;planCount&quot;:2,&quot;fanboxUserStatus&quot;:2,&quot;lang&quot;:&quot;ja&quot;}},&quot;isNewTopLevel&quot;:1}">
    </head><body></body></html>
    """#

    static let loggedOutMetadataHTML = #"""
    <html><head><meta name='metadata' content='{"csrfToken":"anon","context":{"user":{"userId":null,"name":"","isCreator":false}}}'></head></html>
    """#
}
