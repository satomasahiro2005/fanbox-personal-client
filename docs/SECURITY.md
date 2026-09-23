# Security and Sensitive Data

This document maps the storage and redaction rules of [SPEC.md](../SPEC.md) §7, §12, §38 and §39 to the code that
implements them.

## Principles

- Session secrets (cookies including `FANBOXSESSID`, CSRF tokens) live only in the Keychain and in the account's own
  WebKit data store. They are never written to SwiftData, `UserDefaults`, files, logs or the screen.
- Each account is isolated: separate WebKit store, separate Keychain item, separate `URLSession`.
- Card numbers, security codes, PINs, 3-D Secure credentials and passwords are never stored. Payment happens in the
  FANBOX / pixiv web pages inside the account-aware web view (§14).
- Everything that is logged or shown in Research Mode goes through `SecretRedactor`. There is no exception for debug
  builds (§38).
- iOS Data Protection is applied to the database and the media cache.

## Sensitive Data Storage Policy

| Data (SPEC §39) | Policy | Where it is stored | Implementation |
|---|---|---|---|
| FANBOX session secret (`FANBOXSESSID` and other session cookies) | Keychain | Generic-password item, service `ai.nemut.FANBOXClient.session`, account `credential.<accountID>`, value = JSON `SessionCredential` | `CredentialStore` (actor) over `KeychainStore`. Accessibility `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: readable by background refresh after the first unlock, never synced or restored to another device. |
| CSRF token | Keychain or memory | Inside the same `SessionCredential` Keychain item (`csrfToken`); cached in the actor's memory | `CredentialStore.updateCSRFToken`; `AccountHTTPClient` adds `X-CSRF-Token` only when `HTTPRequest.requiresCSRF` is set |
| Web cookies | Per-account WebKit store | `WKWebsiteDataStore(forIdentifier: Account.webProfileID)` | `WebSessionStore`. Only fanbox.cc / pixiv.net cookies are copied between the web store and the Keychain credential (`WebCookieScope`). Logout wipes the store; account removal deletes it. |
| API session | Per-account `URLSession` | Memory only | `AccountHTTPClient`: one ephemeral session per account, no shared cookie storage, no URL cache. Cookies are attached by hand and only for fanbox.cc / pixiv.net / pximg.net (`FanboxHostPolicy`). `Set-Cookie` responses are merged back into the Keychain credential. |
| Post body, comments, newsletters, creators, supports | SwiftData | `Application Support/Store/FANBOXClient.store` (+ `-wal`, `-shm`) | `PersistenceController`: directory and files use `FileProtectionType.completeUntilFirstUserAuthentication` |
| Thumbnails and media | File cache | `Caches/Media/<variant>/<sha256(url)>.<ext>`, one `MediaCacheEntry` row per file | `MediaCache` / `MediaService`: `completeUntilFirstUserAuthentication`. Evictable (§32); never contains text. |
| Card last 4 digits, brand, nickname, payment memo | SwiftData | `PaymentProfile` | Checked by `PaymentProfileValidator` before saving |
| Card number (PAN) | **Never stored** | — | `PaymentProfileValidator` rejects any field with a card-number-like digit run; the app has no card entry form |
| CVC / PIN / expiry / 3-D Secure credential | **Never stored** | — | `PaymentProfileValidator` rejects security-code-like values in the nickname, brand and memo; payment runs in the web view |
| Password | **Never stored** | — | Login happens in `AccountWebView`; the app only captures the resulting cookies |
| User settings | `UserDefaults` | Standard defaults | `AppSettings` holds non-secret values only (modes, intervals, toggles, relay URL) |
| Research logs | SwiftData | `ResearchLog`, `APISchemaSnapshot` | Redacted before insertion and again before display; see below |

`Account` rows hold only non-secret profile data (display name, pixiv / FANBOX user ids, avatar URL, `webProfileID`,
creator id, flags, timestamps).

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
`X-CSRF-Token: <REDACTED>`.

| Input | Rule |
|---|---|
| Headers | `Cookie`, `Set-Cookie`, `Authorization`, `Proxy-Authorization`, `X-CSRF-Token`, `X-XSRF-Token`, API-key headers, and any header whose name contains token / secret / session / auth / cookie / csrf are replaced by `<REDACTED>` |
| URLs | user info and the values of sensitive query / fragment parameters (token, csrf, session, password, key, code, signature, …) are replaced; names are kept |
| JSON / form bodies | values of sensitive keys (`csrfToken`, `token`, `password`, `cardNumber`, `cvc`, `FANBOXSESSID`, `authorization`, `cookie`, …) are replaced; binary bodies are summarized as `<binary N bytes>`; output is truncated |
| Free text | cookie pairs, bearer tokens and card-number-like digit runs are replaced |

Where it is applied:

1. **Before recording.** `AccountHTTPClient` builds each `ResearchEntry` from redacted headers
   (`SecretRedactor.formatHeaders`), a redacted URL (`redactURL`) and redacted bodies (`redactBody`).
2. **Before persisting.** `ResearchRecorder.sanitize` runs `SecretRedactor` over every text field again and drops
   response bodies while Research Mode is off.
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
| Request metadata (method, redacted endpoint, status, duration, priority, account, time) | recorded | recorded |
| Redacted headers | recorded | recorded |
| Redacted request body (appended to the request headers text) | not recorded | recorded, truncated to 16,000 characters |
| Redacted response body ("Safe Response Body") | not recorded | recorded, truncated to 64,000 characters |
| Web view navigations (redacted URL) | recorded | recorded |
| API schema snapshots (field names only) | recorded | recorded |

- At most 3,000 `ResearchLog` rows are kept; the oldest are pruned. The maintenance background task also deletes rows
  older than 14 days.
- The Account State screen shows whether a Keychain credential, a `FANBOXSESSID` cookie and a CSRF token exist, and
  how many cookies there are. It never shows their values.
- The export (Settings → Research Mode → ログを書き出す) contains at most the newest 300 entries, with bodies cut to
  8,000 characters, written to a temporary file with complete file protection and shared through the share sheet.
  Earlier export files are deleted on the next export and when logs are cleared. Read an export before sharing it.

## Optional APNs relay

The relay is off by default. If enabled, it receives only the APNs device token and an opaque account hint. It never
receives cookies, session ids, CSRF tokens, post content or supporter data. See
[NOTIFICATION_RELAY.md](NOTIFICATION_RELAY.md).

## Out of scope / known limits

- A device that is unlocked and in someone else's hands can open the app. The app adds no passcode of its own.
- Files protected with `completeUntilFirstUserAuthentication` are readable after the first unlock since boot, which
  background refresh needs.
- The FANBOX API is unofficial; request shapes can change without notice. Use Research Mode and the API Inspector to
  check behavior before relying on it ([API.md](API.md)).

## Reporting a security problem

Do not post secrets (cookies, session ids, tokens, card data) in an issue. Describe the problem and how to reproduce
it; the maintainer will follow up privately if needed. See [CONTRIBUTING.md](../CONTRIBUTING.md).
