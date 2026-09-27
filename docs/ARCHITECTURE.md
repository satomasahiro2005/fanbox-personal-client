# Architecture

This document describes how FANBOX Personal Client is put together. The requirements are in [SPEC.md](../SPEC.md);
section numbers below (§n) refer to it. "docs/API.md §n" refers to [API.md](API.md).

It describes the code. The app has been verified on a real iPhone with real FANBOX accounts, except posting: Creator
Mode's post create / update and media uploads (`post.create`, `post.update`, `post.addImage`, `post.addFile`,
`post.addUrlEmbed`) have not been tried against FANBOX yet. The FANBOX details it
relies on (endpoint shapes, Cloudflare behavior, rate limits) were collected from public reports in API.md. The demo
accounts run the same UI without a network.

## Goals that shape the design

1. **Local data first** (§1, §3.1). Every main screen renders from SwiftData. Nothing waits for the network before it
   shows something.
2. **Text before media** (§29, §46). Notifications, comments and post text are fetched and sent before images, video
   or attachments, including on a 128 kbps connection.
3. **Several accounts, one self** (§0, §3.2, §46). The accounts exist to support the same creators more than once,
   because FANBOX allows one plan per account per creator. Each account has an isolated session, and a session is never
   used for an account it does not belong to. A post, comment or newsletter seen by several accounts is stored once.
   Supports, payment assignments, payment records, support history and support-state events each belong to one
   account and are never merged across accounts; per-creator totals add up the supports of every account.
4. **No mass collection** (§3.7). Sync reads the newest items and stops at the first known one.

## Layers

```text
+----------------------------------------------------------------------------------------------+
| SwiftUI views (Features/*)                                                                   |
|   render SwiftData rows with @Query; start refreshes in .task / .refreshable                 |
|   never see endpoints, DTOs or JSON (§43)                                                    |
+----------------------------------------------------------------------------------------------+
| Services / use cases (Core/*, reached through AppEnvironment)                                |
|   SyncEngine, SyncCoordinator, ReplyQueue, NotificationService, MediaService,                |
|   MediaPrefetcher, OfflineLibraryService, AccountService, WebBridge, PaymentResyncScheduler, |
|   UploadQueue, DraftService, SearchService, SupportAnalyzer, AccountSelector                 |
+----------------------------------------------------------------------------------------------+
| Local store and remote sources                                                               |
|   LocalStore (LocalDataSource)          RemoteDataSource (protocol)                          |
|   SwiftData main context,               DefaultRemoteDataSourceProvider picks per account:   |
|   the ONLY writer of normalized data      - FanboxRemoteDataSource (FanboxAdapter)           |
|                                           - DemoRemoteDataSource (in-memory demo world)      |
+----------------------------------------------------------------------------------------------+
| FANBOX access (Fanbox/*, Core/Network/*, Core/Web/*)                                         |
|   FanboxAPIClient -> RoutingHTTPClient (asks RateGate first)                                 |
|                     |-> AccountHTTPClient (per-account URLSession)       -> NetworkScheduler |
|                     '-> WebFetchHostPool (per-account hidden WKWebView)  -> NetworkScheduler |
|   DTOs are decoded leniently; SchemaInspector records unknown / missing fields               |
+----------------------------------------------------------------------------------------------+
| FANBOX API (api.fanbox.cc), pages (www.fanbox.cc), media (downloads.fanbox.cc, pximg.net)    |
| and the visible account-aware WKWebView (AccountWebView) for features that stay on the web   |
+----------------------------------------------------------------------------------------------+
```

- `Remote*` value types (`Core/Models/RemoteModels.swift`) are the boundary between the FANBOX adapter and the rest of
  the app. When the FANBOX API changes, the fix belongs in `Fanbox/API`, `Fanbox/DTO` or `Fanbox/Adapter` (§43).
- `DefaultFanboxRepository` (`Core/Sync/FanboxRepository.swift`) implements the §43 repository façade on top of
  `LocalStore` and `SyncEngine`: local-first reads, and an error only when nothing is cached. It is a thin façade, not
  the main data path. Its only caller in v1.0 is the notification pipeline: `NotificationService` creates its own
  instance for post text prefetch. `AppEnvironment.repository` exists, but screens read SwiftData with `@Query` and
  call `SyncEngine` and the other services directly.

### Dependency container

`AppEnvironment` (`App/AppEnvironment.swift`) creates every service once and wires the callbacks between them
(`wire()`):

| Callback | Target |
|---|---|
| `SyncEngine.onNewNotificationEvents` | `NotificationService.process(newEventIDs:)`, then `MediaPrefetcher.notificationEventsProcessed` |
| `SyncEngine.onSyncFinished` | `OfflineLibraryService.syncFinished` ("recent N" rules) and `MediaPrefetcher.syncFinished` |
| `SyncEngine.onFailure` | `ResearchRecorder.recordSyncFailure` (Research Mode "Sync / Errors") |
| `SyncEngine.onIdentityMismatch` | `AccountService.quarantineMismatchedSession` |
| `SyncEngine.onSessionExpired` | `SessionExpiryNotifier.notify` (one local notification per account) |
| `ReplyQueue.onAttentionNeeded` | `NotificationService.handleReplyAttention(itemID:)` |
| `SyncCoordinator.notifications` | failed-prefetch retry and badge refresh when the app becomes active |
| `NotificationService.mediaPrefetcher` | `MediaService.load` (avatars / thumbnails, still gated by `MediaPolicy`) |
| `NetworkModeController.onConnectivityRestored` | `ReplyQueue.handleConnectivityRestored()` and `UploadQueue.start()` |
| `WebBridge.onDismiss` | `PaymentResyncScheduler.handleDismissedPaymentSession`; a managed-posts sync after the web post editor (`CreatorWebReconcile`) |
| `AccountService.sessionRevoker` | the `RoutingHTTPClient` (`SessionRevoking`) |
| `AccountHTTPClient.onSessionCookieChanged` | `AccountService.installAPISessionIntoWeb` |
| `WebFetchHostPool.accountResolver` / `prepareSession` / `onIdentityMismatch` | local account lookup, `AccountService.prepareWebSession`, `AccountService.handleWebIdentityMismatch` |

