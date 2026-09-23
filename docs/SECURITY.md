# Security and Sensitive Data

This document maps the storage, isolation and redaction rules of [SPEC.md](../SPEC.md) §3.2, §7, §12, §38, §39 and
§40 to the code that implements them.

Unit tests exercise these rules with in-memory stores, fake data sources and `URLProtocol` stubs. The rules have
not been exercised against the live FANBOX service: no request was sent to fanbox.cc or pixiv.net during development.
In particular, the identity checks rely on the shape of the FANBOX page metadata described in [API.md](API.md) §2.14,
which has not been confirmed by a request from this app.

## Principles

- Session secrets (cookies including `FANBOXSESSID`, CSRF tokens) live only in the Keychain, in memory, and in the
  account's own WebKit data store. They are never written to SwiftData, `UserDefaults`, files, logs or the screen.
- Each account is isolated: separate WebKit store, separate Keychain item, separate `URLSession`, separate hidden
  transport web view.
- A session is stored for, or used as, an account only after its logged-in pixiv user was checked against the account.
- Logout and account removal stop the account's in-flight requests before its secrets are deleted, and late responses
  cannot bring them back.
- Card numbers, security codes, PINs, 3-D Secure credentials and passwords are never stored. Payment happens in the
  FANBOX / pixiv web pages inside the account-aware web view (§14).
- Everything that is logged or shown in Research Mode goes through `SecretRedactor`. There is no exception for debug
  builds (§38).
- iOS Data Protection is applied to every file the app writes that holds user content.

## Sensitive Data Storage Policy

