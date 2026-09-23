# Architecture

This document describes how FANBOX Personal Client is put together. The requirements are in [SPEC.md](../SPEC.md);
section numbers below (§n) refer to it.

## Goals that shape the design

1. **Local data first** (§1, §3.1). Every main screen renders from SwiftData. Nothing waits for the network before it
   shows something.
2. **Text before media** (§29, §46). Notifications, comments and post text are fetched and sent before images, video
   or attachments, including on a 128 kbps connection.
3. **Many accounts, one view** (§3.2, §46). Each account has an isolated session. Data seen by several accounts is
   merged into one row.
4. **No mass collection** (§3.7). Sync reads the newest items and stops at the first known one.

## Layers

```text
+--------------------------------------------------------------------------------------+
| SwiftUI views (Features/*)                                                           |
|   render SwiftData rows with @Query; start refreshes in .task / .refreshable          |
|   never see endpoints, DTOs or JSON (§43)                                            |
+--------------------------------------------------------------------------------------+
| Services / use cases (Core/*, reached through AppEnvironment)                        |
|   SyncEngine, SyncCoordinator, ReplyQueue, NotificationService, MediaService,        |
|   OfflineLibraryService, AccountService, WebBridge, UploadQueue, DraftService,       |
|   SearchService, SupportAnalyzer, AccountSelector                                    |
+--------------------------------------------------------------------------------------+
| Repository                                                                           |
|   LocalStore (LocalDataSource)          RemoteDataSource (protocol)                   |
|   SwiftData main context,               RemoteDataSourceProvider picks per account:  |
|   the ONLY writer of normalized data      - FanboxRemoteDataSource (FanboxAdapter)   |
|                                           - DemoRemoteDataSource (offline fixtures)  |
+--------------------------------------------------------------------------------------+
| FANBOX access (Fanbox/*, Core/Network/*)                                             |
|   FanboxAPIClient -> HTTPClient (AccountHTTPClient) -> NetworkScheduler -> URLSession |
|   DTOs are decoded leniently; SchemaInspector records unknown / missing fields        |
+--------------------------------------------------------------------------------------+
| FANBOX API (api.fanbox.cc) and web (www.fanbox.cc) in the account-aware WKWebView    |
+--------------------------------------------------------------------------------------+
```

- `Remote*` value types (`Core/Models/RemoteModels.swift`) are the boundary between the FANBOX adapter and the rest of
  the app. When the FANBOX API changes, the fix belongs in `Fanbox/API`, `Fanbox/DTO` or `Fanbox/Adapter` (§43).
- `DefaultFanboxRepository` (`Core/Sync/FanboxRepository.swift`) implements the §43 repository façade on top of
  `LocalStore` and `SyncEngine` (local-first reads; an error only when nothing is cached). The notification pipeline
  reads post text through it; most screens still use `@Query` plus the services directly.

### Dependency container

`AppEnvironment` (`App/AppEnvironment.swift`) creates every service once and wires the callbacks between them:

- `SyncEngine.onNewNotificationEvents` → `NotificationService.process(newEventIDs:)`
- `ReplyQueue.onAttentionNeeded` → `NotificationService.handleReplyAttention(itemID:)` (notice for notification replies)
- `SyncCoordinator.notifications` → failed-prefetch retry and badge refresh when the app becomes active
- `NotificationService.mediaPrefetcher` → `MediaService.load` (Priority 2 avatars / thumbnails, still gated by `MediaPolicy`)
- `NetworkModeController.onConnectivityRestored` → `ReplyQueue.handleConnectivityRestored()`
- `WebBridge.onDismiss` after a payment flow → `SyncEngine.sync(.supports, …, reason: .afterWrite)`

Views read it with `@Environment(AppEnvironment.self)`. `AppEnvironment.live()` builds the production graph (on-disk
store, Keychain credentials). `AppEnvironment.preview(seedDemo:)` builds an in-memory graph with demo accounts for
previews and tests.

## Local-first flow