Views read the container with `@Environment(AppEnvironment.self)`.

- `AppEnvironment.live()` builds the production graph: on-disk store, Keychain credentials, transport preferences in
  standard `UserDefaults`. With `-uiTesting` it uses an in-memory store, `InMemoryCredentialStore`, a throwaway
  defaults suite and in-memory transport preferences; `-demoData` seeds three demo accounts when there are none. It then
  applies the router's launch arguments, starts `NetworkModeController` (also for background launches without a
  scene), deletes stale multipart body files, and deletes temporary login-probe credentials left by an interrupted
  login.
- `AppEnvironment.preview(seedDemo:)` builds an in-memory graph with demo accounts for previews and tests.

## Local-first flow

```text
App launch
    |
    v
Open SwiftData store (no network)            PersistenceController.makeContainer
    |                                        (an unreadable store is moved aside, see SECURITY.md)
    v
First frame from the local DB                RootView -> tabs -> @Query
    |
    v
.task after the first frame                  NetworkModeController.start() (already running; idempotent)
    |                                        NotificationService.configure()
    |                                        SyncCoordinator.start(): reply flush, launch refresh,
    |                                          foreground polling
    |                                        RemoteRelay.registerIfEnabled (off by default)
    v
Differential sync (background priority)      SyncEngine.syncAll(reason: .appLaunch)
    |
    v
Normalize + upsert                           LocalStore+Upserts (Remote* -> @Model)
    |
    v
@Query views update automatically
```

On failure the screen keeps its cached rows and shows `SyncStatusBanner`
("同期できませんでした" (sync failed) / "キャッシュ済みデータを表示しています" (showing cached data) /
"最後の同期: HH:mm" (last sync), §44). Network errors never delete cached rows.

## Data model

All models are listed in `AppSchema.models` (`Core/Database/Persistence.swift`). Enum-backed fields are stored as
`…Raw` strings with typed accessors.

```text
Account ───< PostAccess >─── Post ───< PostBlock
   │                          │
   │                          └── Comment, OutgoingComment (reply queue), PostTag >── Tag
   │
   ├───< Support >──── Creator ───< Plan
   │        │
   │        ├── SupportHistory (observed changes)
   │        └── SupportPaymentAssignment ──> PaymentProfile
   ├── defaultPaymentProfileID ──────────────────> PaymentProfile
   │
   ├───< PaymentRecord, NotificationEvent (post / comment / newsletter events merged across accounts), Newsletter
   ├───< Fan, CreatorDashboardSnapshot            (creator accounts)
   └───< SyncState (per account / resource / scope)

Draft ───< DraftBlock
Draft ───< UploadJob
Media, MediaCacheEntry                            (media file cache bookkeeping)
ResearchLog, APISchemaSnapshot                    (Research Mode / API Inspector)
```

- A post is stored once (`Post.postID` is unique). Per-account visibility lives in `PostAccess`.
- A new-post, comment or newsletter notification seen by several accounts is one `NotificationEvent` whose id is an
  account-independent dedupe key (`NotificationEvent.dedupeKey`), with `accountIDs` listing every receiver. Derived
  support events (`supportChanged`, `paymentAttention`, `newSupporter`) are keyed per account (fallback
  `local:<accountID>:…`): each account's support change, stop or payment problem is its own event, even for a creator
  that other accounts still support.
- Supports are one row per account and creator (`Support.key` is `accountID|creatorID`), and so are
  `SupportPaymentAssignment` rows; `PaymentRecord` and `SupportHistory` rows carry their account too. The same creator
  under several accounts is the normal case: per-creator views add the rows up and never merge them.
- The payment profile a support line shows is resolved when the line is drawn (`PaymentResolution`): the support's
  own assignment, else the account default (`Account.defaultPaymentProfileID`, skipped when FANBOX reports a different
  payment type), else a guess from the reported type, else none. Nothing is copied into the supports, so changing the
  default changes every support that inherits it. 前回 is the newest `PaymentRecord` of the account and creator; 次回 is
  the 1st–5th (JST) of the next billing month unless a stop is scheduled (`SupportBilling.nextCharge`).
- User metadata (read, favorite, read later, memo, tags, offline state) is never overwritten by remote data and is
  never sent to FANBOX (§33).
- Secrets are not stored in SwiftData. See [SECURITY.md](SECURITY.md).

## Sync engine

`SyncEngine` (`Core/Sync/SyncEngine.swift`) owns all reads from FANBOX.

- **Bookkeeping.** One `SyncState` row per `(accountID, resource, scope)` holds `lastSuccessfulSync`, `lastAttemptAt`,
  `cursor`, `lastKnownItemID`, `error` and `consecutiveFailures` (§34).