| Data (SPEC §39) | Policy | Where it is stored | Implementation |
|---|---|---|---|
| FANBOX session secret (`FANBOXSESSID` and other session cookies) | Keychain | Generic-password item, service `ai.nemut.FANBOXClient.session`, account `credential.<accountID>`, value = JSON `SessionCredential` | `CredentialStore` (actor) over `KeychainStore`, with an in-memory cache. Accessibility `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: readable by background refresh after the first unlock, never synced or restored to another device. An item is created only for a verified session (a login, or a re-login verified in a web session); cookie, token and user-agent updates from responses change an existing item only. |
| CSRF token | Keychain or memory | Inside the same `SessionCredential` item (`csrfToken`) and the actor's memory. The hidden web view transport keeps its page's token in memory only. | See [CSRF token](#csrf-token). |
| Web cookies | Per-account WebKit store | `WKWebsiteDataStore(forIdentifier: Account.webProfileID)` | `WebSessionStore`. Only fanbox.cc / pixiv.net cookies are copied from the web store into the Keychain credential (`WebCookieScope`), and only after the page's logged-in pixiv user was verified. See [Cookie flow](#cookie-flow-between-the-web-store-and-the-keychain). Logout wipes the store; account removal deletes it. |
| API session | Per-account `URLSession` | Memory only | `AccountHTTPClient`: one ephemeral session per account, no shared cookie storage, no URL cache, no credential storage. Cookies are attached by hand and only for *.fanbox.cc (`FanboxHostPolicy`; pixiv.net cookies stay in the credential for the web store only, pximg.net gets none). Caller-supplied `Cookie` / `X-CSRF-Token` headers are dropped. `Set-Cookie` responses are merged into an EXISTING credential only. |
| Post body, comments, newsletters, creators, supports | SwiftData | `Application Support/Store/FANBOXClient.store` (+ `-wal`, `-shm`) | `PersistenceController`: directory and files use `FileProtectionType.completeUntilFirstUserAuthentication`. See [Store recovery](#store-recovery). |
| Thumbnails and media | File cache | Evictable: `Caches/Media/<variant>/<sha256(url)>.<ext>`. Pinned (saved offline): `Application Support/OfflineMedia/<variant>/…`, excluded from backup. One `MediaCacheEntry` row per file. | `MediaFileCache` / `MediaService`: `completeUntilFirstUserAuthentication`. Never contains text. |
| Draft media | Files | `Application Support/Drafts/<draftID>/`; while a file is uploaded, a hard link under its display name in `Application Support/Drafts/_upload/<jobID>/` | `DraftMediaStore`: `completeUntilFirstUserAuthentication`; ids and names are sanitized so they cannot leave the directory. Upload staging links are removed after each attempt and at launch. |
| Multipart bodies with file parts | Temporary file | `tmp/fanbox-multipart-<uuid>.body` | `MultipartFormData.writeToTemporaryFile`: `FileProtectionType.complete`, deleted right after the request, leftovers deleted at launch. Used by the media uploads (`post.addImage` / `post.addFile`); these bodies never contain the CSRF token (see [CSRF token](#csrf-token)). |
| Card last 4 digits, brand, nickname, payment memo | SwiftData | `PaymentProfile` | Checked by `PaymentProfileValidator` before saving |
| Card number (PAN) | **Never stored** | — | `PaymentProfileValidator` rejects any field with a card-number-like digit run; the app has no card entry form |
| CVC / PIN / expiry / 3-D Secure credential | **Never stored** | — | `PaymentProfileValidator` rejects security-code-like values in the nickname, brand and memo; payment runs in the web view |
| Password | **Never stored** | — | Login happens in `AccountWebView`; the app only captures the resulting cookies |
| User settings | `UserDefaults` | Standard defaults | `AppSettings` holds non-secret values only (modes, intervals, toggles, relay URL). `TransportPreferences` stores endpoint names and dates only. |
| Research logs | SwiftData | `ResearchLog`, `APISchemaSnapshot` | Redacted before insertion and again before display; see below |
| Research log export | Temporary file | `tmp/ResearchExport/FANBOX-Research-<time>.txt` | Written with `.completeFileProtection`; earlier exports are deleted on the next export and when logs are cleared |

`Account` rows hold only non-secret profile data (display name, pixiv / FANBOX user ids, avatar URL, `webProfileID`,
creator id, flags, timestamps).

## CSRF token

- **Source.** The token comes from the `<meta name="metadata">` tag of www.fanbox.cc (docs/API.md §1.4, §2.14). The
  app reads it with `FanboxAPIClient.fetchMetadata` (native), from pages that finish loading in the account web view,
  and from the page of the hidden transport web view.
- **Storage.** Keychain (inside the account's credential) and memory. The hidden transport web view keeps the token of
  its page in memory only (`WebFetchHost.pageCSRFToken`); it is dropped when the page is closed or reloaded (after
  30 minutes). It is never written to SwiftData, `UserDefaults`, files or logs. The Research Mode Account State screen
  shows only whether a token exists.
- **Sending.** The transport adds `X-CSRF-Token` only when the request is marked `requiresCSRF`, and only to fanbox.cc
  hosts (`FanboxRequestHeaders.apply` refuses any other host). When no token is available the request fails with
  `RemoteError.csrfUnavailable` and nothing is sent. The web transport sends `x-csrf-token` from its page, or from the
  credential when the page has none.
- **Refresh.** A missing token is fetched before a CSRF-protected write. When such a write is rejected with 403 or an
  invalid-request error, the token is read again and the write is retried once, only if the token changed.
- **Rotation.** When a response rotates `FANBOXSESSID`, the token of the old session is dropped
  (`SessionCredential.mergeResponseCookies`). The same happens when a browse session brings a new session cookie.
- **`post.update`.** FANBOX takes the token in the multipart field `tt`. That form has no file parts, so it is encoded
  in memory (`MultipartFormData.encodedData`) and sent like any other request. It is never written to a file. In
  Research logs a `multipart/form-data` body is summarized as `<binary N bytes, …>`, so the `tt` value is not recorded.
- **Media uploads.** `post.addImage` / `post.addFile` bodies are streamed from a temporary file, so they carry the token
  ONLY in the `X-CSRF-Token` header the transport adds (the web client's newer request layer does the same; its legacy
  helper uses `tt`, docs/API.md §15.4). `FanboxAPIClient.sendMultipart` refuses a form with file parts that contains a
  `tt` field before anything is written. `post.addUrlEmbed` has no file part and is sent from memory, also without `tt`.
  A rejected upload is retried once after a token refresh with the same token-free body file.

## Cookie flow between the web store and the Keychain

- **Web store → Keychain.** After a verified login, and after a FANBOX page finishes loading in a browse or payment
  session, `AccountService` copies fanbox.cc / pixiv.net cookies and the web view's user agent into the account's
  credential. A different `FANBOXSESSID` without a page naming its user is probed before it replaces the stored one.
- **API response → web store.** When an API response rotates `FANBOXSESSID`, only that cookie is copied into the web
  store (`installAPISessionIntoWeb`). Other cookies set by responses to the native transport, including CDN cookies such
  as `__cf_bm`, are merged into the Keychain credential but not into the web store on this path.
- **Keychain → empty web store.** When a web session opens (or the hidden transport page loads) and the account's web
  store has no FANBOX session, `prepareWebSession` installs the stored credential, and `resetWebSession` does the same
  after clearing a web store. These paths install every fanbox.cc / pixiv.net cookie of the credential. That can include
  CDN cookies the native transport received; `SessionCredential.isEdgeCookie` exists but is not used to filter them.
  Whether this matters on the live service has not been checked.

## Account identity

One pixiv user's session must never end up in another local account (SPEC §3.2 / §7.1 / §40). `AccountService`:

- **Login / re-login.** The logged-in user named by the FANBOX page is compared with the account BEFORE anything is
  stored. The captured session is then probed under a temporary Keychain key (`login-probe-<uuid>`, removed right
  after, and removed at launch if a kill left it behind) and saved for the account only when the user matches and no
  other local account already has that pixiv user. A mismatch or a duplicate never touches the account's credential;
  its web store is cleared and the account's own session is re-installed (a new, unbound placeholder account is
  discarded instead).
- **Browse / payment sessions.** Every FANBOX page that finishes loading is inspected. A page logged in as another
  user stops the session (the page and any popup, such as a PayPal or 3-D Secure window), resets the web store and
  copies nothing. The account detail screen then shows a warning.
- **Hidden web view transport.** The page is used only after its logged-in user matched the account. On a mismatch the
  page is closed and the web store is reset.
- **Session checks and sync (quarantine).** When the `currentUser` check of a stored session (explicit session check or
  the `session` sync resource) names another pixiv user, `quarantineMismatchedSession` sets the account to `.error`
  (shown as "要再ログイン" (re-login required) on the account's session label), revokes its requests, deletes the Keychain
  credential and clears the web store. Sync skips `.error` accounts, the post-body account choice never picks them,
  and a successful sync never clears the state. Only a verified re-login does.
- A session check that fails for any reason other than a 401 (Cloudflare challenge, edge block, FANBOX 403, offline)
  leaves the session state unchanged (`AccountService.sessionState(for:)`).

## Teardown on logout and removal

1. `AccountService.logout` / `remove` first calls `RoutingHTTPClient.revokeSession(accountID:)` (`SessionRevoking`):
   - `AccountHTTPClient.invalidateSession` bumps a per-account epoch and invalidates the account's `URLSession`. A
     response that started before is dropped as `.cancelled` without merging its cookies.
   - `WebFetchHostPool.shutdown(accountID:)` closes the account's hidden web view before its data store is touched.
   - `RateGate.reset(accountID:)` forgets the account's breakers.
2. The Keychain credential is deleted. `CredentialStore.mergeCookies` / `updateCSRFToken` / `updateUserAgent` only
   update an existing item, so a late response cannot re-create it.
3. The web store is cleared (logout: `clearData`, the identifier is kept) or removed (removal: `removeData`). If WebKit
   refuses to delete a store that is still in use, its data is wiped anyway and the deletion is retried later
   (`purgePendingRemovals`).
4. Removal also deletes the account-scoped rows (supports, payments, sync state, fans, dashboard, queued replies) and
   stops its uploads. Downloaded text (posts, comments, newsletters, drafts) is kept without the account id.

A verified login or a new session from the web also revokes the account's requests before the new credential is saved,
so a response that belongs to the old session cannot write into the new one.

## Store recovery

`PersistenceController.makeContainer` opens `Application Support/Store/FANBOXClient.store`. If the store cannot be
opened (for example after a failed migration), the whole `Store` directory is moved aside to
`Application Support/Store-unreadable-<timestamp>/`, never deleted, and a fresh store is created so the app still starts
local-first. The failure is logged as a fault; `PersistenceController.lastRecoveredStoreURL` records the location, but no
screen shows it yet. If the fresh store cannot be created either, `AppEnvironment.live()` falls back to an in-memory store
for that launch. The moved-aside files are not removed automatically.

Keychain credentials of account ids that are no longer in the database (for example after such a recovery) are kept on
purpose, in case the accounts come back; only temporary login-probe credentials are purged at launch.

## Login limitation

Google refuses OAuth sign-in inside embedded web views (`WKWebView`). pixiv accounts that only use "Sign in with
Google" cannot log in through the app; the add-account screen and the login sheet say so. Set a pixiv password first,
then log in with the pixiv ID / e-mail address and that password.

## Payment profile validation

`PaymentProfileValidator.validate(nickname:brand:last4:memo:)` (`Core/Payments/PaymentProfileValidator.swift`) returns
a list of `PaymentProfileIssue` values. The payment profile editor must not save while the list is not empty.

- `last4MustBeFourDigits`: `last4` must be exactly four ASCII digits, or empty.
- `looksLikeCardNumber(field:)`: any field containing a long run of digits (spaces and hyphens ignored) is treated as a
  possible card number.
- `looksLikeSecurityCode(field:)`: text in the nickname, brand or memo that looks like a CVC, PIN or expiry date.
- `nicknameRequired`.

Detection is deliberately cautious: a false positive only blocks saving, while a false negative would persist a secret.

## Redaction

`SecretRedactor` (`Core/Security/SecretRedactor.swift`) is the single place that knows what a secret looks like.
Output uses the SPEC §38 form, for example `Cookie: <REDACTED>`, `FANBOXSESSID: <REDACTED>`,
`X-CSRF-Token: <REDACTED>`. Every entry point is total: it never throws, whatever the input.

| Input | Rule |
|---|---|
| Headers | `Cookie`, `Set-Cookie`, `Authorization`, `Proxy-Authorization`, `X-CSRF-Token`, `X-XSRF-Token`, API-key headers, and any header whose name contains token / secret / session / password / auth / cookie / csrf / xsrf are replaced by `<REDACTED>` |
| URLs | user info and the values of sensitive query / fragment parameters (token, csrf, session, password, key, code, signature, …) are replaced; names are kept |
| JSON / form bodies | values of sensitive keys (`csrfToken`, `token`, `password`, `cardNumber`, `cvc`, `FANBOXSESSID`, `authorization`, `cookie`, …) are replaced; binary and `multipart/form-data` bodies are summarized as `<binary N bytes>`; output is truncated |
| HTML | `<meta>` / `<input>` tags whose `name`, `id`, `property` or `itemprop` is a secret key (for example `csrf-token`, `_token`) have their `content` / `value` replaced, in either attribute order |
| Escaped JSON | secret keys inside JSON that is escaped for an HTML attribute, a JS string or a URL are found in every quote encoding: `&quot;`, `&#34;`, `&#034;`, `&#x22;`, `&apos;`, `&#39;`, `\"`, `"`, `\x22`, `%22`, … This covers the www.fanbox.cc `<meta name="metadata" content="{&quot;csrfToken&quot;:…}">`. As a fail-safe, text with entities or backslash escapes is also decoded once and scanned; when only the decoded form shows a secret, the decoded, redacted text is returned. |
| Free text | header lines, `key=value` / `key: value` secrets, cookie pairs, bearer tokens, CVC-like values after a keyword, and Luhn-valid card numbers (kept as `<REDACTED CARD ••••1234>`) are replaced |

