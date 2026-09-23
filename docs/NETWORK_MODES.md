# Network Modes and Request Priorities

The app is designed to stay usable on a 128 kbps connection ([SPEC.md](../SPEC.md) §3.4). Two mechanisms do this:
**network modes** decide which media may be fetched at all, and the **network scheduler** decides which request goes
first.

Code: `Core/Network/NetworkPolicy.swift` (`NetworkModePreference`, `NetworkMode`, `MediaPolicy`),
`Core/Network/NetworkModeController.swift`, `Core/Network/NetworkScheduler.swift`, `Core/Network/RequestContext.swift`.
Settings UI: Settings → 通信モード (`Features/Settings/NetworkModeSettingsView.swift`).

## Modes

| Mode | Summary |
|---|---|
| Automatic | Chosen from the `NWPathMonitor` path: no usable path → **Offline**; iOS Low Data Mode (constrained path) → **Low Data**; otherwise → **Normal**. A cellular (expensive) path alone does not change the mode. |
| Normal | Text, thumbnails and display images load as you browse; prefetch is on. |
| Low Data | Text and thumbnails load; originals load on tap; no original-image or video prefetch. |
| Extreme | Only JSON / text loads by itself. Images, audio, video and files load only when tapped. Thumbnails are optional (setting). No prefetch. |
| Offline | No network requests at all. Cached text and media are still shown; drafts and replies are saved locally. |

Carriers can throttle speed without iOS reporting Low Data Mode, so Extreme is always available as a manual choice
(§30).

## Behavior table

What happens to each kind of content, as decided by `MediaPolicy.decide(kind:variant:trigger:policy:)`. "Tap" means a
"tap to load" placeholder is shown and the item loads only when tapped. The table assumes Wi-Fi; see the notes for
other paths. Already cached files are always shown, in every mode.

| Content | Normal | Low Data | Extreme | Offline |
|---|---|---|---|---|
| Text / JSON (posts, comments, notifications, supports) | ON | ON | ON | OFF |
| Thumbnail | ON | ON | Tap (ON with "Extreme でも Thumbnail を表示") | OFF |
| Display image | ON | ON | Tap | OFF |
| Original image | ON | Tap | Tap | OFF |
| Video | Tap | Tap | Tap | OFF |
| Audio / file | Tap | Tap | Tap | OFF |
| Image prefetch (thumbnail / display) | ON | ON | OFF | OFF |
| Original image prefetch | ON (Wi-Fi only) | OFF | OFF | OFF |
| Video / audio / file prefetch | ON | OFF | OFF | OFF |
| Loading after a tap | ON | ON | ON | OFF |

Notes:

- **"メディアの先読みは Wi-Fi のときだけ"** (`AppSettings.mediaPrefetchWiFiOnly`, on by default, §35) blocks every
  media prefetch while the device is not on Wi-Fi, in every mode.
- Original images are never prefetched off Wi-Fi, even in Normal mode.
- Prefetch covers offline saving, notification thumbnails and background work. Background refresh fetches text only
  (§35).
- Settings → 通信モード → 各モードの説明 shows this table. It is computed from `MediaPolicy` at run time, so it always
  matches the code.

## Request priorities

Every HTTP request runs through `NetworkScheduler.run(_:label:operation:)`. The caller sets the class with
`RequestContext.$priority.withValue(...)`.

| Priority | Value | Used for | Admission |
|---|---:|---|---|
| interactiveWrite | 100 | posting comments / replies, other user-initiated writes | immediate, never limited |
| interactiveRead | 90 | opening a post, pull to refresh, on-demand reads | immediate, never limited |
| notificationPrefetch | 80 | notification listings and the text of new notifications | up to 3 at once |
| foregroundMedia | 50 | images visible on screen, taps to load | up to 3 at once |
| backgroundSync | 20 | launch sync, foreground polling, background refresh | up to 2 at once |
| mediaPrefetch | 5 | offline saving, prefetch | 1 at a time |

- At most 6 non-interactive requests run at once. Waiting requests are admitted by priority, then in arrival order.
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

- In Offline mode every request fails at once with `RemoteError.offline`, and requests still waiting are failed when
  the mode switches to Offline. Replies stay in the local queue and are sent when the connection returns.
- `URLSessionTask.priority` is also set from the class (`RequestPriority.urlSessionTaskPriority`: from
  `URLSessionTask.highPriority` for interactiveWrite down to `URLSessionTask.lowPriority` for mediaPrefetch).

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