- **Differential stop** (§3.7). Feeds are read newest first. Paging stops at the first page that contains a post the
  account already knows. A first sync and lightweight reasons (background refresh, foreground polling, silent push)
  read one page; other reasons read at most `maxFeedPages` (3). Older pages of a creator are loaded only when the user
  asks (`loadMoreCreatorPosts`).

  ```text
  Latest page ─> new post ─> new post ─> known post id ─> STOP
  ```

- **Coalescing.** Concurrent requests for the same `(account, resource, scope)` share one run. `syncAll` is also
  shared while it is running; a caller with a higher priority raises the priority of the batch's remaining requests.
- **Plans.** `syncAll` (launch, pull to refresh): notifications, supports, timeline, supporting timeline, creators,
  plus dashboard, creator comments and fans for creator accounts. `syncLightweight` (background refresh, silent push):
  notifications, supports, timeline, plus fans for creator accounts (so 新規支援 (new supporter) can be detected).
- **Throttles.** Some resources answer from the local DB while their last refresh is recent: the fan list (about every
  6 hours automatically, 10 minutes for screens that open with `.onDemand`), `payment.listPaid` (daily, every 6 hours
  in the first week of the month, never automatically in Low Data / Extreme), the unpaid-payment check (6 hours, hourly
  on the 1st–5th), and creator reads (`CreatorReadPolicy`: dashboard and creator comments 10 minutes, managed posts
  5 minutes). Pull to refresh, after-write and notification-triggered syncs bypass the creator throttles.
- **Priority by reason.** User-initiated work runs as `interactiveRead`; notification detection as
  `notificationPrefetch`; launch, polling and background work as `backgroundSync`. Notification listings are never
  below `notificationPrefetch`.
- **Session state gating.** FANBOX accounts in `.error` (identity mismatch) are never synced. Accounts in `.expired` /
  `.loggedOut` are skipped for automatic reasons (launch, polling, background, silent push); explicit refreshes still
  run. Offline returns at once without touching local data.
- **Identity check.** The `session` resource reads the logged-in user. If it is not the account's `pixivUserID`, the
  engine calls `onIdentityMismatch` (quarantine, see [Accounts, sessions and identity](#accounts-sessions-and-identity))
  and stores nothing. `applyCurrentUser` never rebinds an account to another pixiv user, and a successful sync never
  clears `.error`.
- **Errors.** Mapped to `RemoteError`, stored in `SyncState.error`. `.unauthorized` marks the session expired (and
  posts one local notice). Cached data stays.
- **Account choice for post bodies.** `AccountSelector` (§8: cached → can view → valid session → higher plan → main
  account). If the chosen account only gets a restricted body, other accounts are tried, but only accounts that may be
  entitled. Accounts in `.error` are never picked automatically.
- **Edge-blocked post bodies.** When the detail endpoint is edge-blocked (or answers 403), the engine does not try the
  other accounts (they would get the same block), refreshes the summary through `post.get`, and pauses automatic detail
  fetches for 15 minutes (`postDetailBlockCooldown`). The post screen then shows `SessionEdgeBlockNotice`, which says
  the login is unaffected and offers the account web view.

`SyncCoordinator` (`Core/Sync/SyncCoordinator.swift`) decides when to sync: after the first frame, on foreground
polling (`AppSettings.foregroundPollingInterval`, never below 15 s; notifications every tick, newest timeline page every
fifth tick), when the scene becomes active, on pull to refresh, and from `BGAppRefreshTask` / `BGProcessingTask`
(`BackgroundRefresh`). Queued replies are flushed at launch (alongside the launch refresh), on every polling tick,
when the scene becomes active, and before background refresh work. The maintenance task enforces the cache size,
prunes Research logs older than 14 days and prunes old inbox events.

## Transport

Every FANBOX request goes through `RoutingHTTPClient` (`Core/Network/RoutingHTTPClient.swift`), which is the app's
`HTTPClient`. It chooses between two transports of the same account and applies the device-wide `RateGate`. The design
follows docs/API.md §1.7–§1.11. Research Mode can force either transport to see which one FANBOX accepts.

### The two transports

| | Native | WebView |
|---|---|---|
| Type | `AccountHTTPClient` (`Core/Network/AccountHTTPClient.swift`) | `WebFetchHostPool` / `WebFetchHost` (`Core/Web/WebFetchHost.swift`) |
| Session | One ephemeral `URLSession` per account; no cookie storage, no URL cache. Cookies are attached by hand from the account's Keychain credential, only for *.fanbox.cc. The user agent is the one captured from the account's web view (a WKWebView-shaped default until one is captured). | A hidden `WKWebView` per account that uses the account's own `WKWebsiteDataStore` and has `https://www.fanbox.cc/` loaded. `fetch(url, {credentials: "include"})` runs in the isolated `.defaultClient` content world through `callAsyncJavaScript`; the result comes back as the script's return value. |
| Before first use | — | The page metadata is read; the logged-in user must equal the account's `pixivUserID`. A mismatch shuts the page down and reports it to `AccountService`. |
| Limits | — | Foreground only. At most 2 live pages (LRU), closed after 3 minutes idle, on entering the background, on a memory warning, in Offline mode, and on logout / removal. The page (and its CSRF token) is reloaded after 30 minutes. Only `https://api.fanbox.cc` and `https://www.fanbox.cc` URLs; writes use `redirect: "manual"`. |
| Research log | One redacted entry per request, marked `transport: native` | One redacted entry per request, marked `transport: webview` |

Both transports run inside `NetworkScheduler.run(priority, label:)`, so priorities and Offline apply to both.

### Routing

`TransportRouter.plan(...)` gives an ordered list of transports to try:

| Situation | Order |
|---|---|
| Host is not api.fanbox.cc / www.fanbox.cc (media hosts, pximg) | native only, outside `RateGate` |
| App in the background, no account, or no web transport | native only |
| Research override "Native のみ" (native only) | native only |
| Research override "WebView のみ" (web view only) | WebView only (native while in the background) |
| `post.info`, `post.getEditable` (`webFirstEndpoints`), or an endpoint whose native request was edge-blocked in the last 24 hours (`TransportPreferences`) | WebView, then native |
| Everything else | native, then WebView |

The second transport is used only when the first one did not reach FANBOX:

- the native answer was an edge block (below), or native had no CSRF token while the WebView page has its own;
- the WebView could not be used (`WebFetchError.unavailable`: background, no usable web session, page not ready,
  identity mismatch). Nothing was sent in these cases, so this also applies to writes;
- a WebView GET whose script failed may be retried natively. A write with an unknown outcome (timeout, script error) is
  never re-sent.

Downloads always use the native transport. Uploads (from a body file or a streamed body) use the native transport, with
the same budget and classification.

### Edge-block classification

`EdgeBlockDetector` (`Core/Network/EdgeBlockDetector.swift`) tells a CDN block apart from FANBOX's own refusal:

- only 403 and 503 can be edge blocks;
- a `cf-mitigated` header means an edge block;
- a JSON content type or a body that starts like JSON is FANBOX's answer (401 / 403 / 404 decide the session or the
  entitlement);
- an HTML page from `Server: cloudflare`, or a body containing a challenge / block marker ("just a moment",
  `cf-chl-`, "challenge-platform", "attention required", "cloudflare ray id", `cf-error-details`, `__cf_chl`,
  "ブロックされました" (blocked)), is an edge block;
- 429 is always rate limiting (`RemoteError.rateLimited`), never an edge block.

Inside the web view a CORS-less edge answer surfaces only as a `TypeError`; while the network is up it is mapped to
`RemoteError.edgeBlocked`. An edge block never changes the account's session state (`AccountService.sessionState(for:)`
treats it as "unknown").

