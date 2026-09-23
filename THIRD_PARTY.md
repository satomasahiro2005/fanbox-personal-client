# Third-Party Inventory

This file is the dependency ledger required by [SPEC.md §3.6](SPEC.md). Every direct dependency must be recorded here
**before** it is added to the project.

## Summary

- **No third-party libraries are linked into or bundled with the app.** There are no Swift packages, CocoaPods,
  Carthage frameworks, vendored source files, fonts or other third-party assets.
- The app uses only Apple SDK frameworks, which are part of iOS and are not redistributed with the app.
- XcodeGen is used at build time to generate the Xcode project. It is not part of the app.
- PixiView-KMP and fankt (and the other sources listed in [docs/API.md](docs/API.md) §0.2) were used only as reference
  material for FANBOX behavior. No code from them is included.

Last reviewed: 2026-09-24.

## Ledger: bundled or linked third-party libraries

| Library | Version | Source | License | Copyright Notice | Usage | Redistribution Requirements |
|---|---|---|---|---|---|---|
| *(none)* | — | — | — | — | — | — |

When a library is added, add a row with every column filled in, and copy any required NOTICE text into the app
(see [Review procedure](#review-procedure-before-adding-a-dependency)).

## Platform frameworks (Apple SDK)

These come with iOS. The app links against them but does not ship copies of them. Their use is covered by the Apple
Developer Program License Agreement and the Xcode / SDK license, not by an open-source license, so they have no ledger
rows.

| Framework | Used for |
|---|---|
| SwiftUI | All screens |
| SwiftData | Local database (`Core/Models`, `Core/Database`) |
| Foundation | Networking (`URLSession`), JSON, files, dates |
| Observation | `@Observable` services and settings |
| UIKit | App delegate, background fetch results, image types, system settings links |
| WebKit | Account-aware `WKWebView` and per-account `WKWebsiteDataStore` |
| Network | `NWPathMonitor` for automatic network mode |
| UserNotifications | Local notifications and notification actions |
| BackgroundTasks | `BGAppRefreshTask` / `BGProcessingTask` |
| Security | Keychain (`SecItem*`) for session credentials |
| CryptoKit | SHA-256 file names in the media cache |
| ImageIO | Image downsampling and conversion of draft images before upload |
| PhotosUI | Photo picker in the post editor |
| UniformTypeIdentifiers | File types of draft media and uploads |
| QuickLook | Previews of files attached to posts |
| AVKit | Audio / video playback in posts |
| os | `Logger` (unified logging) |
| XCTest | Unit and UI tests only (not in the app) |

## Build-time tools (not distributed)

| Tool | Version | Source | License | Usage | Redistribution Requirements |
|---|---|---|---|---|---|
| XcodeGen | 2.45.x (developer machine) | https://github.com/yonaskolb/XcodeGen | MIT | Generates `FANBOXClient.xcodeproj` from `project.yml` | None for the app: XcodeGen is not shipped and its output contains no XcodeGen code |
| Xcode 27 | 27.0 | Apple | Apple Xcode and SDK license | Compiler, simulator, `xcodebuild` | Not redistributed |

## Reference-only materials (no code used)

| Material | Source | How it was used | Code copied |
|---|---|---|---|
| PixiView-KMP | https://github.com/matsumo0922/PixiView-KMP | Read to understand FANBOX behavior, endpoints and data shapes | No |
| fankt | https://github.com/matsumo0922/fankt | Read to understand FANBOX endpoints, response envelopes and entities | No |
| Other public projects and the pixivFANBOX Help Center | Listed in [docs/API.md](docs/API.md) §0.2 | Interoperability facts (endpoint paths, parameter and field names, status codes) | No |

Rules for reference material (SPEC §3.6):

- Do not copy code, test fixtures, captured payloads or documentation prose from these projects.
- Do not translate Kotlin (or any other language) into Swift line by line. Understand the behavior, then write an
  independent Swift implementation.
- Do not paste code snippets from the web without first checking their license and recording them here.
- Each of these projects is under its own license. Naming them here is a citation of where facts came from, not a
  license claim.

## Review procedure before adding a dependency

Adding any third-party code (a package, a vendored file, a snippet longer than a trivial idiom, a font or an image)
requires all of the following first:

1. **Need.** Check whether an Apple framework or a small independent implementation is enough. The default answer is
   "no new dependency".
2. **License identification.** Read the actual LICENSE / COPYING / NOTICE files of the exact version to be used,
   including its own transitive dependencies. Do not rely on a README badge.
3. **Permissive licenses (MIT, BSD, Apache-2.0, ISC, zlib, ...).** Record the copyright notice exactly. Check
   attribution requirements: MIT / BSD require the notice to be reproduced; Apache-2.0 requires any NOTICE file to be
   carried along and changes to be marked. Plan where the notice will appear in the app (for example the 法的情報
   screen, `LegalView`).
4. **Copyleft licenses (GPL, AGPL, LGPL, MPL, EPL, CC-BY-SA, ...).** Stop and review the impact before adoption:
   - GPL / AGPL: would require releasing the app's source under the same license. Not compatible with the current All
     Rights Reserved policy. Do not adopt.
   - LGPL: relinking requirements are hard to meet with static linking on iOS. Treat as "do not adopt" unless a
     written review concludes otherwise.
   - MPL-2.0: file-level copyleft. Allowed only if the MPL files stay separate and their source can be provided.
5. **App distribution.** Check that the license allows distribution in an iOS app (App Store or ad hoc) and does not
   conflict with Apple's terms.
6. **Record it.** Add a row to the ledger above with every column filled in, in the same commit that adds the
   dependency.
7. **Update the app.** Add the required notices to the in-app legal screen and update the third-party summary in
   `LegalNotice.thirdPartyPoints` (`FANBOXClient/Features/Settings/LegalView.swift`).
8. **Security.** Pin an exact version, prefer sources with signed releases, and review what data the library can
   access. A dependency must never see cookies, session IDs, CSRF tokens or payment data unless that is its purpose
   and it has been reviewed for it.

Removing a dependency: delete its ledger row and its notices in the same commit.