```text
App launch
    |
    v
Open SwiftData store (no network)            PersistenceController.makeContainer
    |
    v
First frame from the local DB                RootView -> tabs -> @Query
    |
    v
.task after the first frame                  NetworkModeController.start()
    |                                        NotificationService.configure()
    |                                        SyncCoordinator.start()
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
("同期できませんでした / キャッシュ済みデータを表示しています / 最後の同期: HH:mm", §44). Network errors never delete
cached rows.

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
   │
   ├───< PaymentRecord, NotificationEvent (deduplicated across accounts), Newsletter
   ├───< Fan, CreatorDashboardSnapshot            (creator accounts)
   └───< SyncState (per account / resource / scope)

Draft ───< DraftBlock
Draft ───< UploadJob
Media, MediaCacheEntry                            (media file cache bookkeeping)
ResearchLog, APISchemaSnapshot                    (Research Mode / API Inspector)
```

- A post is stored once (`Post.postID` is unique). Per-account visibility lives in `PostAccess`.
- A notification seen by several accounts is one `NotificationEvent` whose id is an account-independent dedupe key
  (`NotificationEvent.dedupeKey`), with `accountIDs` listing every receiver.
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
  shared while it is running.
- **Plans.** `syncAll` (launch, pull to refresh): notifications, supports, timeline, supporting timeline, creators,
  plus dashboard, creator comments and fans for creator accounts. `syncLightweight` (background, silent push):
  notifications, supports, timeline.
- **Priority by reason.** User-initiated work runs as `interactiveRead`; notification detection as
  `notificationPrefetch`; launch, polling and background work as `backgroundSync`. Notification listings are never
  below `notificationPrefetch`.
- **Errors.** Mapped to `RemoteError`, stored in `SyncState.error`. `.unauthorized` marks the account session as
  expired. Cached data stays.
- **Account choice.** Post bodies use `AccountSelector` (§8: cached → can view → valid session → higher plan → main
  account). If the chosen account only gets a restricted body, other accounts are tried.

`SyncCoordinator` (`Core/Sync/SyncCoordinator.swift`) decides when to sync: after the first frame, on foreground
polling (`AppSettings.foregroundPollingInterval`, never below 15 s; notifications every tick, newest timeline page every
fifth tick), when the scene becomes active, on pull to refresh, and from `BGAppRefreshTask` / `BGProcessingTask`
(`BackgroundRefresh`). The maintenance task enforces the cache size and prunes Research logs older than 14 days.

## Network scheduler and modes

Every HTTP request goes through `NetworkScheduler.run(priority, label:operation:)` (`Core/Network/NetworkScheduler.swift`).
Callers set the priority with the task-local `RequestContext.$priority`.

| Priority | Value | Typical use |
|---|---:|---|
| interactiveWrite | 100 | posting a comment / reply, likes, uploads started by the user |
| interactiveRead | 90 | opening a post, pull to refresh |
| notificationPrefetch | 80 | text of a newly detected notification |
| foregroundMedia | 50 | images on screen |
| backgroundSync | 20 | launch / polling / background sync |
| mediaPrefetch | 5 | offline saving, image prefetch |

Interactive requests are admitted at once. While any interactive or notification request is in flight, registered
media transfers are suspended and resumed afterwards. The effective mode (Automatic / Normal / Low Data / Extreme /
Offline) comes from `NetworkModeController` and `MediaPolicy`. See [NETWORK_MODES.md](NETWORK_MODES.md).

## Accounts and sessions

- `AccountService` (`Core/Authentication/AccountService.swift`) adds accounts through a login in the account-aware web
  view, validates sessions, removes accounts and manages the main account.
- `WebSessionStore` gives each account its own `WKWebsiteDataStore(forIdentifier: Account.webProfileID)`.
- `CredentialStore` keeps each account's cookies, CSRF token and user agent as one Keychain item.
- `AccountHTTPClient` keeps one ephemeral `URLSession` per account and attaches that account's cookies itself, only for
  fanbox.cc / pixiv.net / pximg.net (`FanboxHostPolicy`).
- `WebBridge.openWeb(account:destination:purpose:)` opens `AccountWebView` for features that stay on the web
  (payment, some creator tools, fallbacks) (§14, §40).

