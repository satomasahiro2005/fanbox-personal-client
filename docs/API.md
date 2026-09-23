# FANBOX Personal Client — internal API reference

> **Status:** research snapshot, 2026-09-24.
> The pixivFANBOX API is **unofficial and undocumented**. Nothing in this file has been checked yet by a request from this app. Before relying on a shape, confirm it in Research Mode / API Inspector (SPEC §36–37).
> This file sits under the repository's All Rights Reserved policy (SPEC §3.5).

## Contents

- [0. Provenance / legal](#0-provenance--legal)
- [1. Transport](#1-transport)
- [2. Common objects](#2-common-objects)
- [3. Endpoint index](#3-endpoint-index)
- [4. Session](#4-session)
- [5. Timeline](#5-timeline)
- [6. Post](#6-post)
- [7. Creator](#7-creator)
- [8. Plans / Support](#8-plans--support)
- [9. Comments](#9-comments)
- [10. Notifications (bell)](#10-notifications-bell)
- [11. Newsletters (おたより)](#11-newsletters-おたより)
- [12. Payments](#12-payments)
- [13. Follow](#13-follow)
- [14. Creator-side management (posts)](#14-creator-side-management-posts)
- [15. Uploads](#15-uploads)
- [16. Fans](#16-fans)
- [17. Dashboard (creator earnings)](#17-dashboard-creator-earnings)
- [18. Enum tables](#18-enum-tables)
- [19. Differential sync](#19-differential-sync)
- [20. Web fallback URLs](#20-web-fallback-urls)
- [21. Appendix: legacy / unverified endpoints](#21-appendix-legacy--unverified-endpoints)
- [22. Open questions / unknowns](#22-open-questions--unknowns)
- [23. Confidence summary](#23-confidence-summary)

---

## 0. Provenance / legal

### 0.1 How this information was obtained

- This file records **interoperability facts**: endpoint paths, HTTP methods, parameter names, response field names and types, status codes, and the behaviour other people reported, with dates.
- These facts come from **reading** public OSS repositories on GitHub (source files, test fixtures, commit messages and diffs, issues, READMEs) and the pixivFANBOX Help Center. The Help Center was read through its public Zendesk help-center JSON API.
- **No request was sent** to `fanbox.cc`, `api.fanbox.cc`, `www.fanbox.cc`, `downloads.fanbox.cc` or `pixiv.net` during this research.
- **No code was copied.** That covers source code, test fixtures, captured payload files and documentation prose from any project. Every JSON skeleton here is a hand-written summary in this document's own notation (§0.3). None of them is a copied payload, and none contains personal data.
- **The Swift implementation is independent** (SPEC §3.6). Kotlin, TypeScript, Python, Go, Rust and C# code from these projects is not translated into Swift. Where this file says "project X does Y", that is a fact about observed behaviour, and our implementation makes its own decision.
- Each project is licensed under its own terms. This document names them only to cite where a fact was seen.
- FANBOX is operated by pixiv Inc. This project is not affiliated with pixiv and is not endorsed by it. The API can change or be blocked at any time. The client must respect FANBOX's terms and SPEC §3.7: no mass collection, and differential sync only.

### 0.2 Sources consulted

Short names in the "Sources" lines below refer to this table. A "pushed" date is the repository's last push date as seen on 2026-09-24.

| Short name | Repository / location | Notes |
|---|---|---|
| fankt | github.com/matsumo0922/fankt | Kotlin MP FANBOX library (pushed 2026-08-16). Read: endpoints, entities, mappers, fixtures, envelope tests, openspec specs, the check-fanbox-api skill, and commits 5fb15169, d4d218e7, 6a392feb, ccbc0ae4, b8dd76e6, e5af450d, a3947705, a2e42364 |
| PixiView-KMP | github.com/matsumo0922/PixiView-KMP | Shipping app using fankt 0.1.3 (pushed 2026-08-19); commit 7d905c95, PR #21 |
| PixiView (old) | github.com/matsumo0922/PixiView | Older app (pushed 2025-01-31) |
| matsumo article | github.com/matsumo0922/matsumo-me-KMP articles/2-fanbox-viewer.md | 2023-12-23; same author as fankt, so not independent |
| Flare | github.com/DimensionDev/Flare | social/fanbox module (pushed 2026-09-23) |
| gallery-dl | github.com/mikf/gallery-dl | extractor/fanbox.py (last fanbox change 2026-02-25); issue #9393; commits 8553a831, 7b30aab5, f4a32e32 |
| PFD | github.com/xuejianxianzun/PixivFanboxDownloader | Browser extension (pushed 2026-09-10); changelog.md, API.ts, CrawlResult.d.ts, SaveFanCard.ts, docs/fanbox.md |
| hareku | github.com/hareku/fanbox-dl | Go CLI (pushed 2026-08-27); issues #96, #101, #103; PR #98 |
| Magelon | github.com/Magelon-png/PixivApi | C# client (develop, pushed 2026-09-09); 12 payload files under PixivApi.Tests/Payloads/Fanbox (real captures, some hand-wrapped later) |
| PixivUtil2 | github.com/Nandaka/PixivUtil2 | Python (pushed 2026-09-18); commits 6c04e333, fc0f9adf |
| moontaiworks | github.com/moontaiworks/fanbox-dl | TS CLI (pushed 2026-08-26); commits 5394e201, 7278c109 |
| pixivdwn | github.com/CircuitCoder/pixivdwn | Rust (pushed 2026-09-13); commits 3529cda3, 1526d58e, 657758aa |
| fc-downloader | github.com/ryoctrl/fc-downloader | TS (pushed 2026-07-31); says it checked some endpoints against the live service on 2026-06-07 |
| ValerianDillon | github.com/ValerianDillon/fanbox-downloader-extension | Browser extension (pushed 2026-09-02) |
| peach | github.com/longmeidao/peach | Python (pushed 2026-09-21); transport notes dated 2026-08 |
| piep | github.com/1211snowmaple/piep | Tauri/Rust (pushed 2026-09-13) |
| pixiv-cli | github.com/FlanChanXwO/pixiv-cli | Go (pushed 2026-09-23) |
| Pixiv-Shaft | github.com/CeuiLiSA/Pixiv-Shaft | Android (pushed 2026-09-23); FanboxApi.kt, FanboxWebBridge.kt (branch classic) |
| Pixiv-Reader-MD3 | github.com/nichijoux/Pixiv-Reader-MD3 | Mirrors Pixiv-Shaft's interface; not counted as independent |
| hoordu | github.com/yogthot/hoordu | plugins/fanbox.py (pushed 2026-06-15) |
| hideki0403 | github.com/hideki0403/fanbox-api | Captures traffic from a real browser (pushed 2026-07-18); PR #2 |
| lifegpc | github.com/lifegpc/pixiv_downloader | Rust |
| cssxsh | github.com/cssxsh/pixiv-client | Kotlin (pushed 2023-10-04) |
| FanboxViewer | github.com/709924470/FanboxViewer | Android (last changed 2020-08-21) |
| mtwtkman | github.com/mtwtkman/dl-pixiv-fanbox | Haskell (2023) |
| danbooru | github.com/danbooru/danbooru | Source extractor and URL parser for FANBOX |
| fanbox-archiver | github.com/feconi1024/fanbox-archiver | Python (pushed 2026-08-27) |
| konnokai | github.com/konnokai/PixivFanboxDownloader | C# |
| FanboxD | github.com/CHH2000day/FanboxD | Kotlin (2023) |
| nushell script | github.com/wantJoy1/nix-config nixos/nushell/fanbox/fanbox_payments.nu | Commit a5a81ba5, 2026-06-28 |
| cromachina | github.com/cromachina/fanbox-bot | Creator-side Discord bot (ARCHIVED 2025-04); main.py @21ef099 (2022) and HEAD; issue #3 |
| defaultcf spec | github.com/defaultcf/fanbox-specification | OpenAPI spec; unmerged branch feature/add-relationships (2024-09); commit 00a8df23 |
| fanboxsync | github.com/defaultcf/fanboxsync | Go CLI for creators (pushed 2026-09-20) |
| fanbox-go | github.com/defaultcf/fanbox-go | Generated Go client (pushed 2026-08-08); same author as defaultcf spec |
| kozukaccd | github.com/kozukaccd/get-fanbox-supporters | Playwright script (2026-08) |
| 0kqnet | github.com/0kqnet/fanbox-supporters | Bookmarklet |
| JanMaki | github.com/JanMaki/FanboxSupporterApi-Kt | Kotlin creator-side client (2023) |
| yogthot fansync | github.com/yogthot/fansync-importer-app | C# (2024–25); commit 3998a75a |
| axtuki1 | github.com/axtuki1/vrchat-group-Linkfanbox | TS (2025-04) |
| vrct_supporters | github.com/ShiinaSakamoto/vrct_supporters | Browser extension (2026-09); web page URL only |
| Bakabase | github.com/anobaka/Bakabase | Cookie validator only |
| RSSHub | github.com/DIYgod/RSSHub | Issues #21699 (2026-04-11), #19430 (2025-06), #19724 (2025-07) |
| FanboxEnumerator | github.com/kiyo4act/FanboxEnumerator | DOM-based, no API calls |
| nantas | github.com/nantas/chrome-agent sites/strategies/fanbox.cc/strategy.md | **Low reliability** |
| Help | fanbox.pixiv.help (Zendesk help-center API) | Articles 360000664842, 360003723693, 54418828998297, 4514696329625, 360018253253, 360018102654, 900003410886, 360003723653, 360005115293, 360003698754, 360013697473, 360004254334, 4442218789529, 360003698854, 360003698974, 360008991393, 7324997407513, 360005115233, 360003723633, 360003723533, 360000230381, 4442406551705, 4442380315545, 54418814564505, 26030583672217, 360011057793, 26439413791257, 900001773206, 360004253894, 360005114953, 360013904933, 48515034524313, 360005063874 |

Carried over from earlier research and not re-verified in this pass: EndlessMISAKA/AtelierMisaka, and search-snippet text from the Help Center.

Also checked and found fan-side only or irrelevant: hakatashi/HakataArchiver, midona-rhel/picto, 2gPigeon/fanbox-viewer, nonamethanks/danboorutools, 250king/MyFanbox, usagiga/fanbox-emmacho, niwaniwa/fanbox-supporter-manager (empty).

### 0.3 Notation and confidence legend

Skeletons use a JSON-like notation. They are not valid JSON:

- `string`, `int`, `bool`: primitive types. Ids are **strings** even when they are numeric.
- `T | null`: the value can be null. `key?`: the key may be absent.
- `[T]`: an array of T. `{ [id]: T }`: an object used as a map.
- `// ...`: comments.
- Named types such as `PostListItem` are defined in §2.

| Confidence | Meaning |
|---|---|
| **high** | Several independent, current (2025–2026) sources agree, or there is a real captured payload. |
| **medium** | One current source, several old sources, or sources that disagree on details. |
| **low** | One old source, synthetic fixtures only, or inferred. Do not build on it without verifying in Research Mode. |

---

## 1. Transport

### 1.1 Hosts

| Host | Role | Cookie | Notes |
|---|---|---|---|
| `https://api.fanbox.cc` | JSON API. Paths look like `/<group>.<action>`, e.g. `/post.info`. Exceptions: `/legacy/...` paths | FANBOXSESSID (+ Cloudflare cookies) | Main API |
| `https://www.fanbox.cc` | Website HTML. Source of the `metadata` meta tag (CSRF token, current user) | FANBOXSESSID | Also serves WebView fallbacks (§20) |
| `https://downloads.fanbox.cc` | Post images and attachments | **Required** (403 without it) | §1.9 |
| `https://pixiv.pximg.net` | Public resized images: covers, icons, plan covers | **Never send** | Needs a `Referer` (§1.9) |
| `https://fanbox.pixiv.net` | Obsolete API root `/api/{method}` (used `userId` params) and legacy media | — | Do not use for the API. Accept its media URLs if old posts contain them |

### 1.2 Request headers (api.fanbox.cc)

| Header | Value | Required | Notes |
|---|---|---|---|
| `Origin` | `https://www.fanbox.cc` | **Yes** | A missing Origin gives HTTP 400 whether or not you are logged in (hareku comment, Pixiv-Shaft doc, nushell script, defaultcf spec). danbooru sends `https://fanbox.cc`, and JanMaki (2023) sent a creator subdomain. Whether those still work is unverified; use the exact value above. |
| `Referer` | `https://www.fanbox.cc/` | Recommended | All clients send it. PixivUtil2 and peach send the post page URL for `post.info`; PixivUtil2 says it "doesn't seem to be essential". |
| `Accept` | `application/json, text/plain, */*` | Recommended | gallery-dl, hareku, PixivUtil2, Flare, cromachina. Pixiv-Shaft and peach send `application/json`. |
| `User-Agent` | A realistic browser UA | Yes (defaultcf spec) | If you send `cf_clearance`, the UA **must be byte-identical** to the one that earned it (Pixiv-Shaft, pixiv-cli, cromachina). On iOS, use the UA of the account's WKWebView. |
| `x-csrf-token` | `metadata.csrfToken` | POSTs only | §1.4. Header names are case-insensitive. |
| `Content-Type` | `application/json` | JSON POSTs | `post.update` is the exception: it is multipart (§14.4). |
| `Sec-Fetch-Dest` / `-Mode` / `-Site` | `empty` / `cors` / `same-site` | Optional | gallery-dl, moontaiworks, cromachina. Not shown to be required. |
| `Priority`, `TE`, `Alt-Used`, `Accept-Language` | e.g. `u=1, i`; `trailers`; `api.fanbox.cc` | Optional | Magelon, cromachina, hoordu. Not shown to be required. |

For the `www.fanbox.cc` HTML page, Flare sends `Accept: text/html,*/*` plus the same Origin, Referer and UA.

### 1.3 Cookies

| Cookie | Domain | Role |
|---|---|---|
| `FANBOXSESSID` | `.fanbox.cc`, path `/`, httpOnly, secure | The login. Its value looks like `<numericPixivUserId>_<random>`: konnokai's prompt shows this form, and cromachina splits on `_` to get the user id. No source implements a programmatic login. It is always obtained from a browser or WebView login, or pasted by the user. The pixiv app-api Bearer token does **not** work here (Pixiv-Shaft). |
| `cf_clearance` | `.fanbox.cc` | Cloudflare clearance. Tied to the **UA** and effectively to the **IP address** (cromachina README: from another IP it gives 403). |
| `__cf_bm` | `.fanbox.cc` | Cloudflare bot-management cookie. Magelon refuses to start without `__cf_bm`, `cf_clearance` and `FANBOXSESSID`. The nushell script and fc-downloader send only FANBOXSESSID and succeed. |

Scoping rules for this app, following SPEC §7 and §39:

- One `WKWebsiteDataStore` per account, and one cookie jar and URLSession per account.
- Send FANBOX cookies **only** to `www.fanbox.cc`, `api.fanbox.cc` and `downloads.fanbox.cc`. Never send them to `pixiv.pximg.net` or any third party. pixiv-cli and peach follow the same rule.
- hareku (PR #98, 2026-07) carries over the Cloudflare cookies that responses set. Do the same: store `Set-Cookie` values back into the account's jar.
- JanMaki (2023) refreshed FANBOXSESSID from `Set-Cookie`, and pinged `www.fanbox.cc` every 10 minutes to keep the session alive. That was before Cloudflare, so do not copy the ping.

### 1.4 CSRF token

1. `GET https://www.fanbox.cc/` with the account's cookies.
2. Select `<meta name="metadata" content="...">`. yogthot selects the same tag by `id="metadata"`.
3. HTML-unescape the `content` attribute, JSON-decode it, and read `csrfToken` (§2.14).
4. Send it as `x-csrf-token` on every POST. The only exception is `post.update`, which takes the token in the multipart field `tt` (§14.4).

Rules:
- The token is bound to the session. Keep it in memory only. Clear it whenever FANBOXSESSID changes, and re-fetch it at app start or after login (fankt).
- Flare re-reads the metadata when its token is blank and has a forced-refresh path. We re-fetch once after a POST fails with 400 or 403 JSON, then retry once. This is our own inference, because token rotation is undocumented.
- GET requests work without the token (Flare, cssxsh, Pixiv-Shaft, fc-downloader, hareku, gallery-dl). fankt and the old PixiView send `x-csrf-token` on every fanbox.cc request, empty when unknown, and nothing breaks.
- Never send `x-csrf-token` to `pixiv.pximg.net` or `fanbox.pixiv.net`. fankt strips it for those hosts.

These POSTs need the token: `post.likePost`, `post.addComment`, `post.deleteComment`, `post.likeComment`, `follow.create`, `follow.delete`, `notification.updateSettings`, `newsletter.markAsReadAll`, `post.create`, `post.delete`, and `post.update` (as `tt`).

### 1.5 Response envelope

```jsonc
// success (2xx)
{ "body": <payload> }
// failure (normally non-2xx; peach saw an error body from post.info without recording the status,
// so check for an "error" key regardless of status)
{ "error": "general_error" }      // e.g. logged out, bad params, missing credentials
{ "error": "general" }            // post.update failure without a reason (cromachina #3)
```

- pixivdwn requires exactly one of `body` and `error`. PixivUtil2 and fanbox-archiver treat any `error` key as a failure. Do the same.
- A payload may be an object, an array, a number or `null`. The shapes of several bodies changed in 2026 (§1.10).

### 1.6 Status codes

| Status | Meaning as sources interpret it | Client action |
|---|---|---|
| 200 | OK. **A 200 with `isRestricted: true` and `body: null` on `post.info` is normal**: the viewer is not entitled. | Store it. |
| 302 (www pages) | Logged out; redirect to login (yogthot, `/manage/dashboard`). | Mark the session expired. |
| 400 | Missing `Origin`; bad parameters; logged out on some endpoints (`user.countUnreadMessages` gives `general_error`); missing cookie (konnokai); historically `post.listCreator` with `limit` > 300. | Check headers. Do not retry blindly. |
| 401 | Not logged in (`post.listHome`), invalid or expired FANBOXSESSID, or a session revoked after bot detection (hareku #96). | Session expired → re-login in WebView. |
| 403 `application/json` | FANBOX refused the resource: not entitled, or unavailable to this account. | Show the "not available" state. |
| 403 `text/html` | **Cloudflare**, not FANBOX. Signs: `Server: cloudflare`, a `Cf-Ray` header, `cf-mitigated: challenge`, or markers such as `just a moment`, `cf-chl-`, `challenge-platform`, `attention required`, `cloudflare ray id`. Since 2026-04 the body can also be an HTML page titled "ブロックされました". | **Does not by itself mean the session is invalid** (fankt check-fanbox-api skill). Switch to the WebView transport (§1.11). |
| 404 | Not found. `legacy/manage/supporter/user` also returns 404 for "not a supporter". | — |
| 429 | Rate limited, sometimes with `Retry-After` given in seconds or as an HTTP-date. fankt and piep parse both. In a browser the 429 comes from Cloudflare without CORS headers, so `fetch` only sees `TypeError: Failed to fetch` (PFD, 2025-07). `Retry-After` is also unreadable from a content-script fetch (ValerianDillon). | Back off globally (§1.8). |
| 5xx | Server error. On downloads, `500 text/plain "failed to thumbnailing"` for very large originals. | Retry later; for images, fall back to `thumbnailUrl` (hareku). |

Redirects: do not follow redirects on POST, and cap GET redirects at 5 (fankt). Before following any redirect or `nextUrl`, check its host against the allowlist in §1.1.

### 1.7 Cloudflare / bot detection (2024–2026)

- **Since about 2024-06-26 or 2024-07-01**, FANBOX has sat behind Cloudflare with Turnstile (cromachina README; hideki0403 wiki). `cf_clearance` only works from the IP address and UA that passed the challenge. hideki0403 guesses it lasts one year (unverified).
- **TLS/JA3 and HTTP/2 fingerprints are enforced.** Plain python-requests, OkHttp and curl get 403 challenges. Stacks that impersonate a browser pass: curl_cffi `chrome136` (fankt check script), curl_cffi `firefox135` (PixivUtil2, for `post.info` only), curl_cffi `firefox147` / `chrome150` (peach, for `post.info` only), tls-client Chrome 146 PSK (hareku), and wreq Chrome140 (pixivdwn). In gallery-dl #9393 (2026-04), the HTTP/2 pseudo-header order mattered, and a browser forced down to HTTP/1.1 got 403 on the post API.
- **Since about 2026-04-10, `post.info` is blocked for non-browser clients** even with valid cookies (RSSHub #21699; Pixiv-Shaft). The response is 403 with the HTML page "ブロックされました", no JSON and no CORS header. Headless Chrome is blocked too. A real on-device WebView passes, even without `cf_clearance`. Pixiv-Shaft's code comment says the same rule covers `post.getEditable`; nobody has confirmed that independently. Earlier 403 waves on `post.info` were reported in 2025-06 (RSSHub #19430) and 2025-07 (#19724).
- Pixiv-Shaft reports that `post.get`, `post.listHome` and `bell.countUnread` still return 200 over OkHttp with the same cookie, UA and Origin that get 403 on `post.info`.
- Other reports:
  - FANBOX revoked the browser session right after non-browser use (hareku #96, 2026-07).
  - 403s tied to IP reputation.
  - Paying users got `isRestricted: true` with no body under automated access (hareku #101, 2026-07-19; low confidence).
- Creator-side tools (kozukaccd, 0kqnet, hideki0403) all issue their calls **from inside a logged-in browser page**.

### 1.8 Rate limiting

- About 30–37 rapid `post.info` calls trigger a Cloudflare 429, and it took about 6 minutes to clear (PFD 2025-07). PFD now makes **1 request/s, serially**, with at most 3 concurrent downloads.
- ValerianDillon lets the user set a 100–2000 ms interval for `post.info`, honours `Retry-After`, and shares the backoff across tabs.
- nantas (low reliability) claims 80–100 calls per 10 minutes, 2.5–3 hours to recover, and a safe rate of 8–10 calls per minute.
- **Skip `post.info` for list items with `isRestricted: true`.** Those calls only use up the budget (ValerianDillon, hareku). peach also skips items with `feeRequired > 0`.
- App policy (our own inference):
  - Keep one **device-wide** budget shared by all accounts, because Cloudflare limits are most likely per IP.
  - Keep `post.info` serial at ≥ 1 s apart.
  - After a 429, pause every api.fanbox.cc call for `Retry-After`, or 6 minutes if it is absent.
  - Never let background sync spend the budget that interactive requests need (SPEC §29).
  - Creator fan and pledge endpoints: kozukaccd advises pulling the fan list only about monthly. The app pulls it on demand, at most about once a day.

### 1.9 Media hosts

| Host / pattern | Cookie | Headers | Notes |
|---|---|---|---|
| `downloads.fanbox.cc/images/post/{postId}/{imageId}.{ext}` (originalUrl) | FANBOXSESSID **required** | `Referer: https://www.fanbox.cc/` (+Origin/UA) | 403 without a cookie (PFD) |
| `downloads.fanbox.cc/images/post/{postId}/w/1200/{imageId}.jpeg` (thumbnailUrl) | required | same | Width-1200 sample |
| `downloads.fanbox.cc/images/post/{postId}/c/1200x630/{imageId}.jpeg` | required | same | Cropped sample (danbooru) |
| `downloads.fanbox.cc/files/post/{postId}/{fileId}.{ext}` (File.url) | required | same | Attachments |
| `pixiv.pximg.net/c/{W}x{H}_90_a2_g5/fanbox/public/images/...` | **none** | `Referer: https://www.fanbox.cc/` | fc-downloader reports 403 without a FANBOX Referer. Paths: `post/{postId}/cover/` (1200x630), `user/{userId}/icon/` (160x160), `creator/{userId}/cover/` (1620x580), `creator/{userId}/profile/` (400x400 thumbnails), `plan/{planId}/cover/` (936x600) |
| `pixiv.pximg.net/fanbox/public/images/...` (without `/c/…/`) | none | Referer | The original size. gallery-dl and PixivUtil2 drop the `/c/<size>/` segment. danbooru calls un-resized profile URLs a "dead URL type", but real payloads return them (disagreement). |
| `fanbox.pixiv.net/images/post/...`, `/files/post/...`, `/images/entry/...` | — | — | Legacy host. In legacy `entry` HTML, `<a href>` points to the original and `<img src>` to the `/w/1200/` thumbnail. gallery-dl also reads `data-src-original`. |

- Use media URLs **exactly as the API returns them**. Do not rebuild them (fankt spec). The table above exists for recognising URLs and choosing sizes, not for constructing them.
- There is no field named `coverImageFeedUrl` in any source.

### 1.10 2026 envelope changes and decoding policy

In 2026, FANBOX wrapped several bare response bodies in named objects. **Every decoder must accept both the old shape and the new one**, and Research Mode should record which shape it saw.

| Endpoint | Legacy body | Current body | Changed | Evidence |
|---|---|---|---|---|
| `creator.listFollowing`, `creator.listPixiv`, `creator.listRecommended` | `[Creator]` | `{ creators: [Creator] }` | ~2026-04 | fankt 5fb15169 (04-13), PFD 4.9.0 (04-29); Magelon's capture committed 04-26 was still bare (captured earlier?) |
| `post.info` | `PostDetail` | `{ post: PostDetail }` | 2026-07-13 | PFD 4.9.2, fankt d4d218e7, pixivdwn 3529cda3 (07-14) |
| `post.get` | `{…metadata}` | `{ post: {…} }` | probably the same day (inferred) | Pixiv-Shaft (current) and hoordu (pre-July) |
| `plan.listSupporting`, `plan.listCreator` | `[Plan]` (older still: `supportingPlans`) | `{ plans: [Plan] }` | 2026-07-14…18 | pixivdwn 07-14, Magelon 02ed2e60 07-16, hareku #101 07-17, hideki0403 07-18, moontaiworks 5394e201 07-19 |
| `post.listCreator` | `[PostListItem]` (2024-08…2026-07); before 2024-08 `{ items, nextUrl }` | `{ posts: [PostListItem] }` | 2026-07-22 | PFD 4.9.3, fankt 6a392feb, hareku #103, Magelon and PixivUtil2 (07-25), pixivdwn (07-26) |
| `post.paginateCreator` | `[string]` | `{ pageUrls: [string] }` | 2026-07-22 | PFD 4.9.4, fankt 6a392feb |
| `payment.listPaid` | `[PaidRecord]` | `{ payments: [PaidRecord] }` | by 2026-06-28 | nushell script (06-28), fankt a3947705 (07-16) |
| `tag.getFeatured` | ? | `{ featuredTags: [...] }` | fankt b8dd76e6 (2026-02-02) | fankt, ValerianDillon |

- **Not reported as changed:** `post.listHome`, `post.listSupporting`, `post.listTagged` (disputed, §5.5), `creator.get`, `creator.search`, `post.getComments`, `bell.list`.
- **Still bare arrays:** `tag.search` and `newsletter.list`. fankt's envelope test states these two are "genuinely" bare arrays. `relationship.listFans` and `relationship.listFilterOptions` are also bare; there is no 2026 capture for them.
- fankt commit ccbc0ae4 says the wrappers "have not changed", but fankt's own history (bare arrays at b8dd76e6 in 2026-02, and 6a392feb saying FANBOX changed them) contradicts that.
- Clients that still read the old shapes: gallery-dl master, danbooru, moontaiworks (`post.listCreator` and `paginateCreator`), PixivUtil2 (`creator.listFollowing`), hoordu, and piep (`plan.listSupporting`).

Decoding rules (our own policy, not copied from any project):
- For each wrapped list, try the named key (`creators`, `posts`, `pageUrls`, `plans`, `payments`), then a bare array, and record which one matched.
- Ids are strings. Numeric fields sometimes arrive as strings: `feeRequired` in the 2022 `fanbox.post` postInfo sample. Decode numbers leniently.
- Unknown enum strings decode to an `.unknown(raw)` case. Never fail a whole list because of one item (fankt's tolerant decoder skips a malformed item).
- Missing maps such as `embedMap` count as empty.
- Datetimes are ISO-8601 with an offset (`2025-02-08T12:00:00+09:00`). Accept them with or without fractional seconds.

### 1.11 iOS transport recommendation (design; inferred)

No source tests iOS. The following follows from §1.7:

1. **Native transport** (URLSession, one per account, cookies copied from the account's `WKWebsiteDataStore`, UA equal to the WKWebView UA). Use it for list, count and metadata endpoints.
2. **WebView transport**: an offscreen `WKWebView` per account that has loaded `https://www.fanbox.cc/` and runs `fetch(url, {credentials: "include"})` from that page, returning the JSON through a script message handler. This is the same idea as Pixiv-Shaft's bridge, implemented independently. Use it for `post.info`, `post.getEditable`, all creator-side endpoints (§14–17), and as the automatic fallback whenever the native transport receives a Cloudflare HTML 403.
3. Record which transport succeeded for each endpoint in Research Mode, and prefer that transport next time.

---

## 2. Common objects

### 2.1 UserRef

```jsonc
{ "userId": string /* numeric pixiv user id */, "name": string, "iconUrl": string | null }
```

### 2.2 PostListItem (list endpoints, bell `post`)

Seen in real 2026-04 captures (Magelon) and in anonymized fankt fixtures.

```jsonc
{
  "id": string,                      // numeric post id
  "title": string,
  "feeRequired": int,                // JPY; 0 = public
  "publishedDatetime": string,       // ISO-8601 with offset
  "updatedDatetime": string,
  "tags": [string],
  "isLiked": bool,
  "likeCount": int,
  "isCommentingRestricted": bool,
  "commentCount": int,
  "isRestricted": bool,              // true = this viewer cannot read the body
  "user": UserRef | null,
  "creatorId": string,               // creator handle (the @name)
  "hasAdultContent": bool,
  "cover": { "type": "cover_image" | "post_image", "url": string } | null,
  "excerpt": string,                 // often "" when restricted
  "isPinned"?: bool                  // present on post.listCreator items; absent on post.listHome
}
```

List items carry **no `type` and no `body`** (since 2022-03, PFD 1.9.0).

### 2.3 PostDetail (`post.info`)

```jsonc
{
  "id": string, "title": string, "feeRequired": int,
  "publishedDatetime": string, "updatedDatetime": string,
  "tags": [string], "isLiked": bool, "likeCount": int,
  "isCommentingRestricted": bool, "commentCount": int,
  "isRestricted": bool, "user": UserRef | null, "creatorId": string,
  "hasAdultContent": bool, "excerpt": string,
  "type": "article" | "image" | "file" | "text" | "video" | "entry",
  "coverImageUrl": string | null,    // FLAT here; list items use cover{type,url}
  "body": PostBody | null,           // null when isRestricted
  "nextPost": { "id": string, "title": string, "publishedDatetime": string } | null,
  "prevPost": { "id": string, "title": string, "publishedDatetime": string } | null,
  "imageForShare": string,
  "isPinned": bool
  // Declared only by older clients and absent from 2025–2026 captures:
  // restrictedFor (pixiv-cli), commentList (embedded comments; removed ~2024-09-18)
}
```

### 2.4 PostBody (by `type`)

```jsonc
// image
{ "text": string, "images": [Image] }
// file
{ "text": string, "files": [File] }
// text
{ "text": string }
// video
{ "text": string, "video": { "serviceProvider": string, "videoId": string } }   // fankt also accepts contentId
// entry (legacy HTML post)
{ "html": string }
// article
{
  "blocks": [Block],
  "imageMap": { [imageId]: Image },
  "fileMap": { [fileId]: File },
  "embedMap"?: { [embedId]: Embed },       // absent from fankt's 2026 response-derived fixtures -> treat as {}
  "urlEmbedMap": { [urlEmbedId]: UrlEmbed },
  "text"?: null, "images"?: [], "files"?: []   // empty extras seen in 2026 fixtures
}
```

PFD's older documentation says all four maps are always present, as `{}` when empty. The 2026 fixtures disagree, so treat any missing map as empty.

Some posts contain blocks that reference ids **missing from their map**. pixivdwn raises an explicit "unmatched id" error and PixivUtil2 logs a warning. Render a placeholder for such a block instead of failing the post.

### 2.5 Image / File

```jsonc
Image = { "id": string, "extension": string, "width": int, "height": int,
          "originalUrl": string, "thumbnailUrl": string }
File  = { "id": string, "name": string /* WITHOUT extension */, "extension": string,
          "size": int /* bytes */, "url": string }
```

Display file name = `name + "." + extension` (gallery-dl, PFD).

### 2.6 Block (article)

```jsonc
{
  "type": "p" | "header" | "image" | "file" | "embed" | "url_embed",
  "text"?: string,                                   // p / header; may be "" (keep it as spacing)
  "styles"?: [ { "type": "bold", "offset": int, "length": int } ],
  "links"?: [ { "offset": int, "length": int, "url": string } ],
  "imageId"?: string, "fileId"?: string, "embedId"?: string, "urlEmbedId"?: string
}
```

Captures often include the unused id keys set to `null`. For offset units, see §18.4.

### 2.7 Embed / UrlEmbed

```jsonc
Embed = { "id": string, "serviceProvider": string, "contentId"?: string, "videoId"?: string }  // videoId wins when both exist

UrlEmbed =
  { "id": string, "type": "default", "url": string, "host"?: string }        // host: 2022 sample only
| { "id": string, "type": "html" | "html.card", "html": string }             // iframely markup - UNTRUSTED
| { "id": string, "type": "fanbox.post", "postInfo": PostListItem-like }     // parse tolerantly (see note)
| { "id": string, "type": "fanbox.creator", "profile": Creator }             // lifegpc
```

- `fanbox.post` postInfo: fankt's 2026 fragment has the full list-item shape, while PFD's 2022 sample had a reduced set (`feeRequired` as a string and a flat `coverImageUrl`). Decode both.
- `html` and `html.card` markup must be sanitized, or rendered in a sandboxed WKWebView with no FANBOX cookies and no access to the app bridge.

### 2.8 Creator (`creator.get`, `creator.list*`, `creator.search`)

```jsonc
{
  "user": UserRef | null,
  "creatorId": string,
  "description": string,
  "hasAdultContent": bool,
  "coverImageUrl": string | null,
  "profileLinks": [string],
  "profileItems": [ProfileItem],
  "isFollowed": bool,
  "isSupported": bool,             // has an active plan (fc-downloader: a ¥0 plan also counts)
  "isStopped": bool,               // cancelled but still valid until month end (fc-downloader)
  "isAcceptingRequest": bool,
  "hasBoothShop": bool,
  "hasPublishedPost": bool,
  "category": string | null        // e.g. "illustrations"; null in every real Magelon payload
}
ProfileItem =
  { "id": string, "type": "image", "imageUrl": string, "thumbnailUrl": string }
| { "id": string, "type": "video", "serviceProvider": string, "videoId": string }   // one fankt fragment (medium)
```

pixiv-cli's creator type has fields that no other source has (`isFollowing`, and `plan{fee,hasSupportingPlan}`). They are probably wrong; ignore them.

### 2.9 Plan

```jsonc
{
  "id": string,                  // numeric
  "title": string,
  "fee": int,                    // JPY per month
  "description": string,
  "coverImageUrl": string | null,
  "user": UserRef | null,
  "creatorId": string,
  "hasAdultContent": bool,
  "paymentMethod": string | null, // §18.9; null when the viewer does not pay for this plan
  "perks"?: []                   // only ever seen empty
}
```

### 2.10 Comment

```jsonc
{
  "id": string,
  "parentCommentId": string,     // "0" for a root comment
  "rootCommentId": string,       // "0" for a root comment
  "body": string,                // plain text
  "createdDatetime": string,
  "likeCount": int,
  "isLiked": bool,
  "isOwn": bool,
  "user": UserRef | null,        // null for a deleted user
  "replies": [Comment]           // only on root items; each reply has replies: []
}
```

The server flattens a reply to a reply into its root's `replies`: `rootCommentId` is the root's id, and `parentCommentId` is the comment it answers. fankt sorts replies by `createdDatetime` itself, so do not assume the server returns them in order.

### 2.11 Bell (notification item)

```jsonc
// Always present:
{ "id": string, "type": string, "notifiedDatetime": string, "isUnread": bool }

// type == "on_post_published"  (anonymized REAL capture: ONLY these keys + post)
{ ..., "post": PostListItem }

// type == "post_comment"  (fankt handcrafted fixture; PixiView/PixiView-KMP handle it in production)
{ ..., "post": null, "postCommentBody": string, "isRootComment": bool,
  "creatorId": string, "postId": string, "postTitle": string,
  "userName": string /* commenter */, "userProfileImg": string /* commenter icon */ }

// type == "post_comment_like"  (handcrafted fixture)
{ ..., "post": null, "postCommentBody": string /* the liked comment */,
  "creatorId": string, "postId": string, "count": int,
  "postTitle": null, "userName": null, "userProfileImg": null }

// "creatorUserId": modeled by fankt, null in every fixture, purpose unknown.
```

- In the real capture, keys that do not apply to a type are **absent**, not null. fankt's handcrafted fixtures fill them with null. Decode every type-specific key as optional.
- fankt uses the bell id as the comment id for `post_comment`. Whether the bell id really equals the comment id is **unverified**.

### 2.12 NewsLetter (おたより)

```jsonc
{
  "id": string,
  "body": string,                // text; whether it can contain HTML is unknown -> render as plain text
  "createdAt": string,           // note: "createdAt", not "*Datetime"
  "creator": { "creatorId": string, "user": UserRef },
  "isRead": bool
}
```

### 2.13 PaidRecord / SupportTransaction

```jsonc
PaidRecord = {                   // payment.listPaid / listUnpaid
  "id": string,                  // numeric (cssxsh typed it as a number)
  "paidAmount": int,             // JPY
  "paymentDatetime": string,
  "paymentMethod": string,       // §18.9
  "creator": { "creatorId": string, "user": UserRef, "isActive"?: bool /* legacy only */ }
}
SupportTransaction = {           // legacy/support/creator (fan side)
  "id": string,
  "paidAmount": int,
  "targetMonth": string,         // "YYYY-MM"
  "transactionDatetime": string,
  "supporter": UserRef
}
```

### 2.14 Metadata (`<meta name="metadata">` on www.fanbox.cc)

```jsonc
{
  "apiUrl": string | null,
  "csrfToken": string,                       // the only field Flare requires
  "context": {
    "privacyPolicy": { "policyUrl": string, "revisionHistoryUrl": string,
                       "shouldShowNotice": bool, "updateDate": string /* YYYY-MM-DD */ },
    "user": {
      "userId": string | null,               // null when logged out
      "creatorId": string | null,            // set only for creators
      "name": string,
      "iconUrl": string | null,
      "isCreator": bool,
      "isSupporter": bool,
      "fanboxUserStatus": int,               // meaning undocumented
      "hasAdultContent": bool | null,
      "hasUnpaidPayments": bool,             // paymentAttention signal
      "isMailAddressOutdated": bool,
      "lang": string,
      "planCount": int,
      "showAdultContent": bool
    }
  },
  // Keys seen in 2023-2025 snapshots (cssxsh, lifegpc); may or may not still exist:
  "wwwUrl"?: string, "isOnCc"?: bool, "isXEmbedEnabled"?: bool,
  "isPayPalCashbackCampaignForSimplifiedChineseUserEnabled"?: bool,
  "urlContext"?: { "creatorOriginPattern": string, "rootOriginPattern": string,
                   "host": { "creatorId": string | null },
                   "user": { "creatorId": string | null, "isLoggedIn": bool } }
  // older context.user also had: hasPlans, isPrivacyPolicyAgreementRequired, socialConnectStatus{twitter}
}
```

Decode leniently: Flare treats every field except `csrfToken` as optional.

### 2.15 EditablePost (creator side)

```jsonc
{
  "id": string,
  "title": string,
  "status": "draft" | "published",
  "permalink": string,
  "feeRequired": int,
  "updatedAt": string,           // NOTE: *At, not *Datetime (creator-side naming)
  "publishedAt": string,
  "tags"?: [string],             // seen only in cromachina 2022; absent from defaultcf spec
  "body"?: {
    "blocks": [Block],           // spec lists only p / header / image / url_embed
    "imageMap": { [id]: { "id": string, "extension": string, "originalUrl": string, "thumbnailUrl": string } },
    "urlEmbedMap": { [id]: { "id": string, "type": "html" | "html.card" | "fanbox.post" | "default",
                              "html"?: string, "url"?: string,
                              "postInfo"?: { "id": string, "creatorId": string } } }
    // fileMap / embedMap: not in the spec; probably present on articles that use them (inferred)
  }
}
```

### 2.16 Fan / FilterOption (creator side)

```jsonc
Fan = {
  "status": "supporter" | "follower",
  "user": UserRef,
  "planId": string | null,       // null or absent for followers
  "activatedAt": string,         // ISO-8601; the defaultcf branch spells it "activedAt" (typo)
  "note": string                 // the creator's private memo about this fan
}
FilterOption = {
  "type": "supporter" | "follower" | "all",
  "planId": string | null,       // non-null = a per-plan supporter bucket
  "planTitle": string | null,
  "count": int
}
```

---

## 3. Endpoint index

| # | Area | Endpoint | Method | Auth | CSRF | Confidence |
|---|---|---|---|---|---|---|
| 1 | Session | `www.fanbox.cc/` metadata | GET | optional | no | high |
| 2 | Timeline | `post.listHome` | GET | yes | no | high |
| 3 | Timeline | `post.listSupporting` | GET | yes | no | high |
| 4 | Timeline | `post.paginateCreator` | GET | no | no | high |
| 5 | Timeline | `post.listCreator` | GET | no | no | high |
| 6 | Timeline | `post.listTagged` | GET | no | no | medium |
| 7 | Post | `post.info` | GET | optional | no | high |
| 8 | Post | `post.get` | GET | unknown | no | medium |
| 9 | Post | `post.likePost` | POST | yes | yes | high |
| 10 | Post | `tag.search` | GET | no | no | medium |
| 11 | Creator | `creator.get` | GET | no | no | high |
| 12 | Creator | `creator.listFollowing` | GET | yes | no | high |
| 13 | Creator | `creator.listRecommended` | GET | optional | no | high |
| 14 | Creator | `creator.listPixiv` | GET | yes | no | medium |
| 15 | Creator | `creator.search` | GET | no | no | high |
| 16 | Creator | `tag.getFeatured` | GET | no | no | medium |
| 17 | Creator | `creator.getStartComments` | GET | yes | no | **low** |
| 18 | Plans/Support | `plan.listSupporting` | GET | yes | no | high |
| 19 | Plans/Support | `plan.listCreator` | GET | no | no | high |
| 20 | Plans/Support | `legacy/support/creator` | GET | yes | no | high |
| 21 | Comments | `post.getComments` | GET | optional | no | high |
| 22 | Comments | `post.addComment` | POST | yes | yes | high |
| 23 | Comments | `post.deleteComment` | POST | yes | yes | high |
| 24 | Comments | `post.likeComment` | POST | yes | yes | high |
| 25 | Comments | `post.listComments` (legacy) | GET | optional | no | medium (deprecated) |
| 26 | Notifications | `bell.list` | GET | yes | no | high |
| 27 | Notifications | `bell.countUnread` | GET | yes | no | high (shape: medium) |
| 28 | Notifications | `user.countUnreadMessages` | GET | yes | no | high |
| 29 | Notifications | `notification.getSettings` | GET | yes | no | medium |
| 30 | Notifications | `notification.updateSettings` | POST | yes | yes | medium |
| 31 | Newsletters | `newsletter.list` | GET | yes | no | medium |
| 32 | Newsletters | `newsletter.countUnread` | GET | yes | no | medium |
| 33 | Newsletters | `newsletter.markAsReadAll` | POST | yes | yes | **low** |
| 34 | Payments | `payment.listPaid` | GET | yes | no | high |
| 35 | Payments | `payment.listUnpaid` | GET | yes | no | medium |
| 36 | Follow | `follow.create` | POST | yes | yes | high |
| 37 | Follow | `follow.delete` | POST | yes | yes | high |
| 38 | Creator mgmt | `post.listManaged` | GET | yes | no | medium |
| 39 | Creator mgmt | `post.getEditable` | GET | yes | no | high |
| 40 | Creator mgmt | `post.create` | POST | yes | yes | medium |
| 41 | Creator mgmt | `post.update` | POST (multipart) | yes | yes (`tt`) | high |
| 42 | Creator mgmt | `post.delete` | POST | yes | yes | medium |
| 43 | Uploads | (unknown upload endpoint) | ? | yes | yes? | **low** |
| 44 | Fans | `relationship.listFans` | GET | yes | no | high |
| 45 | Fans | `relationship.listFilterOptions` | GET | yes | no | high |
| 46 | Fans | `relationship.getFan` | GET | yes | no | **low** |
| 47 | Fans | `legacy/manage/supporter/user` | GET | yes | no | medium |
| 48 | Dashboard | `legacy/manage/pledge/monthly` | GET | yes | no | medium |
| 49 | Dashboard | `legacy/payout_request` | GET | yes | no | medium |

Media hosts (`downloads.fanbox.cc`, `pixiv.pximg.net`) are covered in §1.9. Legacy and unverified names are listed in §21.

---

## 4. Session

### 4.1 GET `https://www.fanbox.cc/` — page metadata (CSRF, current user)

- **Method / URL:** `GET https://www.fanbox.cc/`. Any www.fanbox.cc HTML page carries the same tag: cssxsh used `/user/settings`, and yogthot uses `/manage/dashboard`.
- **Auth:** the cookie is optional; logged-out users get `userId: null`. **CSRF:** no. **Confidence:** high.
- **Params:** none.
- **Response:** HTML. Parse `meta[name=metadata]` (it also has `id="metadata"`), HTML-unescape the `content` attribute, and JSON-decode it into [Metadata](#214-metadata-meta-namemetadata-on-wwwfanboxcc).
- **Pagination:** none.
- **Notes:**
  - No JSON API endpoint returns the current user's profile. This page is the only source, and every client uses it.
  - Use it for: the CSRF token; `isCreator`, `creatorId` and `planCount` (to enable Creator Mode, and as the `creatorId` for `plan.listCreator`); `hasUnpaidPayments` (paymentAttention, §18.8); and `userId` (Account.pixivUserID).
  - A `302` from a www page means logged out. A `403` with the `cf-mitigated` header means a Cloudflare challenge (yogthot).
  - `isMailAddressOutdated: true`: post pages may redirect to `/email/reactivate` (nantas, low).
  - On iOS, read it from inside the account's WKWebView by evaluating JS on the loaded page, rather than fetching the HTML natively (§1.11; inferred).
- **Sources:** fankt (FanboxMetaDataEntity.kt, FanboxMetadataHtmlFixtures.kt, FanboxKsoupMetadataExtractor.kt, Fanbox.kt `updateCsrfToken`), Flare (FanboxService.kt, FanboxModels.kt), lifegpc (fanbox_api.rs), cssxsh (MetaData.kt, FanBoxUser.kt, FanBoxApi.kt), PixivUtil2 (PixivBrowserFactory.py), yogthot fansync (FanboxClient.cs `TestCookie`), old PixiView (FanboxRepository.kt), nantas (low).

### 4.2 Session validity probes

| Probe | Logged in | Logged out / invalid | Source |
|---|---|---|---|
| `GET api.fanbox.cc/bell.countUnread` | 200 `{ body: { count } }` | 401 = bad FANBOXSESSID, 400 = no cookie (konnokai) | konnokai, piep, Pixiv-Shaft, mtwtkman |
| `GET api.fanbox.cc/user.countUnreadMessages` | 200 `{ body: int }` | 400 `{ error: "general_error" }` (fc-downloader, live 2026-06-07) | fc-downloader |
| `GET api.fanbox.cc/plan.listSupporting` | 200 | error (status not recorded) | hareku `ValidateSession` |
| www page metadata | `context.user.userId` set | `userId: null`, or 302 on `/manage/*` | fankt, yogthot |
| `plan.listCreator?userId=official` | — | — | Bakabase (cookie check only; `userId` is deprecated) |

App policy: the cheapest check is `bell.countUnread`, and it also feeds the badge. Treat a Cloudflare HTML 403 as "unknown", never as "logged out".

---

## 5. Timeline

### 5.1 `post.listHome`

- **Method / URL:** `GET https://api.fanbox.cc/post.listHome?limit={n}[&maxPublishedDatetime={dt}&maxId={postId}]`
- **Auth:** required (401 when logged out, per Pixiv-Shaft). **CSRF:** no. **Confidence:** high.
- **Purpose:** the home timeline, with posts from followed and supported creators.

| Param | In | Type | Req | Notes |
|---|---|---|---|---|
| `limit` | query | int | no | Clients use 10 (gallery-dl, Pixiv-Shaft, PFD docs, and Magelon's captured nextUrl), 20 (fankt) or 30 (fc-downloader) |
| `maxPublishedDatetime` | query | string | no | Cursor copied from `nextUrl`. The real 2026-04 capture has `YYYY-MM-DD HH:MM:SS` in **JST local time**, URL-encoded |
| `maxId` | query | string | no | Cursor copied from `nextUrl` |
| `firstPublishedDatetime`, `firstId` | query | string | no | fankt and Flare forward these if a cursor URL has them. They have never been seen in a listHome `nextUrl` |

```jsonc
{ "body": { "items": [PostListItem], "nextUrl": string | null } }
// empty: { "body": { "items": [], "nextUrl": null } }
```

- **Pagination:** a cursor in `body.nextUrl`: an absolute api.fanbox.cc URL, or null at the end. Newest first. The bound is **inclusive**: in the Magelon capture, the cursor names the first post of the *next* page, which is not on the current page. GET `nextUrl` verbatim, after checking its host.
- **Notes:** the 2026 wrapping did not change this endpoint. Items have no `isPinned`. fc-downloader treats `isRestricted: true` as "this viewer cannot access it". No source shows whether listHome cursors moved to `first*` keys after July 2026.
- **Sources:** Magelon (GetHomePagePosts.json, GetHomePagePosts-NextUrl.json, FanboxClient.cs), fankt (FanboxEndpoints.kt `homePosts`, FanboxPostListEntity.kt, fixtures), gallery-dl (FanboxHomeExtractor), Flare (FanboxResources.kt), Pixiv-Shaft (FanboxApi.kt), fc-downloader (index.ts), lifegpc, FanboxViewer, PFD docs/fanbox.md.

### 5.2 `post.listSupporting`

- **Method / URL:** `GET https://api.fanbox.cc/post.listSupporting?limit={n}[&maxPublishedDatetime={dt}&maxId={postId}]`
- **Auth:** required. **CSRF:** no. **Confidence:** high.
- **Purpose:** a timeline of posts from creators the user supports.
- **Params:** the same as `post.listHome`. `limit` is 10 in gallery-dl, PFD, PixivUtil2 and Magelon.

```jsonc
{ "body": { "items": [PostListItem], "nextUrl": string | null } }
```

- **Pagination:** the same as `post.listHome`.
- **Notes:** PixivUtil2's code from 2026-07-27, written after the July wrapping, still reads `body.items` and `body.nextUrl`, so this endpoint is unchanged. PixivUtil2 filters items by the creator ids that `plan.listSupporting` returns.
- **Sources:** fankt (`supportingPosts`), PFD (API.ts `getPostListSupporting`, CrawlResult.d.ts, changelog 4.4.0), PixivUtil2 (commit fc0f9adf), gallery-dl (FanboxSupportingExtractor), Flare, Magelon, lifegpc, FanboxViewer.

### 5.3 `post.paginateCreator`

- **Method / URL:** `GET https://api.fanbox.cc/post.paginateCreator?creatorId={creatorId}[&sort=newest]`
- **Auth:** not required for public creators (peach, gallery-dl), though Cloudflare may still challenge. **CSRF:** no. **Confidence:** high.
- **Purpose:** returns every page cursor URL for a creator's post list, all at once. The website has paginated this way since at least 2024-08.

| Param | In | Type | Req | Notes |
|---|---|---|---|---|
| `creatorId` | query | string | **yes** | The creator's handle. cssxsh (2023) also had a `userId` variant |
| `sort` | query | string | no | pixivdwn (2026-09) sends `newest`. moontaiworks types `newest` and `oldest`. Most clients send only `creatorId` |

```jsonc
// CURRENT (since 2026-07-22)
{ "body": { "pageUrls": [string] } }
// LEGACY
{ "body": [string] }
```

- **Pagination:** every element is an absolute `post.listCreator` URL for 10 posts, and page 1 is the newest. An empty list means the creator has no posts. gallery-dl's offset option assumes 10 posts per page.
- **Page-URL query layouts (treat the URLs as opaque):**
  - (a) Older captures (Magelon from before 2026-04; hoordu 2026-06): `creatorId`, `maxPublishedDatetime` (JST `YYYY-MM-DD HH:MM:SS`), `maxId`, `limit=10`.
  - (b) The fankt fixture from 2026-07-15 onward, and peach (2026-08): `creatorId`, `firstPublishedDatetime` (ISO with offset, URL-encoded), `firstId`, `sort`, `limit=10`.
- **Notes:**
  - When fankt rebuilds a request from a page URL it drops `sort`, so `sort` may be optional.
  - PFD keeps every 30th URL and rewrites `limit=10` to `limit=300`. Do not do that (§5.4).
  - hoordu saw pinned posts inside these pages and errors when more than one appears.
- **Sources:** fankt (FanboxCreatorPostsPaginateEntity.kt, commits 6a392feb and ccbc0ae4, FanboxResponseEnvelopeTest.kt, the `paginateCreatorNormal` fixture, openspec creator-post-pagination), hareku (official_api_response.go, issue #103), PFD (changelog 4.9.4 and 4.4.0, InitPageBase.ts), Magelon (GetCreatorPostPagination.json, commit 975581fa), PixivUtil2 (commit 6c04e333), pixivdwn (commit 1526d58e), peach (follow_sources.py), fc-downloader (normalize.ts), ValerianDillon, piep, Flare, hoordu, gallery-dl.

### 5.4 `post.listCreator`

- **Method / URL:** `GET https://api.fanbox.cc/post.listCreator?creatorId={creatorId}&limit={n}[&firstPublishedDatetime=..&firstId=..&sort=newest | &maxPublishedDatetime=..&maxId=..]`
- **Auth:** not required for public listings (peach). The cookie is needed to get `isRestricted` right for the viewer. **CSRF:** no. **Confidence:** high.
- **Purpose:** one page of a creator's post summaries.

| Param | In | Type | Req | Notes |
|---|---|---|---|---|
| `creatorId` | query | string | **yes** | The old host used `userId` |
| `limit` | query | int | no | Page URLs use 10. PFD docs (2024) say the maximum is 300 and higher values give HTTP 400. moontaiworks uses 300 and piep 100. peach capped itself at 10 after seeing 10 per page on 2026-08-27. **Use 10.** |
| `firstPublishedDatetime` | query | string | no | Current cursor style: ISO with offset. moontaiworks passes a post's `publishedDatetime` and treats the bound as inclusive |
| `firstId` | query | string | no | Paired with `firstPublishedDatetime` |
| `sort` | query | string | no | `newest` (moontaiworks, pixivdwn); `oldest` is typed only by moontaiworks |
| `maxPublishedDatetime` | query | string | no | Legacy cursor, JST `YYYY-MM-DD HH:MM:SS` |
| `maxId` | query | string | no | Legacy cursor |
| `withPinned` | query | `"true"` | no | Sent only by PFD's `getPostListByUser`. **Low** confidence |

```jsonc
// CURRENT (since 2026-07-22)
{ "body": { "posts": [PostListItem] } }        // items include isPinned
// LEGACY 2024-08 .. 2026-07
{ "body": [PostListItem] }
// BEFORE 2024-08
{ "body": { "items": [PostListItem], "nextUrl": string | null } }
```

- **Pagination:** the response has no `nextUrl`. Either use the `pageUrls` from `post.paginateCreator`, or build an inclusive `firstId`/`firstPublishedDatetime` cursor from the last item and drop the duplicate first item of the next page (moontaiworks).
- **Pinned posts:** `isPinned: true` items can be out of date order. hareku keeps paging past already-downloaded pinned posts, and pixivdwn ignores pinned posts when detecting already-seen posts (commit 657758aa). §19 does the same.
- **Sources:** fankt (FanboxCreatorPostListEntity.kt, `creatorPosts`, the `postListCreatorNormal` fixture, 6a392feb), hareku (`ListCreatorResponse`, `IsPinned`), PFD (changelog 4.9.3, 4.4.0 and 1.9.0; CrawlResult.d.ts; docs), Magelon (GetCreatorPostsFromPagination.json), pixivdwn, ValerianDillon, PixivUtil2 (`parsePosts`), moontaiworks (creator-list-posts.ts, discover-posts.ts), peach, fc-downloader, piep, Flare.

### 5.5 `post.listTagged`

- **Method / URL:** `GET https://api.fanbox.cc/post.listTagged?tag={tag}[&creatorId={creatorId}][&page={n}]`
- **Auth:** no. **CSRF:** no. **Confidence:** medium.
- **Purpose:** posts with a given tag (the creator's `/tags/{tag}` page).

| Param | In | Type | Req | Notes |
|---|---|---|---|---|
| `tag` | query | string (URL-encoded) | **yes** | |
| `creatorId` | query | string | no | gallery-dl and pixiv-cli always send it, fankt makes it optional, and Flare never sends it. Older clients (PFD, FanboxViewer, cssxsh) send a numeric `userId` instead |
| `page` | query | int (0-based) | no | fankt and Flare send it, and read the next page number from `nextUrl` |

```jsonc
{ "body": { "count": int, "items": [PostListItem], "nextUrl": string | null } }
// DISAGREEMENT: pixiv-cli (rewritten 2026-08-18) decodes body.posts. Accept both items and posts.
```

- **Pagination:** `body.nextUrl`; fankt extracts its `page=N`.
- **Notes:** PFD's 2024 changelog says the tag listing kept its shape when listCreator changed. There is no post-July-2026 capture.
- **Sources:** fankt (`taggedPosts`, FanboxPostSearchEntity.kt), Flare (`listTaggedPosts`), gallery-dl (FanboxTagExtractor, 2026-02-25), PFD (API.ts, CrawlResult.d.ts `TagPostList`), pixiv-cli (posts.go, wire.go), FanboxViewer, cssxsh.

---

## 6. Post

### 6.1 `post.info`

- **Method / URL:** `GET https://api.fanbox.cc/post.info?postId={postId}`
- **Auth:** the cookie is optional. Anonymous calls return free/public posts, and FANBOXSESSID is needed for paid content. **CSRF:** no. **Confidence:** high.
- **Purpose:** the full post detail. The body is filled in only when the viewer is entitled to it.

| Param | In | Type | Req | Notes |
|---|---|---|---|---|
| `postId` | query | string (numeric) | **yes** | |

```jsonc
// CURRENT (since 2026-07-13)
{ "body": { "post": PostDetail } }
// LEGACY
{ "body": PostDetail }
```

- **Pagination:** none. `prevPost` and `nextPost` give the neighbouring posts.
- **Notes:**
  - **This is the endpoint Cloudflare guards most heavily.** Since 2026-04 it has been blocked for non-browser clients (§1.7). Pixiv-Shaft always gets 403 over OkHttp and uses a WebView. peach got 403 or `{error:"general_error"}` over plain HTTPX even with a valid cookie, and 200 with curl_cffi. PixivUtil2 switches to curl_cffi for this call only. The app should use the **WebView transport** (§1.11).
  - A restricted post returns **200** with `isRestricted: true` and `body: null`. That is normal, not an error.
  - hareku #101 (2026-07-19, low confidence) reports that under suspected bot detection, paying users got `isRestricted: true` with no body instead of 401 or 403. If an account that should be entitled gets a restricted response, re-check it later through the WebView before believing it.
  - Blocks may reference ids that are missing from their maps (§2.4).
  - Comments are no longer embedded here (removed around 2024-09-18: PixiView-KMP 7d905c95 and PR #21). Use `post.getComments`.
  - Rate limit: §1.8. Skip items that are already known to be restricted.
- **Sources:** Magelon (GetPostInfo.json: a real restricted article, wrapped by hand on 2026-07-16), fankt (FanboxPostDetailEntity.kt, d4d218e7, fixtures, openspec article-text-blocks, article-url-embeds, article-embed-blocks), PFD (changelog 4.9.2, CrawlResult.d.ts, docs), hareku (`PostInfoResponse` accepts both shapes), pixivdwn (3529cda3), PixivUtil2 (`fanboxUpdatePost`, `fanboxGetPostJsonById`), Flare (unwraps `post`), moontaiworks (post-info.ts, 7278c109), fc-downloader (normalize.ts), ValerianDillon (requires `body.post`), pixiv-cli (wire.go), lifegpc (url_embed.rs), Pixiv-Shaft, peach (docs/reference-snapshots), gallery-dl and danbooru (legacy shape), RSSHub #21699, #19430 and #19724.

### 6.2 `post.get`

- **Method / URL:** `GET https://api.fanbox.cc/post.get?postId={postId}`
- **Auth:** unknown; both sources send the normal cookie. **CSRF:** no. **Confidence:** medium.
- **Purpose:** post metadata without the content. Pixiv-Shaft falls back to it when `post.info` is blocked, because it still returns 200 over OkHttp. hoordu uses it to find the creator of a post embedded with `serviceProvider: "fanbox"`.

| Param | In | Type | Req |
|---|---|---|---|
| `postId` | query | string | **yes** |

```jsonc
// CURRENT (Pixiv-Shaft)
{ "body": { "post": {
    "id": string, "title": string, "feeRequired": int, "publishedDatetime": string,
    "tags": [string], "likeCount": int, "commentCount": int, "isRestricted": bool,
    "user": UserRef, "creatorId": string, "hasAdultContent": bool,
    "cover": { "url": string, ... } | null, "excerpt": string
    // no "body", no "type"
} } }
// LEGACY (hoordu, before 2026-07): { "body": { ...same metadata... } }
```

- **Notes:** the wrapper probably changed on the same day as `post.info` (inferred). It is unknown whether it works for a creator's own drafts.
- **Sources:** Pixiv-Shaft (FanboxApi.kt `postGet`, FanboxWebBridge.kt), hoordu (`POST_EMBED_INFO_URL`), Pixiv-Reader-MD3 (derived; not independent).

### 6.3 `post.likePost`

- **Method / URL:** `POST https://api.fanbox.cc/post.likePost`
- **Auth:** required. **CSRF:** **yes** (`x-csrf-token`). **Confidence:** high.

| Param | In | Type | Req | Notes |
|---|---|---|---|---|
| `postId` | body (JSON) | string | **yes** | `Content-Type: application/json`, body `{"postId": "..."}` |

```jsonc
{ "body": <undocumented> }     // every source ignores it (fankt/Flare return Unit)
```

- **Notes:** **No unlike endpoint** appears in any source, so a like is one-way in the app. Show the like state from `isLiked` and `likeCount`.
- **Sources:** fankt (`likePost`, TrustedFanboxEndpointPolicy.kt), Flare (FanboxResources.kt, `FanboxPostIdRequest`), matsumo article.

### 6.4 `tag.search`

- **Method / URL:** `GET https://api.fanbox.cc/tag.search?q={query}`
- **Auth:** no. **CSRF:** no. **Confidence:** medium.
- **Purpose:** tag suggestions and search.

| Param | In | Type | Req |
|---|---|---|---|
| `q` | query | string | **yes** |

```jsonc
{ "body": [ { "value": string, "count": int } ] }     // genuinely a bare array (fankt envelope test)
```

- **Notes:** no endpoint for searching posts by keyword appears in any source. Keyword search in the app runs over the local library (SPEC §33).
- **Sources:** fankt (FanboxTagListEntity.kt, FanboxResponseEnvelopeTest.kt `tagListIsGenuinelyABareArray`), matsumo article (not independent).

---

## 7. Creator

### 7.1 `creator.get`

- **Method / URL:** `GET https://api.fanbox.cc/creator.get?creatorId={creatorId}`, or `?userId={numericUserId}`
- **Auth:** no; the cookie gives the correct `isFollowed` and `isSupported`. **CSRF:** no. **Confidence:** high.

| Param | In | Type | Req | Notes |
|---|---|---|---|---|
| `creatorId` | query | string | one of the two | |
| `userId` | query | string (numeric pixiv id) | one of the two | PixivUtil2 uses it when the id is all digits |

```jsonc
{ "body": Creator }     // NOT wrapped (fankt real capture 2026-07-15/16, after the post.info change)
```

- **Notes:** `body.user.userId` is the `creatorUserId` that `follow.create` and `follow.delete` need.
- **Sources:** fankt (FanboxCreatorDetailEntity.kt; fixtures `actualCreatorGet` and `actualDerivedCreatorGetWithVideoProfileItem`), PFD (API.ts `getUserId`, CrawlResult.d.ts `CreatorData`), PixivUtil2 (`fanboxGetArtistById`), gallery-dl (`_get_user_data`), moontaiworks (models/creator.ts), Flare, hoordu, danbooru, FanboxViewer, fc-downloader.

### 7.2 `creator.listFollowing`

- **Method / URL:** `GET https://api.fanbox.cc/creator.listFollowing`
- **Auth:** required. **CSRF:** no. **Confidence:** high.
- **Purpose:** the creators the user follows. This also includes supported creators whose support is stopped but still valid until the end of the month.
- **Params:** none.

```jsonc
// CURRENT (since ~2026-04)
{ "body": { "creators": [Creator] } }
// LEGACY
{ "body": [Creator] }
```

- **Pagination:** none; one list.
- **Notes:** moontaiworks alone types the elements as a flat summary; that is probably wrong. PixivUtil2's FOLLOWING mode looks broken on the current shape (inferred from its code). This endpoint is the main source for the app's supportChanged diff (§18.8), through `isSupported` and `isStopped`.
- **Sources:** fankt (FanboxCreatorListEntity.kt, 5fb15169), PFD (changelog 4.9.0, `ListFollowing`), Magelon (GetFollowedCreators.json), hareku (creator_id_lister.go, 6d3cf951), pixivdwn (`fetch_following_list`), fc-downloader (accepts both), moontaiworks, Flare, PixivUtil2, cssxsh.

### 7.3 `creator.listRecommended`

- **Method / URL:** `GET https://api.fanbox.cc/creator.listRecommended?limit={n}`
- **Auth:** optional; logged-out users get generic recommendations (Pixiv-Shaft). **CSRF:** no. **Confidence:** high.

| Param | In | Type | Req | Notes |
|---|---|---|---|---|
| `limit` | query | int | no | 10 (Pixiv-Shaft) or 20 (fankt) |

```jsonc
{ "body": { "creators": [Creator] } }     // fankt modeled a bare array before 2026-04-13
```

- **Sources:** fankt (`recommendedCreators`), Flare, Pixiv-Shaft, FanboxViewer, mtwtkman (ListRecommended.hs, 2023), Magelon (its payload file is hand-made).

### 7.4 `creator.listPixiv`

- **Method / URL:** `GET https://api.fanbox.cc/creator.listPixiv`
- **Auth:** required. **CSRF:** no. **Confidence:** medium.
- **Purpose:** FANBOX creators whom the user follows on pixiv.

```jsonc
{ "body": { "creators": [Creator] } }     // per fankt since 2026-04-13; no real payload anywhere
```

- **Sources:** fankt (`followingPixivCreators`), Magelon (FanboxClient.cs), cssxsh (FanBoxCreator.kt `LIST_PIXIV`).

### 7.5 `creator.search`

- **Method / URL:** `GET https://api.fanbox.cc/creator.search?q={query}&page={n}`
- **Auth:** no. **CSRF:** no. **Confidence:** high.

| Param | In | Type | Req | Notes |
|---|---|---|---|---|
| `q` | query | string | **yes** | |
| `page` | query | int (0-based) | no | |

```jsonc
{ "body": { "creators": [Creator], "count": int /* total hits */, "nextPage": int | null } }
```

- **Pagination:** a page number taken from `body.nextPage`, which is null on the last page. The real payload had 50 creators per page (count 109, nextPage 1).
- **Sources:** Magelon (SearchCreators.json, real), fankt (FanboxCreatorSearchListEntity.kt), Flare, mtwtkman (Search.hs).

### 7.6 `tag.getFeatured`

- **Method / URL:** `GET https://api.fanbox.cc/tag.getFeatured?creatorId={creatorId}`
- **Auth:** no. **CSRF:** no. **Confidence:** medium.
- **Purpose:** a creator's featured tags.

| Param | In | Type | Req | Notes |
|---|---|---|---|---|
| `creatorId` | query | string | **yes** | cssxsh also had a `userId` variant |

```jsonc
{ "body": { "featuredTags": [ { "tag": string, "count": int, "coverImageUrl": string | null } ] } }
// DISAGREEMENT: pixiv-cli expects a bare array or { tags: [ { tag, url } ] }. Accept all three.
```

- **Sources:** fankt (FanboxCreatorTagListEntity.kt, b8dd76e6), ValerianDillon (reads `body.featuredTags`), cssxsh (TagFeature.kt), FanboxViewer, pixiv-cli (tags.go).

### 7.7 `creator.getStartComments` — **low**

- **Method / URL:** `GET https://api.fanbox.cc/creator.getStartComments`
- **Auth:** required (assumed). **CSRF:** no. **Confidence:** low.
- **Response:** cssxsh decodes `body` as a map from string to lists of `UserRef`.
- **Purpose:** unknown. The name suggests the messages supporters leave when they start supporting (inferred). No current client uses it, so do not implement it in v1.0.
- **Sources:** cssxsh (FanBoxCreator.kt, 2023).

---

## 8. Plans / Support

### 8.1 `plan.listSupporting`

- **Method / URL:** `GET https://api.fanbox.cc/plan.listSupporting`
- **Auth:** required. **CSRF:** no. **Confidence:** high.
- **Purpose:** the plans the user is actively paying for, with the payment method of each. hareku also uses it to validate the session.

```jsonc
// CURRENT (since ~2026-07-14)
{ "body": { "plans": [Plan] } }
// LEGACY
{ "body": [Plan] }
// OLDER (PixivUtil2 still checks)
{ "body": { "supportingPlans": [Plan] } }
```

- **Notes:**
  - **Disagreement:** piep (2026-09-13) still decodes a bare array. That is probably a stale path in piep. Accept all three shapes anyway.
  - A creator whose support was stopped but is valid until month end, or who was downgraded to free, may be **missing here** while still appearing in `creator.listFollowing` with `isSupported` or `isStopped` (fc-downloader). Compute support state from both endpoints (§18.10).
  - No transaction id appears here. Transactions are in `legacy/support/creator`.
  - fankt maps `paymentMethod` case-insensitively (§18.9).
- **Sources:** Magelon (GetSupportingPlans.json, 02ed2e60), pixivdwn (`fetch_supporting_list`, 3529cda3), hareku (official_api_client.go `ValidateSession`, issue #101), fankt (FanboxCreatorPlanListEntity.kt, 6a392feb, ccbc0ae4), PFD (`AllSupportingPlan`, SaveFanCard.ts, changelog 5.1.0), moontaiworks (5394e201), PixivUtil2 (`parseArtistCreatorIDs`), fc-downloader, piep, fanbox-archiver, cssxsh.

### 8.2 `plan.listCreator`

- **Method / URL:** `GET https://api.fanbox.cc/plan.listCreator?creatorId={creatorId}`
- **Auth:** no; with the cookie, `paymentMethod` is filled in for the viewer's plan. **CSRF:** no. **Confidence:** high.
- **Purpose:** a creator's plans, as shown on the paywall. A creator also uses it to read their own plans (the `/manage/plans` page calls it).

| Param | In | Type | Req | Notes |
|---|---|---|---|---|
| `creatorId` | query | string | **yes** | For your own plans, use `context.user.creatorId` from the metadata |
| `userId` | query | string | — | **DEPRECATED** around 2025-04/05: yogthot 3998a75a ("userId was deprecated"), and hideki0403 PR #2 moved its hook to `creatorId`. Do not use |

```jsonc
// CURRENT (since ~2026-07-16)
{ "body": { "plans": [Plan] } }
// LEGACY (and cromachina's userId form)
{ "body": [Plan] }
```

- **Notes:**
  - In the real Magelon payload, `paymentMethod` is `"PAYPAL"` only on the plan the viewer pays for and `null` on the other plan. That supports "filled only for the viewer's active plan" (medium).
  - No owner-only fields have been observed. For per-plan supporter counts, use `relationship.listFilterOptions`.
  - Plan covers live at `pixiv.pximg.net/c/936x600_90_a2_g5/fanbox/public/images/plan/{planId}/cover/{key}.jpeg`.
  - gallery-dl's `_get_plan_data` iterates the body as a list, so it breaks on the new shape.
- **Sources:** Magelon (GetCreatorSupportingPlans.json, real), fankt (`creatorPlans`, fixture `actualCreatorPlanList`, envelope test), hideki0403 (schema/plans.ts, capture/def.ts, PR #2), ValerianDillon, Pixiv-Shaft, FanboxViewer, yogthot fansync (`GetPlans`, CHANGELOG 2.2.0.0), moontaiworks (creator-list-plans.ts), cromachina, Bakabase, defaultcf spec branch, gallery-dl.

### 8.3 `legacy/support/creator`

- **Method / URL:** `GET https://api.fanbox.cc/legacy/support/creator?creatorId={creatorId}`. The path segment is `legacy/support/creator`, not a dotted name.
- **Auth:** required. **CSRF:** no. **Confidence:** high.
- **Purpose:** the viewer's own support details for one creator: the current plan, the support start date, every payment, and the Fan Card background image.

| Param | In | Type | Req |
|---|---|---|---|
| `creatorId` | query | string | **yes** |

```jsonc
{ "body": {
    "plan": Plan,
    "supportStartDatetime": string,          // ISO, e.g. +09:00
    "supporterCardImageUrl": string,         // 1280 px Fan Card background
    "supportReservations": [],               // only ever seen empty; probably convenience-store 支援予約 (inferred)
    "supportTransactions": [SupportTransaction]
} }
```

- **Notes:**
  - The same `targetMonth` can appear more than once: a mid-month upgrade pays the difference as a separate payment (Help 26030583672217).
  - A PFD code comment says automatic renewals were usually charged around 10:00 on the 2nd of the month (anecdotal).
  - What it returns for a creator you do not support is undocumented; treat 404 as "no support" (inferred).
  - This endpoint is the main source for the app's Support History (SPEC §11).
- **Sources:** fankt (FanboxCreatorPlanDetailEntity.kt, `creatorPlanDetail`), PFD (API.ts `getSupportingPlanForOneCreator`, CrawlResult.d.ts `SupportInfo`, SaveFanCard.ts; used since 2025-12-29, fixed on 2026-09-07), old PixiView (FanboxTranslator.kt), Help 26030583672217.

---

## 9. Comments

### 9.1 `post.getComments`

- **Method / URL:** `GET https://api.fanbox.cc/post.getComments?postId={postId}&offset={n}&limit={n}`
- **Auth:** optional for public posts. Needed for FANs-only posts and to get meaningful `isLiked` and `isOwn` (Help 360004254334). **CSRF:** no. **Confidence:** high.
- **Purpose:** the comment threads on a post, with replies nested. Creators use the same endpoint for their own posts.

| Param | In | Type | Req | Notes |
|---|---|---|---|---|
| `postId` | query | string | **yes** | |
| `offset` | query | int | no | Starts at 0. fankt, Flare and PFD always send it; gallery-dl and Pixiv-Shaft leave it out on page 1 and follow `nextUrl` |
| `limit` | query | int | no | Seen: 10 (gallery-dl, fanbox-archiver), 20 (fankt, Pixiv-Shaft, Pixiv-Reader-MD3), 50 (PFD). Maximum unknown |

```jsonc
{ "body": {
    "viewMode": string,                         // only "OPEN" seen
    "commentList": { "items": [Comment], "nextUrl": string | null }
} }
```

- **Pagination:** offset-based through `body.commentList.nextUrl`, an absolute URL such as `post.getComments?postId=X&offset=42&limit=7` (Flare test). fankt reads `offset` from it. PFD also stops when a page returns fewer than `limit` items. The offset probably counts **root threads**, because replies come nested (inferred).
- **Notes:**
  - fankt (e5af450d, 2025-04-17) and gallery-dl (7b30aab5, 2025-04-19) both moved here from `post.listComments` within two days.
  - gallery-dl made comment extraction non-fatal in 2026-01 (issue #8814) because the call can fail.
  - gallery-dl fetches comments only when `commentCount > 0`. Do the same.
  - No creator moderation flag such as `canDelete` has been observed.
- **Sources:** fankt (`postComments`, FanboxCommentListEntity.kt, FanboxPostCommentListEntity.kt, FanboxPostMapper.kt, the `postCommentsFlat` fixture, e5af450d), gallery-dl (`_get_comment_data`, 7b30aab5), Flare (FanboxResources.kt, FanboxTimelineLoaders.kt, FanboxCommentsLoaderTest.kt), Pixiv-Shaft, Pixiv-Reader-MD3, PFD (API.ts `getPostComments`, `CommentData`), fanbox-archiver, PixiView-KMP (PostDetailViewModel.kt), Help 360004254334.

### 9.2 `post.addComment`

- **Method / URL:** `POST https://api.fanbox.cc/post.addComment`, `Content-Type: application/json`
- **Auth:** required. **CSRF:** **yes**. **Confidence:** high. The sources are all from one author (matsumo0922), but the library is current and ships in PixiView-KMP.

| Param | In | Type | Req | Notes |
|---|---|---|---|---|
| `postId` | body | string | **yes** | |
| `body` | body | string | **yes** | Comment text. PixiView-KMP blocks sending more than 1000 characters; the server's limit is unknown |
| `rootCommentId` | body | string | see notes | Reply: the target's `rootCommentId` if it is not `"0"`, otherwise the target's own `id`. Root comment: `"0"` |
| `parentCommentId` | body | string | see notes | Reply: the target's `id` (a root or a reply). Root comment: `"0"` |

```jsonc
{ "body": <undocumented> }    // no source reads it; fankt maps it to Unit; the old PixiView checks 2xx only
```

- **Root-comment convention:** both PixiView generations (2023–2026, fankt 0.1.3) send `"0"`/`"0"` in production. fankt ≥ 0.1.0 *omits* both keys when the caller passes null; its test checks the request body, but its real-service tasks are still unchecked. **Send `"0"`/`"0"`**, which production has used.
- **After a POST, re-fetch `post.getComments`** to show the new comment (PixiView-KMP).
- **Rules (Help 54418828998297, 4442406551705):**
  - Commenting on a FANs-only post needs an active support.
  - A creator's block disables commenting.
  - `isCommentingRestricted: true` on the post means commenting is off.
  - A creator can set `commentingPermissionScope` (§14.4).
- **Offline reply queue (SPEC §22; our own inference):** the endpoint takes no idempotency key. When a send times out, the state becomes `needsConfirmation`. Before retrying, re-fetch `post.getComments` and look for an own comment (`isOwn`) with the same text and a recent `createdDatetime`.
- **Sources:** fankt (`addComment`, FanboxCommentSubmissionTest.kt, openspec comment-submission and 2026-07-24-make-comment-parent-ids-nullable), PixiView-KMP (PostDetailCommentSection.kt, FanboxRepository.kt, PostDetailViewModel.kt), old PixiView (FanboxRepository.kt, PostDetailCommentSection.kt), matsumo article.

### 9.3 `post.deleteComment`

- **Method / URL:** `POST https://api.fanbox.cc/post.deleteComment`, JSON
- **Auth:** required. **CSRF:** **yes**. **Confidence:** high (matsumo0922 ecosystem only, but current).

| Param | In | Type | Req |
|---|---|---|---|
| `commentId` | body | string | **yes** |

```jsonc
{ "body": <undocumented> }   // any 2xx = success; re-fetch comments afterwards
```

- **Notes:** PixiView-KMP shows the delete action only when `isOwn` is true. Whether a creator can delete *other users'* comments on their own posts is **unverified**. For that case, use the web UI through the WebView. Blocking a commenter uses pixiv's block feature; there is no FANBOX API for it.
- **Sources:** fankt (`deleteComment`, TrustedFanboxEndpointPolicy.kt, FanboxResponses.kt), PixiView-KMP, old PixiView, matsumo article.

### 9.4 `post.likeComment`

- **Method / URL:** `POST https://api.fanbox.cc/post.likeComment`, JSON
- **Auth:** required. **CSRF:** **yes**. **Confidence:** high (matsumo0922 only).

| Param | In | Type | Req |
|---|---|---|---|
| `commentId` | body | string | **yes** |

```jsonc
{ "body": <undocumented> }
```

- **Notes:** **No unlike endpoint** exists in any source, so the like is one-way. The comment author is presumably notified through `post_comment_like` (inferred from the setting `bell_post_comment_like`).
- **Sources:** fankt (`likeComment`), old PixiView, matsumo article, PixiView-KMP.

### 9.5 `post.listComments` — legacy, deprecated

- **Method / URL:** `GET https://api.fanbox.cc/post.listComments?postId={postId}&offset={n}&limit={n}`
- **Confidence:** medium. **Do not build on it.**

```jsonc
{ "body": { "items": [Comment], "nextUrl": string | null } }    // flat older shape
```

- **Notes:**
  - Used by cssxsh (2023), the old PixiView, gallery-dl (2024-10-06 to 2025-04-19) and fankt (until 2025-04-17). gallery-dl and fankt both dropped it in the same week.
  - fanbox-archiver still tries it as a fallback, with `offset=0&limit=10`.
  - The app may call it only as a last-resort fallback in Research Mode.
- **Sources:** cssxsh (FanBoxPost.kt, CommentList.kt, CommentInfo.kt), old PixiView, matsumo article, fankt e5af450d, gallery-dl 8553a831 and 7b30aab5, fanbox-archiver.

---

## 10. Notifications (bell)

### 10.1 `bell.list`

- **Method / URL:** `GET https://api.fanbox.cc/bell.list?page={n}&skipConvertUnreadNotification={0|1}&commentOnly={0|1}`
- **Auth:** required. **CSRF:** no. **Confidence:** high.
- **Purpose:** the notification feed behind the bell icon.

| Param | In | Type | Req | Notes |
|---|---|---|---|---|
| `page` | query | int | no | **Counts from 1.** PixiView-KMP starts at 1, FanboxViewer and FanboxD request `page=1`, and fankt's real page-one capture has `nextUrl` ending in `page=2`. fankt's own default is 0; its effect is unverified. Magelon sends no page on the first request (unverified) |
| `skipConvertUnreadNotification` | query | 0 or 1 | no | `0`: the server **marks the returned unread items as read**, and fankt says this cannot be undone through its API. `1`: leave them unread. **The app sends `1` for every poll** and never marks items read behind the user's back (fankt ≥ 0.1.0 does the same). PixiView-KMP sends 0 on purpose |
| `commentOnly` | query | 0 or 1 | no | `1` returns comment notifications only (FanboxViewer, Magelon). The 2023 matsumo article writes `commentId`, which is a typo |
| `limit` | query | int | no | Sent only by Magelon (default 10). Its fixture is synthetic, and the real capture had 20 items. Unverified; do not send it |

```jsonc
{ "body": { "items": [Bell], "nextUrl": string | null } }   // nextUrl e.g. https://api.fanbox.cc/bell.list?page=2
```

- **Pagination:** by page number; fankt reads `page` from `nextUrl`. Magelon's synthetic `lastId`-style nextUrl conflicts with the real capture; ignore it.
- **Notes:**
  - Known types: `on_post_published` (real capture) and `post_comment` / `post_comment_like` (handcrafted fixtures, handled in production by PixiView). The mapping to app events is in §18.8.
  - fankt's mapper throws on any other type. **The app must keep unknown types** as `other` and record the raw string.
  - Creator-side events such as support start, new follower and post like must exist, because the matching settings exist (§18.7), but their type strings are unknown.
  - FanboxD (2023) modeled every item with a non-null `post`.
- **Sources:** fankt (`bells`, FanboxBellListEntity.kt, FanboxUserMapper.kt, FanboxUserJsonFixtures.kt, Fanbox.kt `getBells` KDoc, openspec notification-read-state, FanboxBellReadStateTest.kt), PixiView-KMP (FanboxRepository.kt, LibraryNotifyPagingSource.kt, Bell.kt), old PixiView (FanboxBellItemsEntity.kt, FanboxTranslator.kt), FanboxViewer (FanboxAPI.java, FanboxParser.kt), FanboxD, Magelon (GetNotification.json, synthetic), matsumo article.

### 10.2 `bell.countUnread`

- **Method / URL:** `GET https://api.fanbox.cc/bell.countUnread`
- **Auth:** required. **CSRF:** no. **Confidence:** high for the endpoint, medium for the shape (the readers of `body.count` date from 2023).

```jsonc
{ "body": { "count": int } }
```

- **Notes:** it doubles as a cheap session check (§4.2). Pixiv-Shaft reports 200 over OkHttp with only FANBOXSESSID and Origin. FanboxViewer read `count` at the top level from the pre-2020 host; that is outdated. **This is the app's cheapest "anything new?" poll:** call `bell.list` only when the count changed or a sync is due.
- **Sources:** cssxsh (FanBoxBell.kt), mtwtkman (CountUnread.hs, ValidateSessionId.hs), konnokai (Program.cs), piep (`check_session`), Pixiv-Shaft (class doc), FanboxViewer.

### 10.3 `user.countUnreadMessages`

- **Method / URL:** `GET https://api.fanbox.cc/user.countUnreadMessages`
- **Auth:** required. **CSRF:** no. **Confidence:** high.

```jsonc
{ "body": int }                          // logged in (a bare number)
// logged out: HTTP 400 { "error": "general_error" }  (fc-downloader, live 2026-06-07)
```

- **Notes:** the Help Center (4514696329625) says FANBOX messaging uses pixiv's messaging feature, so this most likely counts **pixiv direct messages**, not newsletters (inferred). Do not use it as the newsletter badge.
- **Sources:** fc-downloader (index.ts `checkAuth`, docs/spec/service-abstraction.md), cssxsh (FanBoxUser.kt), FanboxViewer, Help 4514696329625.

### 10.4 `notification.getSettings`

- **Method / URL:** `GET https://api.fanbox.cc/notification.getSettings`
- **Auth:** required. **CSRF:** no. **Confidence:** medium (2023 and 2020 sources only; no current client).

```jsonc
{ "body": { [settingKey]: bool } }     // keys: §18.7
```

- **Notes:** the Help Center (360018253253, 360018102654) describes website and email notifications, and says important emails are sent even when every setting is off. Web settings page: `/notifications/settings`.
- **Sources:** cssxsh (FanBoxNotification.kt, Notification.kt), FanboxViewer, Help 360018253253, 360018102654 and 360013904933.

### 10.5 `notification.updateSettings`

- **Method / URL:** `POST https://api.fanbox.cc/notification.updateSettings`, JSON
- **Auth:** required. **CSRF:** **yes**. **Confidence:** medium (cssxsh, 2023).

| Param | In | Type | Req | Notes |
|---|---|---|---|---|
| `type` | body | string | **yes** | A setting key (§18.7), e.g. `bell_post_comment` |
| `value` | body | string `"1"` or `"0"` | **yes** | One key per call |

```jsonc
{ "body": string | null }     // cssxsh decodes it as a nullable string
```

- **Notes:** FanboxViewer (2020) posts a raw string body of unknown shape. Prefer the web settings page, and treat native support as optional.
- **Sources:** cssxsh (FanBoxNotification.kt), FanboxViewer.

---

## 11. Newsletters (おたより)

### 11.1 `newsletter.list`

- **Method / URL:** `GET https://api.fanbox.cc/newsletter.list`
- **Auth:** required. **CSRF:** no. **Confidence:** medium. The envelope is confirmed as a bare array; the element fields come from a handcrafted fixture and the old PixiView entity (2023), both by the same author.
- **Purpose:** the newsletter inbox: announcements that supported or followed creators sent to the viewer.
- **Params:** none.

```jsonc
{ "body": [NewsLetter] }     // genuinely a bare array (fankt envelope test, commit ccbc0ae4, 2026-08-02)
```

- **Pagination:** none seen. Every client fetches the full list in one request.
- **Notes:**
  - A creator sends a newsletter to one of four audiences (Help 900003410886): all FANs and followers; all FANs; FANs of one plan, optionally filtered by cumulative months at that tier or above; or followers only. Eligibility is evaluated when it is sent.
  - PixiView-KMP shows these on its "Messages" screen.
- **Sources:** fankt (FanboxNewsLetterListEntity.kt, FanboxResponseEnvelopeTest.kt, FanboxUserJsonFixtures.kt `handcraftedNewsletterList`, `newsletters`), old PixiView (FanboxNewsLattersEntity.kt), PixiView-KMP (LibraryMessageViewModel.kt), matsumo article, Help 900003410886.

### 11.2 `newsletter.countUnread`

- **Method / URL:** `GET https://api.fanbox.cc/newsletter.countUnread`
- **Auth:** required. **CSRF:** no. **Confidence:** medium (one source from 2023).

```jsonc
{ "body": int }
```

- **Sources:** cssxsh (FanBoxNewsLetter.kt).

### 11.3 `newsletter.markAsReadAll` — **low**

- **Method / URL:** `POST https://api.fanbox.cc/newsletter.markAsReadAll`, JSON body `{}`
- **Auth:** required. **CSRF:** **yes**. **Confidence:** low.

```jsonc
{ "body": <unknown> }
```

- **Notes:** Magelon marks its implementation Obsolete, with a note that it needs a CSRF token it cannot get. It has never been exercised with a token. **No endpoint marks a single newsletter read or fetches a single newsletter.** The app therefore keeps its own read state locally and never calls markAsReadAll automatically.
- **Sources:** Magelon (FanboxClient.cs).

---

## 12. Payments

### 12.1 `payment.listPaid`

- **Method / URL:** `GET https://api.fanbox.cc/payment.listPaid`
- **Auth:** required. **CSRF:** no. **Confidence:** high.
- **Purpose:** the history of completed charges (決済履歴).

```jsonc
// CURRENT (seen by 2026-06-28)
{ "body": { "payments": [PaidRecord] } }
// LEGACY (cssxsh 2023, old PixiView): bare array; creator also had isActive
{ "body": [PaidRecord] }
```

- **Pagination:** none; the whole history comes in one response.
- **Notes:**
  - Records carry no plan id and no target month. For per-month detail, use `legacy/support/creator`.
  - The nushell script groups records by `paymentDatetime` to total each charge, and separately by `creatorId`, which fits monthly batch billing.
  - It sends only Origin and FANBOXSESSID, with a comment that the API refuses requests without Origin.
- **Sources:** fankt (FanboxPaidRecordListEntity.kt, FanboxPaymentJsonFixtures.kt, a3947705), nushell script (a5a81ba5), cssxsh (FanBoxPayment.kt, PaidRecord.kt, CreatorActive.kt), old PixiView (FanboxPaidRecordEntity.kt).

### 12.2 `payment.listUnpaid`

- **Method / URL:** `GET https://api.fanbox.cc/payment.listUnpaid`
- **Auth:** required. **CSRF:** no. **Confidence:** medium.
- **Purpose:** outstanding or unpaid payments. `context.user.hasUnpaidPayments` in the metadata says whether there are any.

```jsonc
{ "body": { "payments": [PaidRecord] } }     // ASSUMED from listPaid (fankt decodes both with one type; no fixture)
// legacy decoders expected: { "body": [PaidRecord] }
```

- **Notes:** it is unclear which cases produce unpaid records (an unpaid convenience-store bill? a failed card charge?). The app shows only the observed fact, per SPEC §15: "決済状態を確認できない".
- **Sources:** fankt (FanboxEndpoints.kt, FanboxResponses.kt), cssxsh (FanBoxPayment.kt), old PixiView.

---

## 13. Follow

### 13.1 `follow.create`

- **Method / URL:** `POST https://api.fanbox.cc/follow.create`, JSON
- **Auth:** required. **CSRF:** **yes**. **Confidence:** high.

| Param | In | Type | Req | Notes |
|---|---|---|---|---|
| `creatorUserId` | body | string (numeric pixiv user id) | **yes** | **Not** the `creatorId` handle. Get it from `creator.get` → `body.user.userId`. Send it as a JSON **string**, which fankt's test enforces |

```jsonc
{ "body": <ignored> }     // any 2xx = success
```

- **Notes:** read the new state back from `creator.get` (`isFollowed`, `isSupported`).
- **Rules (Help):** supporting a creator you follow turns "followed" into "supporting", and after support stops the status becomes "following" again. A creator's pixiv block removes the follow and prevents following again (54418828998297).
- **Sources:** fankt (`followCreator`, FanboxFollowCreatorSubmissionTest.kt), Flare (FanboxResources.kt, FanboxModels.kt `FanboxFollowRequest`, FanboxProfileLoaders.kt), old PixiView, matsumo article, Help 360003723653, 54418828998297 and 360000230381.

### 13.2 `follow.delete`

- **Method / URL:** `POST https://api.fanbox.cc/follow.delete`, JSON
- **Auth:** required. **CSRF:** **yes**. **Confidence:** high.
- **Params:** the same as `follow.create` (`creatorUserId`).

```jsonc
{ "body": <ignored> }
```

- **Notes:** **unfollowing does not stop a paid support.** Stopping support is only possible in the web plan and payment flow (SPEC §14).
- **Sources:** fankt (`unfollowCreator`, FanboxFollowCreatorSubmissionTest.kt), Flare, old PixiView.

---

## 14. Creator-side management (posts)

All endpoints in this section need an account where `context.user.isCreator` is true. Use the **WebView transport** for them (§1.11): none of them has been tested from a non-browser client since the 2026-04 Cloudflare change.

### 14.1 `post.listManaged`

- **Method / URL:** `GET https://api.fanbox.cc/post.listManaged`
- **Auth:** required. **CSRF:** no. **Confidence:** medium (one author: the defaultcf spec, fanbox-go and fanboxsync).
- **Purpose:** every post the creator owns, both drafts and published posts.
- **Params:** no source defines any query parameters.

```jsonc
{ "body": [EditablePost] }    // one flat array; no nextUrl, no cursor
```

- **Pagination:** none known. It is unknown whether the server caps or paginates a long history.
- **Notes:**
  - fanboxsync treats list items as stubs and calls `post.getEditable` for every id. The app calls `getEditable` **only when a post is opened**, never for all of them (SPEC §3.7).
  - The spec requires Origin and User-Agent, and returns 400 `{"error":"general_error"}` when credentials are missing.
  - fanboxsync sends a non-browser UA (`fanboxsync/<version>`). Whether that still works behind Cloudflare is unknown.
- **Sources:** defaultcf spec (generated/openapi.yaml `/post.listManaged`, `components.responses.List`, `schemas.Post`), fanboxsync (fanbox.go `GetPosts`, cmd.go), fanbox-go (oas_client_gen.go).

### 14.2 `post.getEditable`

- **Method / URL:** `GET https://api.fanbox.cc/post.getEditable?postId={postId}`
- **Auth:** required. **CSRF:** no. **Confidence:** high (defaultcf 2024 and cromachina 2022 are independent).
- **Purpose:** one of your own posts, drafts included, in editable form, to prefill the editor or to round-trip into `post.update`.

| Param | In | Type | Req |
|---|---|---|---|
| `postId` | query | string | **yes** |

```jsonc
{ "body": EditablePost }
```

- **Notes:**
  - No source shows the editable shape of non-article posts. By analogy with `post.info`: image = `text` + `images`, file = `text` + `files`, text = `text`, video = `text` + `video` (inference only).
  - **Cloudflare:** Pixiv-Shaft's comment says that since 2026-04 this endpoint is blocked for non-browser clients just like `post.info`. Nobody has confirmed that independently. Use the WebView transport.
- **Sources:** defaultcf spec (`/post.getEditable`, `schemas.Post`), fanboxsync (fanbox.go `GetPost`, entry.go `ConvertPost`), cromachina @21ef099 (`get_editable_post`, `convert_post`), Pixiv-Shaft (FanboxWebBridge.kt class doc, FanboxApi.kt), RSSHub #21699.

### 14.3 `post.create`

- **Method / URL:** `POST https://api.fanbox.cc/post.create`, JSON
- **Auth:** required. **CSRF:** **yes** (the header). **Confidence:** medium (one author).
- **Purpose:** creates an empty **draft** and returns its id. The title, content, fee and status are then set with `post.update`.

| Param | In | Type | Req | Notes |
|---|---|---|---|---|
| `type` | body | string | **yes** | The spec only lists `article`, and fanboxsync only sends `article`. `image`, `file`, `text` and `video` are plausible because the web UI offers them, but they are **unverified** here |

```jsonc
{ "body": { "postId": string } }
```

- **Notes:** fanboxsync's create command calls `post.update` immediately afterwards with status `draft`, fee `"0"` and the title.
- **Sources:** defaultcf spec (`/post.create`, `requestBodies.Create`, `responses.Create`), fanboxsync (fanbox.go `CreatePost`, cmd.go `CommandCreate`).

### 14.4 `post.update`

- **Method / URL:** `POST https://api.fanbox.cc/post.update`, **`multipart/form-data`** (defaultcf spec, fanbox-go). cromachina 2022 used `application/x-www-form-urlencoded`, and that also worked at the time.
- **Auth:** required. **CSRF:** **yes, via the form field `tt`**. The spec declares only cookie security for this endpoint, with no `X-CSRF-Token` header. Also sending the header is probably harmless (inferred). **Confidence:** high.
- **Purpose:** saves a post's title, content, fee, tags, comment permission and publish status. It is used to save a draft, publish and unpublish.

| Field | In | Type | Req | Notes |
|---|---|---|---|---|
| `postId` | multipart | string | **yes** | |
| `status` | multipart | `draft` or `published` | no | Publish = `published`. Unpublish = back to `draft` (inferred from the enum; untested) |
| `feeRequired` | multipart | string (integer yen) | no | `"0"` = public. Posts are gated by a minimum fee; no source shows a `planId` field |
| `title` | multipart | string | no | |
| `commentingPermissionScope` | multipart | `everyone`, `supporters` or `none` | effectively yes | Added in spec commit 00a8df23 (2025-03-08), titled "fix: post update with new property", so updates probably fail without it. fanboxsync sends `supporters` when the fee is above 0 and `everyone` otherwise |
| `body` | multipart | string holding JSON | no | The JSON of the **blocks array only**, not an object (fanboxsync and cromachina). Send `[]` rather than `null` for an empty body. **Omit `styles`** on paragraphs that have none; fanboxsync says an empty styles array must not be sent |
| `tags` | multipart | string, repeated | no | The spec encodes it as a repeated form field. fanboxsync always sends an empty list. cromachina (2022) sent one field holding a JSON array string. At most 6 tags per post (Help 26439413791257). Whether omitting it keeps or clears the tags is unknown |
| `tt` | multipart | string | **yes** | The anti-CSRF token, which is the same value as `metadata.csrfToken` (fanboxsync uses its configured csrf token; cromachina's hard-coded 32-hex value matches the token format) |

```jsonc
// success
{ "body": EditablePost }
// failure (often with no reason)
{ "error": "general" }
// missing credentials
HTTP 400 { "error": "general_error" }
```

- **Fields not seen in any source:** `planId`, cover image, scheduled publish time (the web UI has scheduled posting), a per-post adult flag, `imageMap` or `fileMap` on write, `excerpt`, content for non-article types, a visibility field. **Do not invent them.** Leave those features to the web editor at `/manage/posts/{postId}`.
- **Offsets:** fanboxsync counts style offset and length in **Unicode code points** (Go runes), while fankt and Pixiv-Shaft document **UTF-16 code units**. The two only differ for characters outside the BMP, such as emoji. Until this is verified, the native editor either blocks bold styles on text containing non-BMP characters, or falls back to the web editor for it (our policy).
- **App scope (proposal):** native publishing covers article posts built from `p` and `header` blocks. Posts with images or files go through the web editor, because the upload API is unknown (§15).
- **Sources:** defaultcf spec (`/post.update` security, `requestBodies.Update`, 00a8df23), fanbox-go (oas_request_encoders_gen.go), fanboxsync (fanbox.go `PushPost`, `convertJson`; entry.go `ConvertFanbox`; config.go `csrf_token`), cromachina @21ef099 (`post_update`, `convert_post`) and issue #3, Pixiv-Shaft (link offset note).

### 14.5 `post.delete`

- **Method / URL:** `POST https://api.fanbox.cc/post.delete`, JSON
- **Auth:** required. **CSRF:** **yes** (the header). **Confidence:** medium (one author).

| Param | In | Type | Req |
|---|---|---|---|
| `postId` | body | string | **yes** |

```jsonc
{ "body": null }
```

- **Notes:** deletion is permanent. The app always asks for explicit confirmation and never retries automatically.
- **Sources:** defaultcf spec (`/post.delete`, `requestBodies.Delete`, `responses.Delete`), fanboxsync (fanbox.go `DeletePost`).

---

## 15. Uploads

### 15.1 Post image / file / cover upload — **UNKNOWN (low)**

- **Method / URL:** unknown. Names such as `post.uploadImage` or `post.uploadFile` are **guesses**, not observations.
- **Auth:** required. **CSRF:** presumably yes. **Confidence:** low.
- **Searched on 2026-09-24:** GitHub code search for uploadImage, listManaged, getEditable and post.create combined with "fanbox", plus a repository search. No client that uploads to FANBOX was found; the only hit (an S3 helper in HakataArchiver) is unrelated.
- **What is known, from the read side:**
  - The image map entry is `{ id, extension, width, height, originalUrl, thumbnailUrl }`, and the file map entry is `{ id, name, extension, size, url }`.
  - Stored post images live under `downloads.fanbox.cc/images/post/{postId}/{hash}.{ext}`, and covers under `pixiv.pximg.net/fanbox/public/images/post/{postId}/cover/{hash}.{ext}`. Uploads are therefore probably tied to an existing `postId` (inference).
- **Limits (Help 360011057793, updated 2026-09-17):**
  - Images: jpg, jpeg, png, gif. Audio: mp3, wav, flac. Video: mp4, mov, avi. Other: zip, pdf, txt, psd, clip.
  - Up to **300 MB** per file. Post covers and creator-page covers up to **30 MB**.
- **App policy:** the Upload Queue (SPEC §20) prepares media locally (resize and convert). The actual upload runs in the WebView editor at `/manage/posts/{postId}` until the endpoint has been captured from the user's **own** browser session in Research Mode (Web Bridge network observation).
- **Sources:** danbooru (url/fanbox.rb, storage paths), Pixiv-Shaft (FanboxImage and FanboxFile fields), Help 360011057793.

---

## 16. Fans

### 16.1 `relationship.listFans`

- **Method / URL:** `GET https://api.fanbox.cc/relationship.listFans?status={status}[&planId={planId}]`
- **Auth:** required (creator). **CSRF:** no. **Confidence:** high (seen in 8 projects).
- **Purpose:** the creator's fans, i.e. supporters and/or followers, with their plan, start date and memo. This is the data behind `www.fanbox.cc/manage/relationships`.

| Param | In | Type | Req | Notes |
|---|---|---|---|---|
| `status` | query | `supporter`, `follower` or `all` | treat as **yes** | Every tool sends it. `supporter` is universal. `all` appears in the defaultcf branch, JanMaki and the yogthot README; `follower` in the defaultcf branch and JanMaki |
| `planId` | query | string | no | Filters to one plan (defaultcf branch, JanMaki). JanMaki's URL builder leaves out the `&` before `planId`, which is a bug in that code; the correct form is `&planId=` |

```jsonc
{ "body": [Fan] }     // bare array
```

- **Pagination:** none observed. Every tool reads a single array: 0kqnet counts supporters as its length. It is unknown whether very large fan counts are capped.
- **Notes:**
  - 累計月数 (total months) appears on the web list when it is filtered by plan, but no JSON field for it has been observed; 0kqnet scrapes it from the DOM.
  - No endpoint edits `note`.
  - kozukaccd warns to pull this only about monthly. The app pulls it on demand, at most about once a day (§1.8).
  - kozukaccd (Playwright), 0kqnet (bookmarklet) and hideki0403 (puppeteer) all call it from inside a logged-in page.
- **Sources:** hideki0403 (capture/def.ts, schema/relationships.ts, api.ts), kozukaccd (README, fetch-supporters.js), 0kqnet (fanbox-supporters-withapi.js), cromachina (`get_all_users`), JanMaki (ListFans.kt, FanData.kt, StatusType.kt), axtuki1 (fanbox/index.ts), yogthot fansync (`GetSupporters`, README), defaultcf spec branch feature/add-relationships (relationships.yaml, Relationship.yaml).

### 16.2 `relationship.listFilterOptions`

- **Method / URL:** `GET https://api.fanbox.cc/relationship.listFilterOptions`
- **Auth:** required (creator). **CSRF:** no. **Confidence:** high (JanMaki 2023 and axtuki1 2025 are independent).
- **Purpose:** the filter options for the fan list, **with a head count per plan**. This is the only known source of per-plan supporter counts, and axtuki1 also uses it to list the creator's plan ids.

```jsonc
{ "body": [FilterOption] }     // entries with planId != null are per-plan supporter buckets
```

- **Notes:** it drives the Creator Dashboard's "支援者数" (SPEC §17): the sum of the plan buckets, or the `supporter` entry.
- **Sources:** JanMaki (ListFilterOptions.kt, FilterOptionData.kt), axtuki1 (fanbox/index.ts `getPlanList`).

### 16.3 `relationship.getFan` — **low**

- **Method / URL:** `GET https://api.fanbox.cc/relationship.getFan?userId={userId}`
- **Auth:** required (creator). **CSRF:** no. **Confidence:** low.

| Param | In | Type | Req |
|---|---|---|---|
| `userId` | query | string (pixiv user id) | **yes** |

```jsonc
{ "body": { "status": "supporter" | "follower", "user": UserRef,
            "activedAt": string /* probably really activatedAt */, "note": string
            /* planId probably present too (unverified) */ } }
```

- **Notes:** its only source is an **unmerged** 2024-09 spec branch. No client calls it, and a code search finds nothing. For per-fan detail, use `legacy/manage/supporter/user`.
- **Sources:** defaultcf spec branch feature/add-relationships (relationships.yaml, responses/relationships/Get.yaml).

### 16.4 `legacy/manage/supporter/user`

- **Method / URL:** `GET https://api.fanbox.cc/legacy/manage/supporter/user?userId={userId}`
- **Auth:** required (creator). **CSRF:** no. **Confidence:** medium (one archived source).
- **Purpose:** the creator's view of one fan: their current plan and full payment history to that creator. It is the creator-side counterpart of `legacy/support/creator`.

| Param | In | Type | Req |
|---|---|---|---|
| `userId` | query | string (the fan's pixiv user id) | **yes** |

```jsonc
{ "body": {
    "user": { "userId": string, "name": string, "iconUrl"?: string },
    "supportingPlan": { "id": string, /* ...Plan fields */ } | null,
    "supportTransactions": [ {
        "id"?: string,
        "paidAmount": int,                 // yen
        "transactionDatetime": string,     // ISO-8601, e.g. +09:00
        "targetMonth": string              // "YYYY-MM"
    } ]                                    // newest first (the bot takes the LAST element as the oldest)
} }
// HTTP 404 = no supporter record for this user
```

- **Notes:**
  - cromachina treats 401 and 403 as an invalid session.
  - Transactions do not say which plan was bought, so the bot maps amounts to plans by fee.
  - Summing `paidAmount` per `targetMonth` accounts for upgrade-difference payments.
  - The `legacy/` prefix suggests an older surface that could disappear.
- **Sources:** cromachina (main.py `get_user`, `compute_role`, CSV export; test.py; README), fankt (FanboxCreatorPlanDetailEntity.kt, the fan-side analogue).

---

## 17. Dashboard (creator earnings)

There is no JSON endpoint known for the `/manage/dashboard` page itself; yogthot only uses that page as a session probe. Per SPEC §17, the Creator Dashboard is composed from what *can* be fetched:

| Dashboard figure | Source |
|---|---|
| Supporters (total and per plan) | `relationship.listFilterOptions` (§16.2) |
| Support received this month | `legacy/manage/pledge/monthly?month=<current>` (sum of `paidAmount`) |
| Transferable balance, monthly totals and fees, next payout | `legacy/payout_request` |
| Post count | `post.listManaged` (count of `published`) |
| Comments | `bell.list` with `commentOnly=1`, or per-post `commentCount` |

Nothing may be shown as a number unless it came from one of these. Estimates must be labelled `estimated` (SPEC §17).

### 17.1 `legacy/manage/pledge/monthly`

- **Method / URL:** `GET https://api.fanbox.cc/legacy/manage/pledge/monthly?month={YYYY-MM}`
- **Auth:** required (creator). **CSRF:** no. **Confidence:** medium.
- **Purpose:** every support payment received in one month, i.e. the creator's monthly earnings detail (支援金詳細).

| Param | In | Type | Req |
|---|---|---|---|
| `month` | query | string `YYYY-MM` | **yes** |

```jsonc
{ "body": {
    "supportTransactions": [ {
        "id": string,
        "supporter": UserRef,
        "paidAmount": int,               // yen
        "paymentMethod": string,         // values not enumerated
        "transactionDatetime": string,   // ISO-8601 with offset
        "targetMonth": string            // "YYYY-MM"
    } ],
    "nextMonth": string | null,          // "YYYY-MM"; null at the ends
    "previousMonth": string | null
} }
```

- **Pagination:** by month, using `nextMonth` and `previousMonth`. No paging within a month has been observed.
- **Notes:**
  - Two sources call the URL: JanMaki (2023, with the full response DTO) and yogthot (2024–25; the current importer no longer calls it). Only JanMaki documents the response.
  - The matching web page is `/manage/pledges/monthly/{YYYY-MM}` (vrct_supporters, 2026-09). Help 360004253894 describes it under 支援金管理/振込 → 支援金詳細.
  - Whether the 2026 Cloudflare rule covers this endpoint is unknown.
  - A new transaction id in the current month is a candidate `newSupporter` signal (§18.8).
- **Sources:** JanMaki (Monthly.kt, MonthlyData.kt, SupportTransactionData.kt, test GetSupportUser.kt), yogthot fansync (`GetPledges`), vrct_supporters (manifest.json, content.js; page URL only), Help 360004253894.

### 17.2 `legacy/payout_request`

- **Method / URL:** `GET https://api.fanbox.cc/legacy/payout_request`
- **Auth:** required (creator). **CSRF:** no. **Confidence:** medium (one source, 2023, before Cloudflare; unmaintained).
- **Purpose:** the payout and earnings summary: current transferable balance, monthly totals and fees, and the next automatic payout date.
- **Params:** none.

```jsonc
{ "body": {
    "maxPayoutRequestAmount": { "amount": int /* yen, transferable now */, "calculatedDatetime": string },
    "monthlyMaxPayoutRequestAmountHistory": [ {
        "targetMonth": string,               // "YYYY-MM-DD" (note: a full date here)
        "supportTotal": int,
        "paymentCharge": int,                // fees
        "maxPayoutRequestAmount": int,       // subtotal after fees
        "specialSales": [ /* element type unknown */ ]
    } ],
    "nextAutoPayoutDatetime": string,
    "notice": string | null
} }
```

- **Notes:**
  - JanMaki's test walks `monthlyMaxPayoutRequestAmountHistory[].targetMonth` and calls `pledge/monthly` for each month. The app does **not** do that (SPEC §3.7); it fetches a past month only when the user opens it.
  - It probably backs the web pages `/manage/payouts` and `/manage/payouts/history` (inferred).
  - No endpoint was found for requesting a payout or for payout-account settings. Those stay in the WebView.
- **Payout rules (Help 360005114953):**
  - A new pledge is added to the balance at once. Recurring charges run on the 1st–5th.
  - Automatic payout (定期振込) runs from the 20th, within 5 business days, and is carried over if the balance is under ¥5,000.
  - Early payout (お急ぎ振込) arrives within 5 business days and is not available for Wise.
  - Payout methods: bank transfer, PayPal, and Wise (automatic payout only).
- **Sources:** JanMaki (PayoutRequest.kt, data/payout_request/*.kt, test GetSupportUser.kt), Help 360005114953.

---

## 18. Enum tables

Every enum decodes unknown values to `.unknown(raw)` and keeps the raw string for Research Mode.

### 18.1 Post types (`PostDetail.type`)

| Value | Body fields | Rendering notes |
|---|---|---|
| `article` | `blocks`, `imageMap`, `fileMap`, `embedMap`?, `urlEmbedMap` | Rich blocks (§18.2) |
| `image` | `text`, `images: [Image]` | Gallery followed by text |
| `file` | `text`, `files: [File]` | Attachment list followed by text |
| `text` | `text` | Plain text |
| `video` | `text`, `video { serviceProvider, videoId }` | Provider link or player; providers in §18.5 |
| `entry` | `html` | Legacy HTML. Sanitize it. `<a href>` points to the original image and `<img src>` to the `/w/1200/` thumbnail |

PixivUtil2 supports exactly these six types. List items carry no type.

### 18.2 Article block types

| `type` | Fields | Reference |
|---|---|---|
| `p` | `text` (may be `""`; keep empty paragraphs as spacing), `styles`?, `links`? | — |
| `header` | `text`, `styles`?, `links`? | — |
| `image` | `imageId` | `imageMap[imageId]` → Image |
| `file` | `fileId` | `fileMap[fileId]` → File |
| `embed` | `embedId` | `embedMap[embedId]` → Embed |
| `url_embed` | `urlEmbedId` | `urlEmbedMap[urlEmbedId]` → UrlEmbed |

Captures often contain the unused keys (`text`, `imageId`, `fileId`, `urlEmbedId`) set to null.

### 18.3 List-item cover types

| `cover.type` | Notes |
|---|---|
| `cover_image` | The post's cover. PixivUtil2 uses `cover.url` only for this type |
| `post_image` | An image taken from the post body |

### 18.4 Text styles and links

| Field | Values | Notes |
|---|---|---|
| `styles[].type` | `bold` (the only value ever seen) | fankt keeps unknown values |
| `styles[]` | `{ type, offset, length }` | |
| `links[]` | `{ offset, length, url }` | |
| Offset unit | UTF-16 code units (fankt doc; Pixiv-Shaft, for links) vs Unicode code points (fanboxsync, when writing) | **Unresolved.** The two agree for BMP-only text. Swift: count with `String.utf16` for rendering, and verify before writing non-BMP text |

### 18.5 Embed and video providers

| `serviceProvider` | URL to open (as rebuilt by other clients) | Where |
|---|---|---|
| `twitter` | `https://twitter.com/_/status/{id}` (gallery-dl) or `https://x.com/i/web/status/{id}` (hoordu) | embedMap |
| `youtube` | `https://www.youtube.com/watch?v={id}` | embedMap, video posts, profileItems |
| `vimeo` | `https://vimeo.com/{id}` | embedMap, video posts |
| `soundcloud` | `https://soundcloud.com/{id}` | embedMap, video posts |
| `google_forms` | `https://docs.google.com/forms/d/e/{id}/viewform` (optionally `?usp=sf_link`) | embedMap |
| `fanbox` | `https://www.pixiv.net/fanbox/{contentId}`, a legacy redirect. The **last path segment** of `contentId` is the post id; resolve it with `post.get` (hoordu) | embedMap |
| `gist` | Only in PFD's type union | embedMap |

- When both `videoId` and `contentId` exist, `videoId` wins (fankt spec, gallery-dl).
- fankt's embed fixtures are synthetic, and fankt itself says the production `embedMap` schema is unproven.
- Video posts (`body.video.serviceProvider`) use `youtube`, `vimeo` and `soundcloud`.

### 18.6 URL embed types

| `type` | Fields | Notes |
|---|---|---|
| `default` | `url`, `host`? | `host` appears only in the 2022 PFD sample |
| `html` | `html` | iframely markup; **untrusted** |
| `html.card` | `html` | iframely card; **untrusted** |
| `fanbox.post` | `postInfo` | A post card; parse it tolerantly (§2.7) |
| `fanbox.creator` | `profile` (Creator) | lifegpc; Pixiv-Shaft names the type |

A Help Center search snippet lists many embeddable services: BOOTH, X, YouTube, Google Forms, Instagram, Spotify, Amazon, TikTok, Niconico, Facebook, SlideShare. Most of them arrive as `html` or `html.card`.

### 18.7 Notification setting keys (`notification.getSettings` / `updateSettings`)

From cssxsh (2023): `email_important_notices`, `email_announcements_from_fanbox`, `email_to_supporter_on_post_published`, `email_to_supporter_on_monthly_charge_success`, `email_to_creator_on_support_start`, `email_to_follower_on_post_published`, `email_to_fan_on_newsletter`, `bell_post_like`, `bell_post_comment`, `bell_post_comment_like`, `bell_support_start`, `bell_new_follower`, `bell_to_supporter_on_post_published`, `bell_to_follower_on_post_published`. Updates send `"1"` or `"0"`.

### 18.8 Bell types → app `NotificationEventType` (mapping suggestion)

The app enum is `NotificationEventType` in `FANBOXClient/Core/Models/DomainEnums.swift`: comment, commentReply, newPost, newsletter, supportChanged, paymentAttention, newSupporter, other.

**A. Events that come from `bell.list`:**

| FANBOX `type` | Condition | App event | Prefetch (SPEC §24.2 / §25) | Evidence |
|---|---|---|---|---|
| `on_post_published` | — | `newPost` | `post.info(post.id)`: text first, cover thumbnail later. Skip it when `post.isRestricted` | Real capture (high) |
| `post_comment` | `isRootComment == true` | `comment` | `post.getComments(postId)`, page 1 | Handcrafted fixture + production handling (medium) |
| `post_comment` | `isRootComment == false` | `commentReply` | `post.getComments(postId)`, page 1 | Same (medium) |
| `post_comment_like` | — | `other` | none (metadata only) | Handcrafted fixture (low) |
| *(creator-side type for support start, string unknown)* | when observed | `newSupporter` | `relationship.listFans?status=supporter` | Setting `bell_support_start` exists; type string unknown |
| *(new follower, post like: strings unknown)* | when observed | `other` | none | Settings `bell_new_follower` and `bell_post_like` exist |
| any other string | — | `other`, raw type stored | none | fankt throws on unknown types; we do not |

Magelon's `comment` type appears only in a synthetic test. No source has `post_comment_reply`.

**B. Events derived from diffs (no bell type exists):**

| App event | Detection | Source endpoints |
|---|---|---|
| `newsletter` | A new `id` in `newsletter.list` with `isRead == false`, compared with the local store | §11.1 (`newsletter.countUnread` as a cheap pre-check, medium) |
| `supportChanged` | Between snapshots: a plan was added or removed in `plan.listSupporting`, `fee`/`id` changed for the same creator, `paymentMethod` changed, or `isSupported`/`isStopped` flipped in `creator.listFollowing` | §8.1, §7.2 |
| `paymentAttention` | `context.user.hasUnpaidPayments` goes false → true; `payment.listUnpaid` is non-empty; a previously supported plan disappears **during the 1st–5th** of the month (Help: a failed automatic charge stops support) | §4.1, §12.2, §8.1. Per SPEC §15, show the observed fact only and never state that a payment failed |
| `newSupporter` (Creator Mode) | A new `userId` with `status == "supporter"` in `relationship.listFans`, or a new transaction id in this month's `legacy/manage/pledge/monthly` | §16.1, §17.1 (low-frequency polling) |

Dedupe across accounts (SPEC §27): the key is `(event type, postId, commentId or bell id)`. The same `on_post_published` for one post received by two accounts becomes one event with both account ids.

### 18.9 Payment methods (`paymentMethod`)

| API string (compare case-insensitively) | Meaning | Seen in |
|---|---|---|
| `card`, `CARD`, `gmo_card` | Credit card | fankt fixture (`card`), PFD type (`CARD`), old PixiView (`gmo_card`, 2023) |
| `paypal`, `PAYPAL` | PayPal | Magelon real payload (`PAYPAL`), old PixiView |
| `cvs`, `gmo_cvs` | Convenience store | fankt enum, old PixiView |
| *(unknown)* | pixivcoban, PayPal via bank account, others | The Help Center lists them; the API strings are unknown |
| `null` | The viewer does not pay for this plan | `plan.listCreator` |

fankt switched to case-insensitive matching of `card`, `paypal` and `cvs` in a2e42364 (2025-02-03). Anything else maps to `unknown(raw)`.

Help Center payment facts:
- Credit cards: Visa, Mastercard, JCB and American Express; VANDLE CARD prepaid is confirmed to work.
- Convenience store: Japan only, ¥120 fee per pledge.
- pixivcoban: Japan residents only.
- PayPal is not available for R-18 creators unless you had used PayPal on FANBOX before 2024-03-21 18:00 JST.

### 18.10 Fan / relationship statuses

| Where | Values | Notes |
|---|---|---|
| `relationship.listFans?status=` | `supporter`, `follower`, `all` | |
| `Fan.status` | `supporter`, `follower` | |
| `FilterOption.type` | `supporter`, `follower`, `all` | `planId` and `planTitle` are null outside plan buckets |
| Creator flags (fan side) | `isFollowed`, `isSupported`, `isStopped` | |

Suggested app-side support state, derived from those flags and `plan.listSupporting`:

| State | Rule |
|---|---|
| `supporting` | Plan present in `plan.listSupporting`, or `isSupported && !isStopped` |
| `stopping` | `isSupported && isStopped`: cancelled, still valid until month end (fc-downloader) |
| `following` | `isFollowed && !isSupported` |
| `none` | Otherwise |

Help Center billing facts that matter for `supportChanged`:
- **Support periods.** The first month runs from the start day to the end of that month. Automatic charges run on the 1st–5th. While "現在決済処理中です" is shown, plans cannot be changed.
- **Upgrade.** The difference is charged at once, the higher tier unlocks immediately, and a separate invoice is issued.
- **Downgrade.** It takes effect next month.
- **Stop.** The whole month is still charged, with no refund, and FANs-only posts stay visible until month end.
- **Failed automatic charge.** Support stops automatically. Supporting again in the same month keeps the Fan Card start date.
- **Timing.** A payment can take up to 15 minutes to show as active support.
- **Convenience store.** Prepaid months become 支援予約; while any exist, you cannot cancel, downgrade or change the payment method.
- **Deleted plan.** When the creator deletes a plan, the support stops and its supporters become followers (48515034524313).
- **Creator block.** An existing support lasts through the current month and is cancelled from next month.

### 18.11 Creator-side post enums

| Field | Values |
|---|---|
| `EditablePost.status` / `post.update status` | `draft`, `published` |
| `commentingPermissionScope` | `everyone`, `supporters`, `none` |
| `post.create type` | `article` (verified); `image`, `file`, `text`, `video` (unverified) |
| `feeRequired` | integer yen, sent as a string in `post.update`; 0 = public |

### 18.12 Datetime formats and page sizes

| Item | Format / value |
|---|---|
| API datetime fields | ISO-8601 with offset, e.g. `2025-02-08T12:00:00+09:00` |
| `maxPublishedDatetime` cursor | `YYYY-MM-DD HH:MM:SS` in **JST**, URL-encoded (legacy) |
| `firstPublishedDatetime` cursor | Apparently ISO with offset (the fankt fixture is anonymized) |
| `targetMonth` | `YYYY-MM` (support transactions); `YYYY-MM-DD` in `legacy/payout_request` history |
| `privacyPolicy.updateDate` | `YYYY-MM-DD` |
| Page sizes | 10 per `paginateCreator` page and on website timelines; `listCreator` historically allowed up to 300; 50 per page in `creator.search` |

---

## 19. Differential sync

This section implements SPEC §3.7 and §34: fetch the latest page, walk newest → oldest, **stop at a known post id**, and never run a full-history crawl.

### 19.1 General algorithm (all newest-first lists)

```
state = SyncState(accountID, resource)         // lastKnownItemID, cursor, lastSuccessfulSync
page  = first page (no cursor)
pages = 0
loop:
    for item in page.items:
        if item.isPinned == true: upsert(item); continue     // pinned posts are out of order - never a stop signal
        if knownIDs(account, resource).contains(item.id):
            refreshIfChanged(item)                           // compare updatedDatetime / isRestricted / commentCount
            STOP
        upsert(item)                                         // new item
    pages += 1
    if page.next == nil or pages >= maxPages(resource, mode): STOP
    page = GET page.next                                     // verbatim nextUrl or next pageUrl, host-checked
save lastKnownItemID = newest non-pinned id seen; lastSuccessfulSync = now
```

- **Inclusive cursors.** If a cursor is ever built by hand (`firstId`/`firstPublishedDatetime`), the first item of the next page repeats the last item of the previous one. Dedupe it by id. A plain id-set check already does this.
- **Edits.** Stop-at-known does not catch edits to older posts. For the known items that *are* on page 1, compare `updatedDatetime`. If it changed and the post body is cached, mark the post stale and re-fetch `post.info` when the post is next opened, or through the prefetch queue within the rate budget (§1.8).
- **Entitlement changes.** If `isRestricted` flips from true to false on a known item, the user started supporting. Queue a `post.info` for that item only. Older posts become readable too, but they are fetched **only when opened**, never backfilled.
- **Deletions.** Incremental sync cannot detect deleted posts. If an open post returns 404, mark it `unavailable`. Never delete the local cache because of network errors (SPEC §44).
- **First sync for an account or resource:** at most `maxPages`. There is no history backfill.
- **Suggested `maxPages`** (app policy): Normal = 3, Low Data = 1, Extreme = 1 (metadata only), Background = 1.
- **Multiple accounts.** Each account syncs its own timeline. Posts are deduped by `postId` across accounts, and the store keeps each account's `isRestricted` separately, so that SPEC §8 can choose an entitled account for `post.info`: one whose plan fee for that creator is ≥ `feeRequired`.

### 19.2 Per-endpoint rules

| Resource | Endpoint(s) | First page | Next page | Stop condition | Notes |
|---|---|---|---|---|---|
| Home timeline | `post.listHome?limit=10` | no cursor | `body.nextUrl` | known non-pinned id, `nextUrl == null`, or maxPages | Newest first. The cursor bound is inclusive |
| Supporting timeline | `post.listSupporting?limit=10` | no cursor | `body.nextUrl` | same | Optional: listHome already covers supported creators |
| Creator posts | `post.paginateCreator?creatorId=X` → `pageUrls[0]` → `post.listCreator` | `pageUrls[0]` | `pageUrls[1]`, `pageUrls[2]`… | known **non-pinned** id, or maxPages | **Re-fetch `paginateCreator` on every sync**: page boundaries are anchored to cursors and shift when new posts appear, so an old page-1 URL can miss new posts. Empty `pageUrls` = no posts; do not call listCreator |
| Tagged posts | `post.listTagged` | `page=0` | `nextUrl` | known id, or 1–2 pages | User-initiated only; never in background sync |
| Post comments | `post.getComments?postId=X&limit=20` | `offset=0` | `commentList.nextUrl` | Order undocumented: upsert every root and reply by id. Fetch further pages only when the user scrolls | Trigger it only when `commentCount` changed, a `post_comment` bell names this post, or the user opens the thread |
| Bell | `bell.countUnread` → `bell.list?page=1&skipConvertUnreadNotification=1&commentOnly=0` | `page=1` | `nextUrl` (`page=2`…) | known bell id, or `notifiedDatetime` ≤ the last-seen datetime | Poll `countUnread` first. Never send `skipConvertUnreadNotification=0` from sync |
| Newsletters | `newsletter.list` | whole list | — | — | Diff by `id`. New unread → `newsletter` event |
| Following / support | `creator.listFollowing`, `plan.listSupporting` | whole list | — | — | Snapshot diff → `supportChanged` / `paymentAttention` (§18.8) |
| Support history | `legacy/support/creator?creatorId=X` | per creator | — | — | Diff `supportTransactions` by `id`. Refresh on the support screen and after `supportChanged`, not on a schedule |
| Payments | `payment.listPaid`, `payment.listUnpaid` | whole list | — | — | Diff by `id`. Low frequency: at app launch in the first week of the month, and on demand |
| Creator: posts | `post.listManaged` | whole list | — | — | Diff by `id` + `updatedAt`. Call `getEditable` only when a post is opened |
| Creator: fans | `relationship.listFans?status=supporter` | whole list | — | — | Diff by `userId` + `planId` + `status` → `newSupporter`. At most about daily, and on demand |
| Creator: pledges | `legacy/manage/pledge/monthly?month=<current>` | current month | `previousMonth` only when the user navigates | — | Diff by transaction `id` |

---

## 20. Web fallback URLs

`WebBridgeDestination` in `FANBOXClient/Core/Web/WebBridge.swift` currently builds the URLs in the "Current code" column. The **Research status** column says whether this research found evidence for each URL. Every URL marked *unverified* should be checked by opening it in the account WebView (Research Mode) before release.

Until then the app does not rely on them blindly: when the first main-frame response of a requested page is 404 or 410, the account WebView switches to the next page of `WebDestination.fallbackSteps` (`FANBOXClient/Core/Web/WebDestination+Fallback.swift`) and says so in a banner. Every chain ends at a page marked **verified** below (plan → creator plans → creator page; payment settings → `payment.pixiv.net/cards` → user settings; payment history → invoices → user settings; supporting plans → home). Payment sessions also offer the same pages manually ("ページが表示されない場合"), because a single-page app may render "not found" with status 200.

| Purpose | URL | Current code | Research status |
|---|---|---|---|
| Home / metadata | `https://www.fanbox.cc/` | `.home` | **Verified** (many clients) |
| Login | `https://www.fanbox.cc/login` (expected to redirect to pixiv accounts) | `.login` | *Unverified*: every client logs in through a WebView, but none records the URL |
| Post page | `https://www.fanbox.cc/@{creatorId}/posts/{postId}`, or `https://{creatorId}.fanbox.cc/posts/{postId}` | `.post` | Medium: danbooru's URL parser knows both forms; PixivUtil2 and peach use the post page as Referer |
| Creator page | `https://www.fanbox.cc/@{creatorId}`, or `https://{creatorId}.fanbox.cc/` | `.creator` | **Verified** (yogthot redirect target, danbooru) |
| Creator tag page | `https://www.fanbox.cc/@{creatorId}/tags/{tag}` | — | Medium (the page behind `post.listTagged`) |
| Creator plans | `https://www.fanbox.cc/@{creatorId}/plans` | `.creatorPlans` | *Unverified* |
| Single plan | `https://www.fanbox.cc/@{creatorId}/plans/{planId}` | `.plan` | *Unverified* |
| Supporting plans list | `https://www.fanbox.cc/creators/supporting` | `.supportingPlans` | *Unverified* |
| Payment method settings | `https://www.fanbox.cc/user/settings/payment` | `.paymentSettings` | *Unverified*. The Help Center path is: plan page → "Update payment method" → "Pay with a credit card" → "Change card" (360008991393) |
| Card management (all pixiv cards) | `https://payment.pixiv.net/cards` | (use `.url`) | **Verified** (Help 360008991393) |
| Payment history | `https://www.fanbox.cc/user/payments` | `.paymentHistory` | *Unverified*. The Help Center only mentions a "payment history page" |
| Invoices | `https://www.fanbox.cc/invoices` | (use `.url`) | **Verified** (Help; available from the 1st of the following month) |
| User settings | `https://www.fanbox.cc/user/settings` | (use `.url`) | **Verified** (Help; cssxsh reads the metadata there) |
| Notification settings | `https://www.fanbox.cc/notifications/settings` | (use `.url`) | **Verified** (Help 360013904933) |
| Notifications list | `https://www.fanbox.cc/notifications` | `.notifications` | *Unverified* |
| Newsletter inbox | `https://www.fanbox.cc/messages[/{id}]` | `.newsletter` | *Unverified*. The Help Center mentions a "Newsletter Inbox" without a URL |
| Email reactivation | `https://www.fanbox.cc/email/reactivate` | — | Low (nantas) |
| pixiv id → creator | `https://www.pixiv.net/fanbox/creator/{pixivUserId}` (302 to `https://{creatorId}.fanbox.cc/`) | — | Medium (yogthot) |
| Legacy embedded post | `https://www.pixiv.net/fanbox/{contentId}` | — | Medium (hoordu) |
| **Creator: dashboard** | `https://www.fanbox.cc/manage/dashboard` | `.manageDashboard` | **Verified** (yogthot session probe) |
| Creator: posts | `https://www.fanbox.cc/manage/posts` | `.managePosts` | **Verified** (Help) |
| Creator: post editor | `https://www.fanbox.cc/manage/posts/{postId}` | `.managePostEditor(id)` | **Verified** (danbooru) |
| Creator: new post | `https://www.fanbox.cc/manage/posts/new` | `.managePostEditor(nil)` | *Unverified*. Safer: call `post.create` natively, then open `/manage/posts/{postId}` |
| Creator: featured tags | `https://www.fanbox.cc/manage/posts/featured` | — | Verified (Help) |
| Creator: fans | `https://www.fanbox.cc/manage/relationships` (filters `?status=`, `planId`) | `.manageRelationships` | **Verified** (Help, hideki0403, 0kqnet, kozukaccd) |
| Creator: one fan | `https://www.fanbox.cc/manage/relationships/{userId}` | — | Verified (0kqnet, vrct_supporters, FanboxEnumerator) |
| Creator: plans | `https://www.fanbox.cc/manage/plans` | `.managePlans` | **Verified** (Help, hideki0403, cromachina). Plan create, edit, delete and reorder exist only here |
| Creator: monthly pledges | `https://www.fanbox.cc/manage/pledges/monthly/{YYYY-MM}` | — | Verified (vrct_supporters, 2026-09) |
| Creator: payouts | `/manage/payouts`, `/manage/payouts/history`, `/manage/payouts/settings` | — | Verified (Help) |
| Creator: settings | `/manage/creator` (R-18, Discord, fees), `/manage/profile`, `/manage/newsletters`, `/manage/invoice_issuer`, `/manage/unregister` | — | Verified (Help) |

These are **WebView-only**, because no API exists in any source: starting, stopping, upgrading or downgrading support; changing the payment method or card; plan management; profile editing; sending newsletters; payout requests; media upload (§15).

---

## 21. Appendix: legacy / unverified endpoints

These names have only been seen in old sources and have not been verified as current. Do not implement them in v1.0.

| Endpoint | Source | Notes | Confidence |
|---|---|---|---|
| `creator.listRelated` (`creatorId` or `userId`, `method`, `limit`) | cssxsh 2023 | Related creators | low |
| `creator.listTwitter` | cssxsh 2023 | — | low |
| `post.getPromotion` | cssxsh 2023 | — | low |
| `user.update` (POST, multipart, CSRF in form field `tt`) | cssxsh 2023 | Account settings; out of scope | low |
| `user.getTwitterAccountInfo` | cssxsh 2023 | Account settings; out of scope | low |
| `https://fanbox.pixiv.net/api/{method}` with `userId` params | FanboxViewer, old docs | Obsolete API root | — |

---

## 22. Open questions / unknowns

Verify each of these in Research Mode before building features that depend on it.

**Transport / Cloudflare**
1. Which api.fanbox.cc endpoints besides `post.info` challenge non-browser TLS clients, and in particular how iOS URLSession is treated? Only `post.info` is confirmed independently; `post.getEditable` rests on one code comment. Nothing is known for creator endpoints.
2. Are `cf_clearance` and `__cf_bm` needed for social and money endpoints? Magelon requires them, while the nushell script and fc-downloader succeed with FANBOXSESSID alone.
3. Must `Origin` be exactly `https://www.fanbox.cc`? danbooru sends `https://fanbox.cc`, and JanMaki (2023) sent a creator subdomain.
4. Is a `Referer` strictly required on `pixiv.pximg.net` and `downloads.fanbox.cc`? Only fc-downloader claims a 403 without it on pximg.
5. Does the CSRF token rotate within a session? What error does a stale token produce?
6. Are the old metadata keys (`urlContext.user.isLoggedIn`, `wwwUrl`, `isOnCc`, …) still present next to `context` and `csrfToken`?

**Timeline / posts**
7. When did `paginateCreator` page URLs switch from `max*` to `first*` cursors? What exact format does `firstPublishedDatetime` use, and what is the real value of `sort`? (fankt anonymized it.)
8. Is `sort` required on `post.listCreator`? Is `oldest` real?
9. Does `post.listCreator` still accept `limit` up to 300 with `first*` cursors? (The app will use 10 regardless.)
10. Does `post.listCreator?creatorId=X&limit=10` with **no cursor** return the newest page? If so, the `paginateCreator` call could be skipped.
11. Did the `post.listHome` and `post.listSupporting` `nextUrl` cursors also move to `first*` keys after 2026-07?
12. `post.listTagged`: is the body `{ count, items, nextUrl }` or `body.posts`? Was it wrapped in July 2026?
13. Is `withPinned=true` a real `post.listCreator` parameter?
14. Is `embedMap` always present on articles? Is `host` still returned on `default` url embeds?
15. `post.get`: what are its auth requirements, and is the current shape `body.post` or bare?
16. Style and link offset units: UTF-16 code units or code points?

**Social**
17. `post.addComment`: does the server accept an omitted `rootCommentId`/`parentCommentId` for root comments? `"0"`/`"0"` is proven in production.
18. What do the response bodies of `post.addComment`, `deleteComment`, `likeComment`, `likePost` and `follow.*` contain? Does `addComment` return the new comment?
19. Is there any unlike endpoint, for posts or comments?
20. Can a creator delete other users' comments through `post.deleteComment`? What is the server's maximum comment length?
21. Does the `post.getComments` offset count root threads or all comments? What `limit` values are allowed, what is the maximum, and in what order are comments returned? Which `viewMode` values exist besides `OPEN`?
22. `bell.list`: what is the full set of type strings, especially creator-side events? What is `creatorUserId` for? Is `page` optional, and is `page=0` the same as `page=1`? Is `limit` honored? Does the `post_comment` bell id equal the comment id?
23. `bell.countUnread`: the exact shape today (`body.count` comes from 2023 readers).
24. `newsletter.list`: is it paginated, and is `body` plain text or HTML? Does any single-item get or mark-read endpoint exist? Are `newsletter.countUnread` and `markAsReadAll` still live?
25. Does `user.countUnreadMessages` count pixiv DMs, newsletters, or both?

**Money**
26. Is the current `payment.listUnpaid` body wrapped in `body.payments`? Which cases produce unpaid records?
27. What are the exact current `paymentMethod` strings and their casing? What strings do pixivcoban and PayPal-via-bank use? Does `PaidRecord.creator.isActive` still exist?
28. `legacy/support/creator`: what does a non-empty `supportReservations` look like? What is returned for a creator you do not support? Is there a non-legacy replacement?
29. `plan.listSupporting`: piep still expects a bare array. Can different accounts or clients get different shapes, or is piep simply stale?
30. When exactly did `creator.listFollowing`, `listPixiv` and `listRecommended` move to `body.creators`?

**Creator side**
31. Media upload: what are the endpoint names, method, fields, whether a `postId` is needed, and the response?
32. `post.update`: scheduled publish, cover image, adult flag, `planId`, non-article content, and whether maps must be sent with the blocks. Is the encoding multipart with repeated `tags`, or urlencoded with a JSON string? Is `commentingPermissionScope` mandatory? Is an `X-CSRF-Token` header needed in addition to `tt`? Does omitting `tags` keep or clear them?
33. `post.listManaged`: pagination, caps, status filters, or a paginate-style variant?
34. `relationship.listFans`: are large fan counts capped? Is there a total-months field? Is there any way to edit `note`? Which `status` values exist beyond `supporter`?
35. Does `relationship.getFan` exist? Which endpoint does `/manage/relationships/{userId}` actually call?
36. Are `legacy/manage/pledge/monthly` and `legacy/payout_request` still live? What values can `paymentMethod` and `specialSales` take?
37. Plan create, edit and delete, profile editing, newsletter sending, dashboard statistics, and payout-request writes: is there any JSON API for them? Currently they are treated as WebView-only.
38. `plan.listCreator`: are there owner-only fields, such as hidden or draft plans, when the owner calls it? Does the `creatorId` form ever return a bare array?
39. What do `notification.updateSettings` (the current body shape) and `creator.getStartComments` actually do today?

**Web URLs**
40. Every row marked *unverified* in §20: login, plans, supporting list, payment settings, payment history, notifications list, newsletter inbox, and new post.

---

## 23. Confidence summary

### 23.1 By area

| Area | Endpoints | high | medium | low |
|---|---:|---:|---:|---:|
| Session | 1 | 1 | 0 | 0 |
| Timeline | 5 | 4 | 1 | 0 |
| Post | 4 | 2 | 2 | 0 |
| Creator | 7 | 4 | 2 | 1 |
| Plans / Support | 3 | 3 | 0 | 0 |
| Comments | 5 | 4 | 1 | 0 |
| Notifications (bell) | 5 | 3 | 2 | 0 |
| Newsletters (おたより) | 3 | 0 | 2 | 1 |
| Payments | 2 | 1 | 1 | 0 |
| Follow | 2 | 2 | 0 | 0 |
| Creator-side management | 5 | 2 | 3 | 0 |
| Uploads | 1 | 0 | 0 | 1 |
| Fans | 4 | 2 | 1 | 1 |
| Dashboard | 2 | 0 | 2 | 0 |
| **Total** | **49** | **28** | **17** | **4** |

Also documented: two media host families (§1.9, high). The five appendix endpoints in §21 are low and not counted above.

### 23.2 Low-confidence endpoints

| Endpoint | Why |
|---|---|
| `creator.getStartComments` | One 2023 source; purpose unknown |
| `newsletter.markAsReadAll` | One source, never run with a token |
| Post media upload (§15) | Not found in any OSS; the endpoint is unknown |
| `relationship.getFan` | Only in an unmerged 2024 spec branch; no client calls it |
| Appendix (§21): `creator.listRelated`, `creator.listTwitter`, `post.getPromotion`, `user.update`, `user.getTwitterAccountInfo` | 2023 sources only |

### 23.3 Medium, with caveats worth remembering

- **`post.listTagged`:** `items` vs `posts` disagreement.
- **`post.get`:** single current source.
- **`tag.search`, `tag.getFeatured`:** a shape disagreement for `getFeatured`.
- **`creator.listPixiv`:** no real payload.
- **`post.listComments`:** deprecated.
- **`notification.getSettings`/`updateSettings`:** 2023 and 2020 sources.
- **`newsletter.list`:** element fields come from a handcrafted fixture.
- **`newsletter.countUnread`:** one source, from 2023.
- **`payment.listUnpaid`:** its wrapper is assumed from `listPaid`.
- **`post.listManaged`, `post.create`, `post.delete`:** a single author.
- **`legacy/manage/supporter/user`:** its only source is archived.
- **`legacy/manage/pledge/monthly`, `legacy/payout_request`:** response shapes are from 2023.

### 23.4 Items rated high whose bodies are still shape-unknown

`post.likePost`, `post.addComment`, `post.deleteComment`, `post.likeComment`, `follow.create` and `follow.delete` are high-confidence as *requests*. No client reads their response body, so the app must treat any 2xx as success and then re-read the state.