Where it is applied:

1. **Before recording.** Both transports build each `ResearchEntry` from redacted headers
   (`SecretRedactor.formatHeaders`), a redacted URL (`redactURL`) and redacted bodies (`redactBody`). The web transport
   records `x-csrf-token` as `<REDACTED>`. The page metadata handed to the API Inspector has its token-like values
   replaced first (`FanboxAPIClient.redactingSecrets`).
2. **Before persisting.** `ResearchRecorder.sanitize` runs `SecretRedactor` over every text field again and drops
   bodies while Research Mode is off.
3. **Before display or export.** `ResearchLogFormatter.safe` (`Features/Settings/Research/ResearchLogFormatter.swift`)
   runs `SecretRedactor.redact` a third time and then `ResearchDisplayRedaction`, a small independent pass for
   sensitive header lines, `key=value` secrets, JSON secret keys, bearer tokens and Luhn-valid card numbers. The export
   text is redacted once more as a whole.

Logging uses `AppLog` (`os.Logger`). Log messages contain status codes, counts, identifiers and error descriptions;
request and response text is redacted before it reaches a log, and cookie / token values are never interpolated.

## Research Mode

Research Mode (§36) is off by default (`AppSettings.researchModeEnabled`).

| | Research Mode off | Research Mode on |
|---|---|---|
| Request metadata (method, redacted endpoint, status, duration, priority, account, transport, time) | recorded | recorded |
| Redacted headers | recorded | recorded |
| Redacted request body (appended to the request headers text) | not recorded | recorded, truncated to 16,000 characters |
| Redacted response body ("Safe Response Body") | not recorded | recorded, truncated to 64,000 characters |
| Web view navigations (redacted URL) | recorded | recorded |
| API schema snapshots (field names only) | recorded | recorded |