Details: [SECURITY.md](SECURITY.md).

## Notification pipeline

```text
Detection                       Prefetch (text first)              Local DB           iOS
-----------------------------   --------------------------------   ----------------   ---------------------
launch refresh                  NotificationService.process        NotificationEvent  UNNotificationRequest
foreground polling      ──>     highest priority first:     ──>    Post / Comment ──> (title + body from
BGAppRefreshTask                 comment + thread,                  Newsletter          the local DB)
silent push (optional relay)     post title + body,                 Support                 |
                                 newsletter body,                                           v
                                 support metadata                                    tap / inline reply
                                (RequestPriority.notificationPrefetch)                     |
                                                                                           v
                                                               NotificationService.open: local render,
                                                               no HTTP wait; reply -> ReplyQueue
```

- New events come from `SyncEngine` (notifications resource) and are deduplicated across accounts. FANBOX comment
  bells carry no comment id, so the same comment seen by two accounts is matched by post, text, author and time.
- Automatic polling asks `bell.countUnread` first and lists `bell.list` only when the count changed or 15 minutes
  passed; `newsletter.list` is polled at most every 10 minutes. Expired sessions are not polled.
- Derived events (docs/API.md §18.8 B): 支援状態変化 from the supporting-plan diff, 決済要確認 from `hasUnpaidPayments`,
  `payment.listUnpaid` or a plan that disappears on the 1st–5th, 新規支援 from the fan-list diff. The first sync of each
  source is a silent baseline, and the texts state observed facts only (§15).
- Prefetch follows the §24.2 table (`NotificationEventType.prefetchTarget`) and records `prefetchState`. For comment
  events the commented comment is resolved from the thread (`NotificationCommentResolver`). After the text, avatars and
  thumbnails are prefetched (§25 Priority 2). Failed or interrupted prefetches are retried when the app becomes active.
- The iOS notification is posted after the prefetch, so its text and the screen behind it are already local. Critical
  events use `.timeSensitive` only when the Time Sensitive entitlement is available; otherwise `.active`.
- Inline replies are queued in `ReplyQueue` first (they work offline) and are sent as `interactiveWrite`, threaded under
  the resolved comment. If the comment cannot be identified, the text is kept as a draft and a notice asks the user to
  choose the target in the thread; a reply is never turned into a top-level comment.
- Inbox: read events older than 90 days are pruned, and remote items older than that are not re-imported.
- The optional APNs relay only wakes the app; see [NOTIFICATION_RELAY.md](NOTIFICATION_RELAY.md).

## Reply queue

`ReplyQueue` (`Core/Sync/ReplyQueue.swift`) stores every comment / reply as an `OutgoingComment` before sending:
`draft → queued → sending → sent | failed | needsConfirmation` (§22). Short outages are retried with backoff. Items that
waited longer than `AppSettings.staleReplyThreshold` go to `needsConfirmation` unless `autoSendStaleReplies` is on
(off by default). A send interrupted by an app kill also asks for confirmation, to avoid duplicate comments.
`post.addComment` has no idempotency key, so before any re-send (automatic or manual) the thread is re-read and an own
comment with the same text and parent is taken as the earlier send (docs/API.md §9.2); when that check is not possible,
the item waits in `needsConfirmation`. Items that need a decision are shown in the 送信キュー screen, reachable from a
banner on every tab and from the inbox. Queued replies are flushed before the launch / foreground refresh (§3.3).

## Media and offline library

- `MediaService` (`Core/Media/MediaService.swift`) loads images in stages (thumbnail → display → original, §6) and asks
  `MediaPolicy` before any fetch. Files live under `Caches/Media/<variant>/` (`MediaCache.swift`).
- Eviction order (§32): unpinned → old (not used for 30 days) → original → display → thumbnail. Text is never evicted.
- `OfflineLibraryService` saves a post, the latest N posts of a creator, or (optionally) every viewed post, and pins
  their media. It never crawls history (§31).

## Research Mode and API Inspector

