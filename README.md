<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="FANBOX Personal Client app icon">
</p>

<h1 align="center">FANBOX Personal Client</h1>

<p align="center">A local-first iOS client that combines several pixivFANBOX accounts in one app.</p>

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
| Creator mode | Dashboard, managed posts, local drafts with a block editor, a media upload queue, comments, fans and plans for accounts that own a creator page. |
| Library | Local full-text search, favorites, read later, local tags and memos (never sent to FANBOX), offline saving with a size-limited media cache. |
| Research mode | Redacted request / response / navigation logs, an API schema inspector that flags new or missing fields, and account, sync, support and scheduler state. |

Not included on purpose: bulk downloading, full-history crawling, and card payment handling inside the app
(see [SPEC.md §3.7](SPEC.md) and [docs/SECURITY.md](docs/SECURITY.md)).

## Requirements

- macOS with **Xcode 27** (iOS 26 SDK)
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
