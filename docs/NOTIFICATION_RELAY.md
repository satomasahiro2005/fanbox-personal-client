# Optional APNs Relay — Design

Status: **design document.** The client-side hooks are in the app. The relay server is **not part of v1.0**, and the
app does not yet send its device token to a relay (see [What is implemented](#what-is-implemented-in-v10)). The
silent-push handler has never received a real push, because the app target has no `aps-environment` entitlement; only
its result mapping is unit-tested. Like the rest of the FANBOX integration, the fetch it triggers has not been
exercised against the live service.

Related: [SPEC.md](../SPEC.md) §24–§28, [ARCHITECTURE.md](ARCHITECTURE.md#notification-pipeline),
[SECURITY.md](SECURITY.md).

## Why a relay

FANBOX has no public push API. Without a server, the app detects events in three ways:

| Path | When it runs | Limit |
|---|---|---|
| Launch refresh | Every app launch | Only when the user opens the app |
| Foreground polling | While the app is in the foreground (interval in Settings, 30 s – 15 min) | Stops in the background |
| Background App Refresh | `BGAppRefreshTask`, requested every 15 minutes or later | iOS decides when, or whether, it runs |

A relay adds one more path: a silent push that wakes the app soon after FANBOX sends its own notification e-mail.
It stays optional. The three local paths keep working with or without it (§28).

## Constraints

1. **No FANBOX secrets on the server.** The relay never receives cookies, `FANBOXSESSID`, CSRF tokens or passwords, so
   it cannot call FANBOX as the user.
2. **No content on the server.** The relay does not keep post bodies, comments, newsletter text, supporter names or
   payment data. It does not put any of them in a push.
3. **The app fetches directly.** After a push, the app fetches from FANBOX with its own per-account session. The
   visible notification is built on the device from that data.
4. **Optional and off by default** (`AppSettings.remoteRelayEnabled == false`).

## Flow

```text
FANBOX                    Mail                      Private relay                 Apple            iPhone
------                    ----                      -------------                 -----            ------
event (comment, post,     FANBOX official           mail event detection          APNs             silent push
newsletter, support) ──>  notification mail   ──>   - check the sender       ──>  (background ──>  (content-available)
                          to the user's own           is FANBOX                    priority)             |
                          address / alias           - map the recipient alias                            v
                                                      to an opaque account hint                     App direct fetch
                                                    - drop the mail                                 (own session):
                                                    - send content-free push                        notifications ->
                                                                                                    text prefetch ->
                                                                                                    local DB ->
                                                                                                    local notification
```

### 1. Mail event detection

- The user turns on FANBOX e-mail notifications for the events they care about (pixivFANBOX Help Center, "通知設定" (notification settings)).
- Mail reaches the relay by one of two routes, both under the user's control:
  - a mail rule that forwards FANBOX notification mail to an address owned by the relay, or
  - the relay reads a dedicated mailbox (for example over IMAP with an app-specific password that can only read mail).
- The relay only needs three facts from a message: it is from FANBOX, which alias it was addressed to, and that it
  arrived now. It does not parse or store the body. The message is deleted after processing.
- One alias per FANBOX account (for example `me+a@…`, `me+b@…`) lets the relay tell accounts apart without knowing
  who they are.

### 2. Relay state

| Stored | Purpose |
|---|---|
| APNs device token(s) of the user's iPhone | Where to send pushes |
| Opaque account hints (random 128-bit values made by the app) and the mail alias each one belongs to | Which account had activity |
| Hash of the registration secret | Authenticating the app |
| Last push time per hint | Rate limiting |

Never stored: FANBOX cookies or session ids, CSRF tokens, pixiv / FANBOX user ids or names, post or comment text,
newsletter text, supporter or payment data, mail bodies.

### 3. Push payload

```json
{
  "aps": { "content-available": 1 },
  "v": 1,
  "h": "3f6c0e9a4d2b41f8a7c5e1d09b6a2c47"
}
```

- APNs headers: `apns-push-type: background`, `apns-priority: 5`, `apns-topic: ai.nemut.FANBOXClient`.
- No `alert`, `sound` or `badge`. Nothing in the payload is shown to the user.
- `v` is the payload version. `h` is the opaque account hint and is optional. The v1.0 client ignores it and runs a
  lightweight sync for every enabled account; the hint is reserved for syncing one account only.
- The relay should merge bursts, for example at most one push per hint per minute. The app also merges concurrent
  syncs of the same resource.

### 4. App side after a push

`AppDelegate.application(_:didReceiveRemoteNotification:)` → `RemoteRelay.shared.handleSilentPush(environment:)`:

1. If there is no usable network (Offline mode or no path), return `.failed`.
2. `ReplyQueue.flush()` sends queued replies first (§3.3).
3. `SyncEngine.syncLightweightOutcomes(reason: .notification)`: notifications first, then supports and the newest
   timeline page, plus the fan list of creator accounts (at most about every 6 hours), for every enabled account, at
   `notificationPrefetch` priority. Accounts whose session is expired, logged out or quarantined are skipped.
4. New `NotificationEvent`s go through the normal pipeline: text prefetch → local DB → local iOS notification.
5. `ReplyQueue.flush()` runs again for replies queued meanwhile.
6. Return `.newData` (something new was stored), `.failed` (every request failed) or `.noData` to iOS.

The app is in the background during this work, so only the native `URLSession` transport runs; the hidden web view
transport is foreground-only ([ARCHITECTURE.md](ARCHITECTURE.md#transport)). If FANBOX refuses `post.info` to
`URLSession`, the post body of a new-post event cannot be prefetched here. The notification is then posted with the
text of the notification listing, and the prefetch is retried when the app becomes active.

## App ↔ relay protocol (proposed)

All requests use HTTPS. The app accepts only `https://` relay URLs without user info (Settings → 通知 (notifications) → APNs Relay).

| Request | Body | Notes |
|---|---|---|
| `POST /v1/devices` | `{ "token": "<apns hex>", "environment": "production" \| "sandbox", "hints": ["<hint>", …] }` | Register or update. Replaces the hint list. |
| `DELETE /v1/devices/<token>` | — | Called when the user turns the relay off. |
| `POST /v1/hints/rotate` | `{ "token": "<apns hex>", "hints": [...] }` | New hints; old ones stop working. |

Authentication: a random registration secret is created once, entered on both sides, and sent as
`Authorization: Bearer <secret>`. The app would keep it in the Keychain like other secrets; the relay stores only its
hash. The secret authorizes device registration only. It gives no access to FANBOX.

The mapping from mail alias to hint is configured on the relay by the user. The app never tells the relay which
FANBOX account a hint belongs to.

## Failure modes

| Situation | Effect | Handling |
|---|---|---|
| Relay down, mail delayed or filtered | No push | Launch refresh, foreground polling and Background App Refresh still run |
| iOS throttles silent pushes (low power, many pushes, app rarely used) | Push dropped or delayed | Best effort by design; APNs delivery is outside the app's guarantees (§26) |
| User force-quit the app | iOS does not deliver silent pushes until the next launch | Local paths resume at launch |
| Device token changes (restore, reinstall) | Old token is invalid | App re-registers when the relay is on; the relay drops tokens APNs reports as unregistered |
| Session expired for an account | Fetch fails with `.unauthorized` | The account is marked expired; the user signs in again in the web view |
| Duplicate or burst pushes | Extra wake-ups | Relay rate limit plus `SyncEngine` coalescing; nothing is fetched twice at the same time |
| Offline when the push arrives | Nothing to fetch | Returns `.failed`; the next local path catches up |

## Threat model

| Party | What it can learn or do | Mitigation |
|---|---|---|
| Relay operator / compromised relay | Device token, opaque hints, times of FANBOX mail. Can send silent pushes. | No secrets or content to steal. A push only triggers a normal sync with the app's own session. Pushes have no visible content, so fake pushes cannot show fake text. |
| Mail provider | FANBOX notification mail content | Unchanged from normal FANBOX e-mail use; the relay adds nothing. |
| Apple (APNs) | Push metadata and the payload above | The payload contains no content. |
| Network observer | That the app talks to the relay | HTTPS only; the relay URL cannot carry credentials. |
| Someone with the registration secret | Can register their own device to receive silent pushes | They learn only activity timing. Rotate the secret and hints to revoke. |

## What is implemented in v1.0

| Item | Where |
|---|---|
| Settings: enable switch (off by default), https relay URL with validation, registration state, APNs token hint (first 8 hex digits only), explanation of what is and is not sent | `Features/Settings/NotificationSettingsView.swift` (`RemoteRelaySettingsView`), `AppSettings.remoteRelayEnabled` / `remoteRelayURL` |
| APNs registration when the relay is enabled with a valid URL | `RemoteRelaySettingsView`, `RemoteRelay.registerIfEnabled(settings:)` |
| Device token / registration error capture | `AppDelegate` → `RemoteRelay.didRegister(deviceToken:)` / `didFailToRegister(error:)` |
| Silent push handling (direct fetch, reply flush, fetch result) | `AppDelegate.application(_:didReceiveRemoteNotification:)` → `RemoteRelay.handleSilentPush(environment:)` |
| Background mode `remote-notification` | `project.yml` / `Info.plist` |

Not implemented in v1.0:

- the relay server and mail detection,
- sending the device token and hints to the relay (`POST /v1/devices`), the registration secret and hint generation,
- the `aps-environment` entitlement. Push registration fails until it is added to the app target.