### Request budget, cooldowns and breakers

`RateGate` (`Core/Network/RateGate.swift`) is consulted before every attempt to api.fanbox.cc / www.fanbox.cc, on both
transports, before the request takes a scheduler slot. The numbers are inferred from third-party reports
(docs/API.md §1.8), not measured.

| Rule | Value |
|---|---|
| Heavy lane (`post.info`, `post.getEditable`) | at least 1 s between starts, device-wide, every priority; interactive requests are served before queued background ones |
| Light lane (other calls) | 0.2 s between starts unless interactive |
| Background budget (heavy lane) | at most 6 starts per 60 s for backgroundSync / notificationPrefetch / mediaPrefetch; a request that would wait more than 30 s fails with `.rateLimited` |
| 429 cooldown | every budgeted call fails fast for Retry-After, or 6 minutes without one (at most 1 hour). Interactive requests are not exempt. |
| Native edge block | device-wide breaker for that endpoint on the native transport, 15 minutes (longer if Retry-After says so) |
| WebView edge block | breaker for that account's WebView transport, 6 minutes |
| WebView edge blocks on two accounts within 2 minutes | device-wide cooldown, 6 minutes |

Breakers never repeat one block across accounts. Logout, removal and re-login reset the account's breakers. Research
Mode shows the cooldown, the breakers, the per-endpoint WebView preference and the background budget, and can reset
them.

## Network scheduler and modes

Every HTTP request runs inside `NetworkScheduler.run(priority, label:operation:)` (`Core/Network/NetworkScheduler.swift`).
Callers set the priority with the task-local `RequestContext.$priority`.

| Priority | Value | Typical use |
|---|---:|---|
| interactiveWrite | 100 | posting a comment / reply, likes, post create / update |
| interactiveRead | 90 | opening a post, pull to refresh |
| notificationPrefetch | 80 | notification listings and the text of a newly detected notification |
| foregroundMedia | 50 | images on screen, media uploads |
| backgroundSync | 20 | launch / polling / background sync |
| mediaPrefetch | 5 | offline saving, image prefetch |

Interactive requests are admitted at once. While any interactive or notification request is in flight, no new media
request is admitted and registered media transfers are suspended, then resumed. At most one large media transfer
(original, video, audio, attachment, upload) runs at a time.

Offline gating (§30):

- the scheduler fails new and queued requests with `.offline`, and cancels registered downloads and uploads (an
  admitted `interactiveWrite` is left alone, because its outcome would become ambiguous);
- `WebFetchHostPool` closes every hidden page, and `WebFetchHost` cancels any navigation;
- the visible account web view loads nothing: `AccountWebSessionView` shows an offline state instead of the page, stops a
  running load when the mode switches, and `AccountWebCoordinator` cancels every http(s) navigation of the page and its
  popups;
- `SyncEngine` returns without touching local data; `ReplyQueue` and `UploadQueue` keep their items queued and resume
  when `NetworkModeController.onConnectivityRestored` fires. The demo data source also answers `.offline`.

The effective mode (Automatic / Normal / Low Data / Extreme / Offline) comes from `NetworkModeController` and
`MediaPolicy`. See [NETWORK_MODES.md](NETWORK_MODES.md).

