<div align="center">

<img src="docs/icon.png" width="104" alt="">

# FANBOX Personal Client

**Several pixivFANBOX accounts, one local-first iOS app**

![iOS](https://img.shields.io/badge/iOS-26%2B-000000?logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-SwiftUI%20%2B%20SwiftData-F05138?logo=swift&logoColor=white)
![Dependencies](https://img.shields.io/badge/dependencies-none-2DD4BF)
![License](https://img.shields.io/badge/license-all%20rights%20reserved-8B5CF6)

<p>
  <img src="docs/shot-home.png" width="23%" alt="Home: one timeline across accounts">
  <img src="docs/shot-post.png" width="23%" alt="Post detail rendered natively">
  <img src="docs/shot-notifications.png" width="23%" alt="Merged notification inbox">
  <img src="docs/shot-support.png" width="23%" alt="Support dashboard">
</p>

<sub>Screenshots use the built-in demo accounts. All creators and posts in them are fictional.</sub>

</div>

---

FANBOX Personal Client is a personal iOS app for people who use more than one pixivFANBOX / pixiv account.
It reads posts, comments, notifications, newsletters (おたより) and support state for every account, stores them in a
local SwiftData database, and shows one merged view. The screens render from the local database first and refresh
from the network afterwards, so a slow or missing connection does not block reading, searching, drafting or replying.

The app is not distributed through the App Store, and it is not affiliated with or endorsed by pixiv Inc.
The full specification (in Japanese) is in [SPEC.md](SPEC.md).

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Build and test](#build-and-test)
- [Demo mode](#demo-mode)
- [Architecture](#architecture)
- [Repository layout](#repository-layout)
- [Documentation](#documentation)
- [Copyright and license](#copyright-and-license)

## Features

| Area | What it does |
|---|---|
| Accounts | Any number of FANBOX / pixiv accounts. Each account has its own `WKWebsiteDataStore`, its own Keychain credential and its own `URLSession`, so cookies never mix. |
| Reader | One timeline across all accounts. A post seen by several accounts is shown once. The app picks the account to read with (cached, can view, valid session, higher plan, main account) and you can switch by hand. Posts render natively: text, images, galleries, files, audio, video, links, embeds and article blocks. |
| Notifications | One inbox for all accounts, with duplicates merged. When an event is detected, the app fetches the post body or comment thread before it posts the iOS notification. A tap then opens the post from the local database. Replies can be written from the notification and are queued offline. |
| Low data | Automatic / Normal / Low Data / Extreme / Offline modes. A text-first scheduler sends comment posts and interactive reads before any media and pauses media transfers while they run. |
| Support | Supports grouped by creator and by account, with monthly totals, this month's actual payments, next month's planned total, a locally observed support history and anomaly flags. Payment profiles (nickname, brand, last four digits, memo) can be linked to each support. Payment itself always happens in the account-aware web view. |
| Creator mode | Dashboard, managed posts, local drafts with a block editor, a media upload queue, comments, fans and plans for accounts that own a creator page. See the limitations below. |
| Library | Local full-text search, favorites, read later, local tags and memos (never sent to FANBOX), offline saving with a size-limited media cache. |
| Research mode | Redacted request / response / navigation logs, an API schema inspector that flags new or missing fields, and account, sync, support and scheduler state. |

Not included on purpose: bulk downloading, full-history crawling, and card payment handling inside the app
(see [SPEC.md §3.7](SPEC.md) and [docs/SECURITY.md](docs/SECURITY.md)).

### Creator mode limitations (real FANBOX accounts)

The FANBOX write API used by Creator mode is reconstructed from public sources and **has not been verified against the
live service** (see [docs/API.md](docs/API.md) §14–§15). With a real account:

- **Native sends cover text and headings only.** Image and file uploads, new link cards, new embeds, the R-18 flag and
  plan-specific gating (FANBOX gates by minimum fee) have no documented request shape. The editor marks these blocks
  "Web" before you publish. Sending saves the text first as a FANBOX draft, then hands off to the account's web editor
  with an ordered checklist and the app's resized / converted images exported for the web file picker. The demo
  account supports every block natively, so you can try the full flow offline.
- **Post Edit round-trip.** Unchanged paragraphs are sent back as they were, including bold, links and empty spacing
  paragraphs. Media, link cards and embeds that are already on the post are kept by their ids. An edited paragraph
  keeps the styles outside the edited text; the app asks before it sends a change that would drop any. Posts the app
  cannot write back faithfully (non-article posts, scheduled posts, unknown block types) are edited in the web editor.
  If FANBOX does not report the tags or the comment permission, the app asks before it overwrites them.
- **No accidental unpublish or overwrite.** Updating a live post keeps it published. Taking it down to a draft needs
  explicit confirmation. Before each update the app reads the post again and stops if it changed elsewhere, for example
  in the web editor, so local content never overwrites that change.

## Requirements

- macOS with **Xcode 27** (iOS 27 SDK; the deployment target is iOS 26)
- An iPhone or simulator running **iOS 26** or later
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** (`brew install xcodegen`). The Xcode project is generated from
  `project.yml` and is not committed.

There are no Swift packages, CocoaPods or other third-party dependencies. See [THIRD_PARTY.md](THIRD_PARTY.md).

## Build and test

```sh
# Generate the project and build the app for the iOS Simulator.
scripts/build.sh

# Also compile the unit / UI test targets.
scripts/build.sh build-for-testing

# Run tests on one simulator (default "iPhone 17 Pro"; override with SIM_DEVICE=...).
scripts/test.sh -only-testing:FANBOXClientTests/SettingsModuleTests

# Remove this checkout's DerivedData folder.
scripts/clean-dd.sh
```

- `scripts/build.sh` runs `xcodegen generate`, builds with `xcodebuild`, and prints only warnings / errors from this
  repository plus the final `** BUILD SUCCEEDED **` / `** BUILD FAILED **` line. `JOBS` sets the number of compile
  jobs (default 2).
- `scripts/test.sh` takes a lock at `/tmp/fanbox-sim-lock`, so parallel checkouts on one machine share one simulator
  in turn. Exit code 75 means the lock timed out; run it again.
- To work in Xcode, run `xcodegen generate` and open `FANBOXClient.xcodeproj`. Code signing uses the team in
  `project.yml`; change `DEVELOPMENT_TEAM` for your own device builds.

## Demo mode

Two launch arguments help with development and UI checks:

| Argument | Effect |
|---|---|
| `-demoData` | Adds three demo accounts ("Demo A", "Demo B", "Demo Creator") when there are no accounts. Demo accounts use `DemoRemoteDataSource`, which returns local fixture data and never touches the network. |
| `-uiTesting` | Uses an in-memory SwiftData store, an in-memory credential store and a throwaway `UserDefaults` suite. |
| `-initialTab <tab>` | Starts on a tab: `home`, `creators`, `support`, `creatorMode` or `library`. |
| `-openRoute <route>` | Pushes a screen at launch, e.g. `post:demo-post-101`, `creator:<id>`, `comments:<postID>`, `supportHistory`. |
| `-openSheet <sheet>` | Opens `settings` or `notifications` at launch. |

`scripts/shot.sh <out.png> [arguments]` launches the demo app with these arguments on a separate simulator and saves a
screenshot. The README screenshots were taken this way.

In Xcode, set them under *Scheme > Run > Arguments Passed On Launch*. Previews and unit tests use
`AppEnvironment.preview(seedDemo:)`, which builds the same demo setup in memory.

## Architecture

```text
SwiftUI views (Features/*)            render from SwiftData with @Query; no endpoints, no JSON
        |
        v
Services / use cases                  SyncEngine, SyncCoordinator, ReplyQueue, NotificationService,
(Core/*, AppEnvironment)              MediaService, OfflineLibraryService, AccountService, WebBridge ...
        |
        v
Repository                            LocalStore (SwiftData, the only writer)  +  RemoteDataSource
        |                                                                          |
        |                                              FanboxRemoteDataSource (FanboxAdapter)
        |                                              DemoRemoteDataSource (offline fixtures)
        v                                                                          v
Local database  <---- normalized upserts ----  FanboxAPIClient -> HTTPClient (per-account session)
                                                              -> NetworkScheduler (priorities)
                                                              -> FANBOX API / Web
```

The app starts from the local database. Network work begins after the first frame, writes through `LocalStore`, and
the views update through `@Query`. Differential sync reads newest-first and stops at the first known post. Network
errors never delete cached data.

Notifications are treated as a trigger to fetch text, not as something to look at later. The body is in the
local database before the iOS notification appears, so opening it does not start an HTTP request:

```text
FANBOX event
  | foreground polling / launch refresh / BGAppRefreshTask / optional silent push
  v
event detected --> text prefetch (comment thread, post body, おたより)   priority: notificationPrefetch
  |
  v
local database --> iOS notification (body already readable, inline 返信 action)
  |
  v
tap --> post / thread rendered from the local database
reply --> queued locally --> sent as interactiveWrite, ahead of any media transfer
```

Details: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Repository layout

```text
FANBOXClient/
  App/          entry point, AppEnvironment (dependency container), router, settings
  Features/     SwiftUI screens: Home, Creator, Support, CreatorMode, Notifications, Library, Settings
  Core/         Models, Database, Network, Authentication, Sync, Notifications, Media, Payments, Security, Web
  Fanbox/       API client, adapter (DTO -> Remote* values), demo data source, research recorder, schema inspector
  UI/           shared components (account badges, sync banner, remote images, image viewer)
  Resources/    Info.plist, asset catalog
FANBOXClientTests/     unit tests (hosted in the app)
FANBOXClientUITests/   UI smoke tests
docs/                  architecture, security, network modes, notification relay, API notes
scripts/               build / test / cleanup helpers
project.yml            XcodeGen project definition
```

## Documentation

- [SPEC.md](SPEC.md): product specification v1.0 (Japanese)
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): layers, data flow, sync, scheduler, notification pipeline, file map
- [docs/SECURITY.md](docs/SECURITY.md): sensitive data storage policy, redaction, Research Mode
- [docs/NETWORK_MODES.md](docs/NETWORK_MODES.md): communication modes and request priorities
- [docs/NOTIFICATION_RELAY.md](docs/NOTIFICATION_RELAY.md): design of the optional APNs relay
- [docs/API.md](docs/API.md): notes on the unofficial FANBOX API (facts only, gathered for interoperability)
- [THIRD_PARTY.md](THIRD_PARTY.md): third-party license inventory and review procedure
- [CONTRIBUTING.md](CONTRIBUTING.md): contribution policy

## Copyright and license

```text
Copyright © 2026 Masahiro Sato. All rights reserved.

No license is granted for this source code.
The source code is publicly available for inspection only.
Permission to use, copy, modify, distribute, sublicense, or create
derivative works is not granted unless separately authorized by
the copyright holder.
```

- Public source is not open source. If this repository is public, it is public so the code can be read. It does not
  grant rights to use it.
- There is **no LICENSE file on purpose**. The project may move to a license such as MIT, Apache-2.0 or MPL later.
  Until then, all rights are reserved.
- **External pull requests are not accepted** until the copyright and relicensing policy is settled. See
  [CONTRIBUTING.md](CONTRIBUTING.md).
- No third-party code is bundled. PixiView-KMP and fankt were read only to understand FANBOX behavior, endpoints and
  data shapes. No code was copied from them. See [THIRD_PARTY.md](THIRD_PARTY.md).
- pixiv and pixivFANBOX are services of pixiv Inc. This project is unofficial and has no relationship with pixiv Inc.