- At most 3,000 `ResearchLog` rows are kept; the oldest are pruned. The maintenance background task also deletes rows
  older than 14 days.
- The Account State screen shows whether a Keychain credential, a `FANBOXSESSID` cookie, a CSRF token and a user agent
  exist, and how many cookies there are. It never shows their values.
- The export (Settings → Research / API Inspector → ログを書き出す (export logs)) contains at most the newest 300
  entries, with bodies cut to 8,000 characters, written to a temporary file with complete file protection and shared
  through the share sheet. Earlier export files are deleted on the next export and when logs are cleared. Read an
  export before sharing it.

## Optional APNs relay

The relay is off by default. If enabled, it would receive only the APNs device token and an opaque account hint. It
never receives cookies, session ids, CSRF tokens, post content or supporter data. The relay server is not part of v1.0.
See [NOTIFICATION_RELAY.md](NOTIFICATION_RELAY.md).

## Out of scope / known limits

- A device that is unlocked and in someone else's hands can open the app. The app adds no passcode of its own.
- Files protected with `completeUntilFirstUserAuthentication` and Keychain items with
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` are readable after the first unlock since boot, which background
  refresh needs.
- CDN cookies received by the native transport can reach the web store through the Keychain → empty web store path
  described above.
- A store that could not be opened is kept on disk until it is removed by hand.
- The FANBOX API is unofficial; request shapes can change without notice. Use Research Mode and the API Inspector to
  check behavior before relying on it ([API.md](API.md)).

## Reporting a security problem

Do not post secrets (cookies, session ids, tokens, card data) in an issue. Describe the problem and how to reproduce
it; the maintainer will follow up privately if needed. See [CONTRIBUTING.md](../CONTRIBUTING.md).