## Accounts, sessions and identity

- `AccountService` (`Core/Authentication/AccountService.swift`) adds accounts through a login in the account-aware web
  view, checks sessions, logs out, removes accounts and manages the main account.
- A disabled account (`Account.enabled == false`) is skipped by sync and hidden everywhere except Settings → アカウント,
  the account's own support screen, the reply queue and Research Mode:
  screens read `FetchDescriptorFactory.enabledAccounts()` / `LocalStore.enabledAccountIDs()`, the denormalized
  `Creator.isSupported` / `isFollowed` and the post feed flags count enabled accounts only (`LocalStore.refreshRelationFlags`
  runs at launch and when an account is enabled or disabled), and the badge counts events of enabled accounts. Its local
  data is kept, so enabling it again shows everything again.
- `WebSessionStore` gives each account its own `WKWebsiteDataStore(forIdentifier: Account.webProfileID)`.
- `CredentialStore` keeps each account's cookies, CSRF token and user agent as one Keychain item. The item is created
  only for a verified session (a login, or a re-login verified in a web session); cookie, token and user-agent updates
  from responses change an existing item only.
- `WebBridge.openWeb(account:destination:purpose:)` opens `AccountWebView` for features that stay on the web
  (payment, some creator tools, fallbacks) (§14, §40).

Identity integrity (§3.2, §7.1, §40): a session is used for an account only after its logged-in pixiv user was
compared with the account's `pixivUserID`.

| Where | Check | On mismatch |
|---|---|---|
| Login / re-login | Page user compared before anything is stored; the captured session is probed under a temporary Keychain key (`login-probe-<uuid>`) and saved only if the user matches and no other local account already has that user | Nothing is stored; the web store is reset to the account's own session (a new placeholder is discarded) |
| Browse / payment web session | Every FANBOX page that finishes loading is inspected; a new session cookie without a page naming its user is probed first | The page and any popup stop, the web store is reset, nothing is copied |
| Hidden WebView transport | The page's user must match before the first fetch | The page is closed; the web store is reset |
| Session check / `session` sync | `currentUser` compared with the account | Quarantine: the account goes to `.error`, requests are revoked, the Keychain credential is deleted and the web store is cleared. Sync skips the account until a verified re-login. |

Teardown on logout and removal: `AccountService` first calls `RoutingHTTPClient.revokeSession(accountID:)`. It
invalidates the account's `URLSession` and bumps a per-account epoch, so a response that started earlier is dropped
without touching cookies. It also closes the account's hidden WebView before the data store is cleared, and resets the
account's breakers. Then the Keychain credential is deleted and the web store is cleared (logout) or removed
(removal). Details: [SECURITY.md](SECURITY.md).

## Notification pipeline

```text
Detection                       Prefetch (text first)              Local DB           iOS
-----------------------------   --------------------------------   ----------------   ---------------------
launch refresh                  NotificationService.process        NotificationEvent  UNNotificationRequest
foreground polling      ──>     highest priority first:     ──>    Post / Comment ──> (title + body from
BGAppRefreshTask                 comment + thread,                  Newsletter          the local DB)
silent push (optional relay)     post title + body,                 Support / Fan           |
                                 newsletter body,                                           v
                                 support / fan metadata                              tap / inline reply
                                (RequestPriority.notificationPrefetch)                     |
                                                                                           v
                                                               NotificationService.open: local render,
                                                               no HTTP wait; reply -> ReplyQueue
```

- New events come from `SyncEngine` (notifications resource). New-post, comment and newsletter events are deduplicated
  across accounts. FANBOX comment bells carry no comment id, so the same comment seen by two accounts is matched by
  post, text, author and time.
- Automatic polling asks `bell.countUnread` first and lists `bell.list` only when the count changed or 15 minutes
  passed; `newsletter.list` is polled at most every 10 minutes. Expired sessions are not polled.
- Event types and priorities (§24.2, `NotificationEventType`):

  | Type | Source | Priority | Prefetch |
  |---|---|---|---|
  | `comment`, `commentReply` | FANBOX bells | critical | comment thread (+ post body) |
  | `newPost` | FANBOX bells | high | post body |
  | `newsletter` (おたより) | `newsletter.list` | high | newsletter body |
  | `supportChanged` (支援状態変化, support changed) | supporting-plan list diff | high | supports |
  | `paymentAttention` (決済要確認, payment needs checking) | page metadata `hasUnpaidPayments` turning true, a creator listed by `payment.listUnpaid`, or a supported plan that disappears on the 1st–5th of the month | critical | supports |
  | `newSupporter` (新規支援, new supporter) | new supporters in the creator's fan list | normal | fan list |

  Derived events (docs/API.md §18.8 B) are created by `LocalStore+Upserts`. The support events (`supportChanged`,
  `paymentAttention`, `newSupporter`) are one per account: when one account's support stops, changes or disappears
  while another account keeps supporting the same creator, the event names only that account. The first sync of each
  source is a silent baseline. A `paymentAttention` reason is announced at most once per account, creator and month.
  The texts state observed facts only; they never say that a payment failed (§15).
- Prefetch follows `NotificationEventType.prefetchTarget` and records `prefetchState`. For comment events the commented
  comment is resolved from the thread (`NotificationCommentResolver`). After the text, `NotificationService` asks for
  avatars and thumbnails, and `MediaPrefetcher` adds thumbnails and up to three display images per post (not in a
  background launch). Both run at `mediaPrefetch`, and `MediaPolicy` decides whether anything is downloaded.
