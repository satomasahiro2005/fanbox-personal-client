# Network Modes and Request Priorities

The app is designed to stay usable on a 128 kbps connection ([SPEC.md](../SPEC.md) §3.4). Three mechanisms do this:

- **network modes** decide which media may be fetched at all;
- the **network scheduler** decides which request goes first;
- the **request budget** (`RateGate`) spaces FANBOX API and page requests and pauses them after a 429 or an edge block.

Code: `Core/Network/NetworkPolicy.swift` (`NetworkModePreference`, `NetworkMode`, `MediaPolicy`),
`Core/Network/NetworkModeController.swift`, `Core/Network/NetworkScheduler.swift`, `Core/Network/RequestContext.swift`,
`Core/Network/RateGate.swift`, `Core/Media/MediaPrefetcher.swift`.
Settings UI: Settings → 通信モード (network mode) (`Features/Settings/NetworkModeSettingsView.swift`).

The modes and the scheduler are exercised by unit tests. The request budget's numbers are inferred from third-party
reports ([API.md](API.md) §1.8) and have not been checked against the live service.

## Modes

| Mode | Summary |
|---|---|
| Automatic | Chosen from the `NWPathMonitor` path: no usable path → **Offline**; iOS Low Data Mode (constrained path) → **Low Data**; otherwise → **Normal**. A cellular (expensive) path alone does not change the mode. |
| Normal | Text, thumbnails and display images load as you browse; prefetch is on. |
| Low Data | Text and thumbnails load; originals load on tap; no original-image or video prefetch. |
| Extreme | Only JSON / text loads by itself. Images, audio, video and files load only when tapped. Thumbnails are optional (setting). No prefetch. |
| Offline | No network requests at all, including web views (see [Offline](#offline)). Cached text and media are still shown; drafts and replies are saved locally. |

Carriers can throttle speed without iOS reporting Low Data Mode, so Extreme is always available as a manual choice
(§30).

## Behavior table

What happens to each kind of content, as decided by `MediaPolicy.decide(kind:variant:trigger:policy:)`. "Tap" means a
"tap to load" placeholder is shown and the item loads only when tapped. The table assumes Wi-Fi; see the notes for
other paths. Already cached files are always shown, in every mode.

| Content | Normal | Low Data | Extreme | Offline |
|---|---|---|---|---|
| Text / JSON (posts, comments, notifications, supports) | ON | ON | ON | OFF |
| Thumbnail | ON | ON | Tap (ON with "Extreme でも Thumbnail を表示" (show thumbnails in Extreme)) | OFF |
| Display image | ON | ON | Tap | OFF |
| Original image | ON | Tap | Tap | OFF |
| Video | Tap | Tap | Tap | OFF |
| Audio / file | Tap | Tap | Tap | OFF |
| Image prefetch (thumbnail / display) | ON | ON | OFF | OFF |
| Original image prefetch | ON (Wi-Fi only) | OFF | OFF | OFF |
| Video / audio / file prefetch | ON | OFF | OFF | OFF |
| Loading after a tap | ON | ON | ON | OFF |

Notes:

- **"メディアの先読みは Wi-Fi のときだけ"** (prefetch media only on Wi-Fi; `AppSettings.mediaPrefetchWiFiOnly`, on by
  default, §35) blocks every media prefetch while the device is not on Wi-Fi, in every mode. A path that iOS has not
  reported yet (for example early in a background launch) counts as "not Wi-Fi".
- Original images are never prefetched off Wi-Fi, even in Normal mode.
- Settings → 通信モード → 各モードの説明 (description of each mode) shows this table. It is computed from `MediaPolicy`
  at run time, so it always matches the code.

## What is prefetched

Automatic prefetch goes through `MediaService.load` with the trigger `.prefetch`, so the table above decides, and the
scheduler runs it at `mediaPrefetch`, behind every other request. Explicit saves use the trigger `.manual`.

| Source | What | When |
|---|---|---|
| `MediaPrefetcher`, after a timeline sync | Card cover and creator icon of the newest new posts (at most 12 per sync) | After launch, pull-to-refresh and foreground-polling syncs; never in a background launch |
| `MediaPrefetcher`, after notification text is ready | Actor / creator avatar and post thumbnail for every new event, then up to 3 display images per post | After `NotificationService` has the text; never in a background launch |
| `OfflineLibraryService`, auto-save of viewed posts (off by default) | Display images of a post when it is opened | Prefetch policy |
| `OfflineLibraryService`, "recent N" rules | Media of the posts a rule newly covers | After a foreground timeline / creator sync, with the prefetch policy; "今すぐ保存" (save now) runs as a manual action and includes attachments |
| `OfflineLibraryService`, saving one post | Thumbnails, display images and attachments of the post | When the user saves it; a manual action at foregroundMedia, so it also runs in Extreme (not in Offline) |

`MediaPrefetcher` never prefetches originals, video or attachments. `MediaPrefetcher` and the "recent N" rules do not
run in a background launch (§35). After a notification's text is ready, `NotificationService` also asks for a few
small thumbnails (actor and creator avatars, post cover, recent commenters). That request is not tied to the app
state, only to `MediaPolicy`, so with the default Wi-Fi-only setting it can run during a background refresh only on a
Wi-Fi path that iOS has already reported.

## Request priorities

Every HTTP request runs through `NetworkScheduler.run(_:label:operation:)`: the native `URLSession` transport and the
hidden web view transport alike. The caller sets the class with `RequestContext.$priority.withValue(...)`.

| Priority | Value | Used for | Admission |
|---|---:|---|---|
| interactiveWrite | 100 | posting comments / replies, likes, post create / update | immediate, never limited |
| interactiveRead | 90 | opening a post, pull to refresh, on-demand reads | immediate, never limited |
| notificationPrefetch | 80 | notification listings and the text of new notifications | up to 3 at once |
| foregroundMedia | 50 | images visible on screen, taps to load, media uploads | up to 3 at once |
| backgroundSync | 20 | launch sync, foreground polling, background refresh | up to 2 at once |
| mediaPrefetch | 5 | offline saving, prefetch | 1 at a time |

- At most 6 non-interactive requests run at once (media does not count against this cap for notificationPrefetch).
  Waiting requests are admitted by priority, then smaller media variants first (thumbnail → display → large), then in
  arrival order.
- At most one large media transfer (original, video, audio, attachment, upload) runs at a time, so thumbnails and
  display images keep the other slots.
- While any interactive or notification request is in flight, no new media request is admitted, and registered media
  downloads / uploads (priority ≤ foregroundMedia) are suspended with `URLSessionTask.suspend()`. They resume when the
  text-first work is done:

  ```text
  20 MB original image downloading
      |
      v
  user sends a comment  (interactiveWrite)
      |
      v
  media transfer suspended
      |
      v
  comment POST completes
      |
      v
  media transfer resumed
  ```

- `URLSessionTask.priority` is also set from the class (`RequestPriority.urlSessionTaskPriority`: from
  `URLSessionTask.highPriority` for interactiveWrite down to `URLSessionTask.lowPriority` for mediaPrefetch; large
  media at most 0.3).

## Request budget and the scheduler

`RateGate` and `NetworkScheduler` do different jobs:

- `NetworkScheduler` orders all traffic on the device by priority and keeps text ahead of media. It applies to every
  host.
- `RateGate` limits how fast the app talks to FANBOX. It applies only to api.fanbox.cc and www.fanbox.cc (not to media
  hosts), on both transports, and it is device-wide because Cloudflare limits are most likely per IP address.

`RoutingHTTPClient` calls `RateGate.admit` first and only then hands the request to a transport, which takes a
scheduler slot. A request that waits for its spacing therefore does not hold a slot that text-first work needs.

| Rule | Value |
|---|---|
| `post.info` / `post.getEditable` spacing | 1 s between starts, device-wide, every priority; interactive requests go before queued background ones |
| Other FANBOX calls | 0.2 s between starts, except interactive requests |
| Background budget for `post.info` / `post.getEditable` | 6 starts per 60 s for backgroundSync, notificationPrefetch and mediaPrefetch; a request that would wait more than 30 s fails with `.rateLimited` |
| After a 429 | every FANBOX call fails fast for Retry-After, or 6 minutes without one (at most 1 hour), interactive ones included |
| After an edge block | native: that endpoint on the native transport pauses device-wide for 15 minutes; web view: that account's web view transport pauses for 6 minutes; web view blocks on two accounts within 2 minutes pause every FANBOX call for 6 minutes |

The priority classes above are the same ones `RateGate` uses to tell interactive from background work. See
[ARCHITECTURE.md](ARCHITECTURE.md#transport) for how the transports are chosen.

## Offline

Offline mode (chosen by hand, or Automatic with no usable path) stops all traffic (§30 "ネットワーク通信を完全停止する"
(stop all network communication)):

- `NetworkScheduler` fails every new request at once with `RemoteError.offline`, fails requests still waiting in its
  queue when the mode switches, and cancels registered downloads and uploads. An admitted `interactiveWrite` is left to
  finish, because cancelling it would make its outcome unknown.
- `WebFetchHostPool` closes every hidden transport web view, and `WebFetchHost` cancels any navigation.
- The visible account web view loads nothing. The web session sheet shows an offline state instead of the page (with a
  button to switch back to Automatic when Offline was chosen by hand), stops a running load when the mode switches,
  and cancels every http(s) navigation of the page and its popups.
- `SyncEngine` returns without touching local data. `ReplyQueue` and `UploadQueue` keep their items queued and send
  them when `NetworkModeController.onConnectivityRestored` fires.
- Demo accounts answer `.offline` too, so this behavior can be tried with them.

## Overall order under a slow connection

```text
Notifications
    |
Comments (send and read)
    |
Post text
    |
Support state
    |
Thumbnails
    |
Display images
    |
Original images / video / attachments
```

Images may be slow. Receiving a notification, reading the text and replying must stay fast (§46).