- `AccountHTTPClient` records one `ResearchEntry` per request; `AccountWebView` records main-frame navigations.
  `ResearchRecorder` (`Fanbox/Research/ResearchRecorder.swift`) redacts every field again, keeps at most 3,000
  `ResearchLog` rows, and stores response bodies only while Research Mode is on.
- `SchemaInspector` compares each JSON response with the fields the DTO knows and updates `APISchemaSnapshot`
  (known / observed / new / missing per endpoint and object path). Decoders ignore unknown fields, so a new field is
  reported, not fatal (§37).
- The UI lives in `Features/Settings/Research/`: request, response, navigation and event lists, a detail screen
  (HTTP status, endpoint, method, safe response body, headers, account, timestamp — §44), the API schema list with
  "New" badges, account / sync state, support state, and scheduler state. Every displayed string passes through
  `ResearchLogFormatter.safe`, which applies `SecretRedactor` once more plus a display-side pass. Logs can be cleared
  and exported as redacted text.

## Module and file map

| Path | Contents |
|---|---|
| `App/` | `FANBOXClientApp` (entry, app delegate, BG task registration), `AppEnvironment`, `AppRouter` (tabs, `AppRoute`), `AppSettings` (UserDefaults, non-secret), `RootView` |
| `Core/Models/` | SwiftData `@Model` classes, `DomainEnums`, `RemoteModels` (Remote* values, `RemoteError`) |
| `Core/Database/` | `PersistenceController`, `LocalStore` (+ upserts), fetch descriptors, `SearchService` |
| `Core/Network/` | `HTTPClient`, `AccountHTTPClient`, `NetworkScheduler`, `RequestContext`, `NetworkPolicy` (`MediaPolicy`), `NetworkModeController`, `FanboxHostPolicy` |
| `Core/Authentication/` | `AccountService`, `CredentialStore` / `SessionCredential` |
| `Core/Sync/` | `SyncEngine`, `SyncCoordinator` + `BackgroundRefresh`, `ReplyQueue`, `RemoteDataSource`, `FanboxRepository`, `AccountSelector`, creator tools (`UploadQueue`, `DraftService`) |
| `Core/Notifications/` | `NotificationService`, `RemoteRelay` |
| `Core/Media/` | `MediaService`, `MediaCache` (file layout, eviction), `OfflineLibraryService`, image downsampling |
| `Core/Payments/` | `SupportAnalyzer`, `PaymentProfileValidator` |
| `Core/Security/` | `SecretRedactor`, `KeychainStore`, `AppLog` |
| `Core/Web/` | `WebBridge`, `WebBridgePresenter`, `AccountWebView`, `WebSessionStore`, `WebPageMetadata` |
| `Fanbox/API`, `Fanbox/DTO`, `Fanbox/Adapter` | FANBOX endpoints, lenient DTOs, mapping to Remote* |
| `Fanbox/Demo/` | `DemoRemoteDataSource` and fixtures for demo accounts |
| `Fanbox/Research/` | `ResearchRecorder`, `SchemaInspector` |
| `Features/Home` | unified timeline, post detail, comment threads |
| `Features/Creator` | creator list and creator detail (merged over accounts) |
| `Features/Support` | support dashboard, per-creator / per-account views, history, payment profiles, payment web flow |
| `Features/CreatorMode` | dashboard, posts, drafts and editor, comments, fans, plans |
| `Features/Notifications` | notification inbox, newsletters |
| `Features/Library` | offline library, local search, tags |
| `Features/Settings` | settings sheet, accounts, network mode, notifications and relay, cache, Research Mode, legal |
| `UI/` | shared components (`AccountBadge`, `SyncStatusBanner`, `EmptyStateView`, `PillLabel`, `RemoteImageView`, `ImageViewer`) |

## Testing

Unit tests are hosted in the app (`FANBOXClientTests/<Module>/`). They use
`PersistenceController.makeContainer(inMemory: true)`, `AppEnvironment.preview(seedDemo:)`, `InMemoryCredentialStore`
and per-module fake `RemoteDataSource` implementations, so they never reach FANBOX. `FANBOXClientUITests` launches the
app with `-uiTesting -demoData`.