- The iOS notification is posted after the prefetch attempt. When the prefetch succeeded, its text and the screen behind
  it are already local. When it failed (offline, edge block, background without the WebView transport), the
  notification uses the text of the listing, and the prefetch is retried when the app becomes active (events of the last
  48 hours, at most 20). Events older than 3 days are imported without a banner.
- Critical events use `.timeSensitive` only when the Time Sensitive entitlement is available; the target has no
  entitlements file today, so they are delivered as `.active`.
- Inline replies are queued in `ReplyQueue` first (they work offline) and are sent as `interactiveWrite`, threaded under
  the resolved comment. If the comment cannot be identified, the text is kept as a draft and a notice asks the user to
  choose the target in the thread; a reply is never turned into a top-level comment.
- A session that moves to `.expired` posts one local notice per account (`SessionExpiryNotifier`).
- Inbox: read events older than 90 days are pruned, and remote items older than that are not re-imported.
- The optional APNs relay only wakes the app; see [NOTIFICATION_RELAY.md](NOTIFICATION_RELAY.md).

## Reply queue

`ReplyQueue` (`Core/Sync/ReplyQueue.swift`) stores every comment / reply as an `OutgoingComment` before sending:
`draft → queued → sending → sent | failed | needsConfirmation` (§22).

- Transient failures are retried with backoff (2 s doubling, at most 60 s, 5 attempts). Losing connectivity keeps the
  item queued without using up an attempt.
- Items that waited longer than `AppSettings.staleReplyThreshold` go to `needsConfirmation` unless
  `autoSendStaleReplies` is on (off by default).
- **Duplicate protection.** `post.addComment` has no idempotency key (docs/API.md §9.2). Before any re-send, automatic
  or manual, the queue reads up to 3 comment pages and looks for an own comment with the same trimmed text and the same
  parent, created after the item was written (10 minutes of clock skew allowed), that no other sent item has claimed.
  If it finds one, the item is marked sent. If the lookup cannot decide, an automatic retry waits in
  `needsConfirmation`; an explicit user retry sends.
- A send interrupted by an app kill goes to `needsConfirmation`. When retries are used up after errors that do not
  prove a rejection (timeouts, lost connections, 5xx), the item also goes to `needsConfirmation`; 4xx answers mark it
  `failed`.
- When FANBOX does not return the new comment's id, the item stays visible as sent and is matched to the real comment
  by a thread refresh, so no provisional comment row is stored.
- Items that need a decision are shown in the 送信キュー (send queue) screen, reachable from a banner on every tab and
  from the inbox. Replies written from a notification get a local notice when they need attention.
- Queued replies are flushed at launch, on polling ticks and scene activation, and before background refresh and
  silent push work (§3.3).

## Creator Mode send and upload flow

`DraftService.send` and `UploadQueue` (`Core/Sync/CreatorTools.swift`) turn a local `Draft` into a FANBOX post. What a
data source can write natively is declared up front in `DraftCapabilities` (`Core/Sync/CreatorCapabilities.swift`;
FANBOX: `.fanbox` in `Fanbox/Adapter/FanboxUploadForm.swift`), so `DraftSendPlanner` can badge blocks, check the
upload limits and explain the send in the confirmation before any request.

FANBOX stores images, files and link cards **into an existing post** (`post.addImage` / `post.addFile` /
`post.addUrlEmbed`, docs/API.md §15; `uploadsNeedPost`). A send runs:

1. **Plan** (no request): title, tags, block kinds the post type can hold, upload limits (images jpg / png / gif ≤ 50 MB,
   attachments ≤ 300 MB from FANBOX's extension list), http(s) link cards of at most 2048 characters, and (in
   `DraftService`) that every file still to upload still exists locally. Blockers and warnings stop the send here, before
   a FANBOX draft is created.
2. **Existing post:** `post.getEditable` first; a revision newer than `Draft.remoteUpdatedAt` (edited elsewhere) or a
   changed status stops the send. The revision just checked becomes the send's baseline.
3. **New post with media or link cards:** `createEmptyPost` (`post.create`, interactiveWrite) and the new id is saved to
   `Draft.remotePostID` **before** anything is uploaded, then the new post is read once for its revision (the baseline).
   A retry therefore updates the same post; there is never a second `post.create`, and an edit of that FANBOX draft in
   the web editor between retries is detected.
4. **Uploads:** `UploadQueue` runs one `UploadJob` at a time in block order at `foregroundMedia`, so comment POSTs
   (`interactiveWrite`) preempt them (SPEC §29). Each job uploads `uploadImage/uploadFile(fileURL:postID:...)` against
   `remotePostID`, from a per-job staging link that carries the block's display name (FANBOX shows an attachment's
   name). The result (`RemoteUploadResult`: id, URLs, size, and the post it belongs to) is written to the job and the
   block (`remoteMediaID`, `remoteMediaJSON`). Completed jobs are never re-sent; `retryFailed` re-queues failed jobs
   only; offline leaves jobs queued. A job of a new post that has no FANBOX id yet is paused with
   `UploadQueue.awaitingPostMessage` (the upload button explains this) and resumed by the send after step 3. A job the app
   could never save into its post (the draft has a `nativeUpdateBlocker`, or the post type cannot hold the block kind) is
   paused, not uploaded, so no orphan asset is left on FANBOX. Outside a send (upload button, connectivity auto-start) the
   queue checks the post's revision itself once per run (newer than the baseline → the draft's jobs are paused with
   `UploadQueue.conflictMessage`) and adopts the revision after each upload. The staging link is made and removed inside
   the upload task, off the main actor.
5. **Link cards:** each new URL block is registered with `addURLEmbed` (interactiveWrite); a registered card keeps its
   id and is never registered again. An edited URL clears the id, so the new URL is registered on the next send.
6. **Save:** `post.update` through `FanboxRemoteDataSource.updatePost`, which re-reads the post and accepts only ids that
   are already on it or were stored into this very post (`RemoteDraftBlock.media.postID`). Articles get the blocks array
   with `image` / `file` / `url_embed` blocks by id in block order; image- and file-type posts get `{text, images}` /
   `{text, files}` with the full objects. `imageMap` / `fileMap` / `urlEmbedMap` and `coverImage` are never sent. `tags`
   is one field holding the JSON array (`[]` included), and taking a published post down sends `status=archived`, as the
   web editor does (`FanboxPostUpdateForm`).

On any failure the local draft stays intact with `lastError`, together with `remotePostID` and every completed media
id; the next send continues from where it stopped. When the failed send had written into the post (uploads, link cards,
a failed save), the post is re-read and its revision becomes the baseline, so the retry does not take the app's own
writes for an edit made elsewhere (whether FANBOX's add calls bump `updatedAt` is unknown). A failure after a FANBOX
draft was created always says so in `lastError`. New embed blocks, which have no add endpoint, are left out of the
save and handed to the account web editor (text-first send with a checklist, SPEC §40); a new post with such items is
saved as a FANBOX draft, never published unfinished.

**CSRF and temporary files (SPEC §38 / §39).** Every multipart write (`post.update`, `post.addImage`, `post.addFile`,
`post.addUrlEmbed`) carries the token in its `tt` field, as FANBOX's web editor does, and the transport also adds the
`X-CSRF-Token` header for `requiresCSRF` endpoints. `FanboxAPIClient.sendMultipart` takes a form builder
(`(csrfToken) -> MultipartFormData`): field-only forms are encoded in memory; image and file forms are sent as a streamed
body (`MultipartFormData.streamedBody` → `HTTPClient.upload(_:streamedBody:...)`: `AccountHTTPClient` uses
`uploadTask(withStreamedRequest:)` with `Content-Length`, and `HTTPBodyStreamProducer` writes the in-memory parts and the
file into a bound stream pair on its own thread). No body file is written. A missing token is fetched first; a 400 / 403
answer triggers one token refresh, and the form is rebuilt with the refreshed token and sent once more only when the
refreshed token differs from the one sent.

The demo data source (`.demo` capabilities) runs the same create → upload → register → save flow against `DemoWorld`,
with every block kind native; file names and URLs containing "fail" fail so the retry path can be tried.

## Web sessions

- `AccountWebSessionView` (`Core/Web/WebBridgePresenter.swift`, presented by the `WebBridgePresenter` modifier) shows
  `AccountWebView` for one account with a banner naming it, and inspects every FANBOX page that finishes loading
  (identity, cookie refresh).
- Several destination URLs are unverified (docs/API.md §20). When the first main-frame response of the requested page
  is 404 or 410, `AccountWebController` loads the next page of `WebDestination.fallbackSteps`
  (`Core/Web/WebDestination+Fallback.swift`) and shows a banner. Each chain ends at a page the research marked verified.
  Payment sessions also offer these pages by hand ("ページが表示されない場合" (if the page does not appear)). `.login`
  has no fallback step. (`WebDestination.fallbacks` in `WebBridge.swift` is a second, older list. It is passed to
  `AccountWebView` and stored by `AccountWebCoordinator`, but only tests call its lookup, so it has no effect in the
  app.)
- After a payment session, `PaymentResyncScheduler` syncs supports at once (`.afterWrite`). For plan, creator and
  supporting-plan pages it checks again 1, 5 and 15 minutes later while the app is alive, and stops at the first check
  that observes a change.
- After the web post editor or post management was used, the managed post list is synced again.

## Media and offline library

- `MediaService` (`Core/Media/MediaService.swift`) loads images in stages (thumbnail → display → original, §6) and asks
  `MediaPolicy` before any fetch. Evictable files live under `Caches/Media/<variant>/`; pinned (saved) files live under
  `Application Support/OfflineMedia/<variant>/`, outside Caches and excluded from backup (`MediaCache.swift`).
- Eviction order (§32): unpinned → old (not used for 30 days) → original → display → thumbnail. Text is never evicted.
- `OfflineLibraryService` saves a post, the latest N posts of a creator, or (optionally) every viewed post, and pins
  their media. A post counts as saved only when its body text is local. It never crawls history (§31).
- `MediaPrefetcher` prefetches thumbnails of new timeline posts after a foreground sync and notification media after
  the text is ready. It never prefetches originals, video or attachments, and never runs in a background launch.

## Research Mode and API Inspector

- Every request is recorded as one redacted `ResearchEntry` by the transport that sent it (`AccountHTTPClient` or
  `WebFetchHostPool`, with the transport named). `RoutingHTTPClient` and the web transport add notes (edge blocks,
  fallbacks, unavailable pages). `AccountWebView` records main-frame navigations. Sync failures and undecodable 2xx
  responses are recorded as events.
- `ResearchRecorder` (`Fanbox/Research/ResearchRecorder.swift`) redacts every field again, keeps at most 3,000
  `ResearchLog` rows, and stores bodies only while Research Mode is on.
- `SchemaInspector` compares each JSON response with the fields the DTO knows and updates `APISchemaSnapshot`
  (known / observed / new / missing per endpoint and object path). Decoders ignore unknown fields, so a new field is
  reported, not fatal (§37).
- The UI lives in `Features/Settings/Research/` and `Core/Web/WebTransportResearchSection.swift`: Requests, Responses,
  Navigation and Sync / Errors lists; a detail screen (HTTP status, endpoint, method, safe response body, headers,
  account, timestamp, §44); the API schema list with "New" badges; account, sync, support and scheduler state; the
  通信経路 (transport) section with the Automatic / Native only / WebView only switch, the cooldown, breakers and
  per-endpoint preferences; and, in debug builds, the demo tools (`ResearchDemoTools`). Every displayed string passes
  through `ResearchLogFormatter.safe`. Logs can be cleared and exported as redacted text.

## Module and file map

| Path | Contents |
|---|---|
| `App/` | `FANBOXClientApp` (entry, app delegate, BG task registration), `AppEnvironment`, `AppRouter` (tabs, `AppRoute`, launch arguments), `AppSettings` (UserDefaults, non-secret), `RootView` |
| `Core/Models/` | SwiftData `@Model` classes, `DomainEnums`, `RemoteModels` (Remote* values, `RemoteError`) |
| `Core/Database/` | `PersistenceController` (store location, protection, recovery), `LocalStore` (+ upserts, managed posts), fetch descriptors, `SearchService` |
| `Core/Network/` | `HTTPClient`, `RoutingHTTPClient` (+ `TransportRouter`, `TransportPreferences`), `RateGate`, `EdgeBlockDetector`, `AccountHTTPClient`, `HTTPTransferDelegate`, `NetworkScheduler`, `RequestContext`, `NetworkPolicy` (`MediaPolicy`), `NetworkModeController`, `FanboxHostPolicy` |
| `Core/Authentication/` | `AccountService`, `CredentialStore` / `SessionCredential`, `SessionExpiryNotifier` |
| `Core/Sync/` | `SyncEngine`, `SyncCoordinator` + `BackgroundRefresh`, `ReplyQueue`, `RemoteDataSource`, `FanboxRepository`, `AccountSelector`, creator tools (`CreatorTools`: `UploadQueue`, `DraftService`; `DraftSendPlan`, `DraftPostMapping`, `DraftMediaStore`, `CreatorCapabilities`) |
| `Core/Notifications/` | `NotificationService`, `NotificationCommentResolver`, `RemoteRelay` |
| `Core/Media/` | `MediaService`, `MediaCache` (file layout, eviction), `MediaPrefetcher`, `OfflineLibraryService`, `ImageDownsampler`, `DemoMediaRenderer` |
| `Core/Payments/` | `SupportAnalyzer`, `PaymentResolution` (profile per support line, account defaults), `PaymentProfileValidator`, `PaymentResync`, support stop rules, next charge window and texts |
| `Core/Security/` | `SecretRedactor`, `KeychainStore`, `AppLog` |
| `Core/Web/` | `WebBridge` (`WebDestination`), `WebDestination+Fallback`, `WebBridgePresenter` (`AccountWebSessionView`), `AccountWebView`, `WebFetchHost` (`WebFetchHostPool`), `WebSessionStore`, `WebPageMetadata`, `WebTransportResearchSection` |
| `Fanbox/API`, `Fanbox/DTO`, `Fanbox/Adapter` | FANBOX endpoints, multipart forms, lenient DTOs, mapping to Remote*, `post.update` form, media upload forms and limits (`FanboxUploadForm`) |
| `Fanbox/Demo/` | `DemoRemoteDataSource`, `DemoWorld` and fixtures for demo accounts |
| `Fanbox/Research/` | `ResearchRecorder`, `SchemaInspector` |
| `Features/Home` | unified timeline, post detail, comment threads |
| `Features/Creator` | creator list and creator detail (merged over accounts) |
| `Features/Support` | support dashboard, per-creator / per-account views, history, payment profiles, payment web flow |
| `Features/CreatorMode` | dashboard, posts, drafts and editor, web hand-off, comments, fans, plans |
| `Features/Notifications` | notification inbox, newsletters, reply queue |
| `Features/Library` | offline library, local search, tags |
| `Features/Settings` | settings sheet, accounts, network mode, notifications and relay, cache, Research Mode, legal |
| `UI/` | shared components (`AccountBadge`, `SyncStatusBanner`, `EmptyStateView`, `PillLabel`, `RemoteImageView`, `ImageViewer`, `AccountReloginBanner`, `SessionEdgeBlockNotice`) |

## Testing

Unit tests are hosted in the app (`FANBOXClientTests/<Module>/`). They use
`PersistenceController.makeContainer(inMemory: true)`, `AppEnvironment.preview(seedDemo:)`, `InMemoryCredentialStore`,
per-module fake `RemoteDataSource` implementations and `URLProtocol` stubs for the transport, so they never reach
FANBOX. `RateGate` and the payment resync run on injected clocks. `FANBOXClientUITests` launches the app with
`-uiTesting -demoData`: a smoke test and a screen tour that opens every screen with demo data. Reports captured with
Research Mode → Live API チェック go into `FANBOXClientTests/Research/LiveReports/`, where `LiveContractTests` decodes
them with the app's decoders.
