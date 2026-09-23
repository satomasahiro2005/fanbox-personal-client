# FANBOX Personal Client v1.0 仕様書

## 0. 文書の目的

本書は、自分専用の iOS 向け FANBOX ネイティブクライアント **FANBOX Personal Client v1.0** の完成仕様を定義する。

本アプリは App Store 公開を前提としない。  
主目的は、FANBOX の Web UI をそのまま再現することではなく、**複数アカウント・複数支援・低速回線・通知・Creator 運用を、自分向けに最適化して一つの iOS アプリへ統合すること**である。

本仕様における `MUST` / `MUST NOT` は、v1.0 で省略不可の非交渉要件を表す。

---

# 1. コンセプト

FANBOX を「Web サイト」としてではなく、以下のデータをローカル中心に扱う Personal Client とする。

- 複数 FANBOX / pixiv アカウント
- 支援中・フォロー中のクリエイター
- 投稿とメディア
- コメント
- おたより
- 通知
- 支援状態
- 支援履歴
- 決済手段の論理的な対応関係
- Creator 側の投稿・コメント・ファン管理
- ローカル下書き
- オフラインライブラリ

設計優先順位は以下とする。

```text
1. Local Data
2. Instant UI
3. Interactive Network Requests
4. Notification Prefetch
5. Differential Sync
6. Media Prefetch
7. FANBOX Web / API
```

**通信が遅いことによって UI 自体が遅くなってはならない。**

通信不能時でも、最後に同期済みの情報については通常どおり閲覧・検索・下書き作成が可能であることを MUST とする。

---

# 2. 対象環境

```text
Platform
- iPhone
- iOS 26 以降

Primary Frameworks
- Swift
- SwiftUI
- SwiftData
- URLSession
- WebKit / WKWebView
- Keychain
- BackgroundTasks
- Network.framework
- UserNotifications
```

iPad は SwiftUI が自然に対応できる範囲では対応してよいが、v1.0 の UI 最適化対象は iPhone とする。

App Store 配布は v1.0 の要件に含めない。

---

# 3. v1.0 の非交渉要件

以下は実装都合によって削除してはならない。

## 3.1 Local-first

- すべての主要な読み取り画面は MUST でローカル DB から描画する。
- View が FANBOX API のレスポンスを待ってから初めて表示される設計を MUST NOT とする。
- API レスポンスは Normalize 後に Local Store へ保存し、UI は Local Store の変更を監視する。
- 起動時に通信を待ってはならない。

```text
App Launch
    ↓
Local DB
    ↓
Immediate UI
    ↓
Background / Differential Sync
    ↓
Local DB Update
    ↓
UI Update
```

---

## 3.2 Multi-account

- 複数 FANBOX / pixiv アカウントを MUST で同時管理できること。
- アカウント数に固定上限を設けない。
- 各アカウントの Cookie / Web Session / API Session は MUST で分離する。
- 1つの投稿を複数アカウントで取得できる場合でも、UI 上では原則として1投稿に統合する。
- 必要な場合は「どのアカウントとして閲覧するか」を手動選択できること。

---

## 3.3 通知

通知は補助機能ではなく P0 機能とする。

以下を MUST とする。

- 通知を可能な限り早く検出する。
- 通知をタップしてから本文取得を開始する設計だけに依存してはならない。
- 通知イベントを検出した時点で、可能であれば本文・コメント等の軽量データを先に取得する。
- 通信制限中でも、通知から本文またはコメントを素早く読めること。
- コメントへの返信は、画像取得等より優先して送信すること。
- 完全オフライン時でも返信文をローカルキューへ保存できること。

---

## 3.4 低速回線

128 kbps 級の通信制限でも、最低限以下を快適に扱えることを目標とする。

- 通知
- 投稿タイトル
- 投稿本文
- コメント本文
- コメント返信
- 支援状態
- Creator metadata

画像・動画・添付ファイルは MUST で後回しにできること。

---

## 3.5 ライセンス・著作権

初期公開時には OSS ライセンスを付与しない。

Repository を public にする場合でも、以下を README 等へ明記する。

```text
Copyright © 2026 Masahiro Sato. All rights reserved.

No license is granted for this source code.
The source code is publicly available for inspection only.
Permission to use, copy, modify, distribute, sublicense, or create
derivative works is not granted unless separately authorized by
the copyright holder.
```

方針:

- Public Source ≠ Open Source とする。
- v1.0 までは All Rights Reserved を基本とする。
- 将来 MIT / Apache-2.0 / MPL 等へ変更することは可能とする。
- 外部 PR は、著作権・再ライセンス方針が確定するまで原則として受け付けない。
- Contributor を受け入れる場合は、Contribution の権利関係を明示する仕組みを先に設計する。

---

## 3.6 第三者コード

以下を MUST とする。

- すべての直接依存ライブラリのライセンスを記録する。
- MIT / BSD / Apache-2.0 等でも NOTICE や attribution 条件を確認する。
- GPL / AGPL / LGPL 等は採用前に影響範囲を確認する。
- PixiView-KMP / fankt 等の既存実装からコードをコピーしないことをデフォルトとする。
- Kotlin コードを機械的に Swift へ翻訳して利用することを避ける。
- 既存実装は、挙動・endpoint・データ構造を理解する参考資料として利用し、Swift 側では独立実装する。
- Web 上のコード片を無条件でコピーしない。

依存関係台帳をリポジトリ内に保持する。

例:

```text
THIRD_PARTY.md
- Library
- Version
- Source
- License
- Copyright Notice
- Usage
- Redistribution Requirements
```

---

## 3.7 FANBOX 側との境界

本アプリは FANBOX downloader / mass archiver を目的としない。

MUST NOT:

```text
全 Creator
×
全履歴
×
全画像
×
定期総当たり
```

通常同期は最新差分取得を基本とし、既知投稿へ到達した時点で停止する。

```text
Latest Page
    ↓
New Post
    ↓
New Post
    ↓
Known Post ID
    ↓
STOP
```

オフライン保存は、通常閲覧したコンテンツとユーザーが明示的に保存対象としたコンテンツを中心とする。

---

# 4. メイン UI

メイン構成:

```text
TabView

ホーム
クリエイター
支援
Creator
ライブラリ
```

設定は NavigationBar 等から開く。

---

# 5. ホーム / 統合フィード

全アカウントを横断した統合フィードを表示する。

フィルター:

```text
すべて
支援中
フォロー中
未読
お気に入り
```

投稿カード表示項目:

- Creator 名
- Creator icon
- 投稿日
- タイトル
- 本文冒頭
- Thumbnail
- 閲覧可能 Account
- 対象 Plan
- 既読状態
- Offline / Cache 状態

同一 `postId` は原則として重複表示しない。

内部:

```text
Post
└─ PostAccess
   ├─ Account A
   ├─ Account B
   └─ Account C
```

---

# 6. 投稿詳細

投稿は可能な限りネイティブ表示する。

対応対象:

- Text
- Image
- Image Gallery
- File
- Audio
- Video / External Video
- URL
- Embed
- Article Block

画像取得は段階化する。

```text
Thumbnail
    ↓
Display Resolution
    ↓
Original
```

操作:

- 既読 / 未読
- お気に入り
- Offline 保存
- Cache 削除
- Browser で開く
- Account 切り替え
- Creator を開く
- 共有

---

# 7. Account 管理

Account model:

```text
Account
- id
- displayName
- pixivUserID
- fanboxUserID
- avatar
- webProfileID
- creatorAccount
- enabled
- lastSyncAt
```

秘密情報は Account model に直接入れない。

## 7.1 Web Session

アカウントごとに独立した WebKit Website Data Store を使用する。

```text
Account A
└─ WebsiteDataStore A

Account B
└─ WebsiteDataStore B
```

目的:

- Cookie 混在防止
- 決済画面の誤 Account 防止
- Creator / Viewer Account の完全分離

## 7.2 API Session

URLSession / Cookie / CSRF 等もアカウント単位で分離する。

---

# 8. 自動 Account 選択

投稿を開く際は以下の優先順位で自動選択する。

```text
1. キャッシュ済み
2. 投稿を閲覧可能
3. Session が正常
4. より高い閲覧権限
5. Main Account
```

ユーザーは常に手動変更できる。

---

# 9. Creator 統合表示

Creator を FANBOX Account より上位の主体として表示する。

例:

```text
Creator A

支援中
Account A    ¥500
Account B  ¥1,000
Account C  ¥5,000

合計       ¥6,500 / 月

Posts
Plans
Support
About
```

Creator 一覧フィルター:

- 支援中
- フォロー中
- 投稿あり
- お気に入り
- 自分の Creator Account

---

# 10. 支援管理

## 10.1 Creator 単位

```text
Creator A

合計月額
¥6,500

Account A
¥500 Plan
楽天カード

Account B
¥1,000 Plan
三井住友カード

Account C
¥5,000 Plan
PayPal
```

## 10.2 Account 単位

```text
Account A

Creator A  ¥500
Creator B  ¥1,000
Creator C  ¥2,000

合計       ¥3,500
```

## 10.3 全体 Dashboard

```text
9月

定常月額       ¥18,500
今月実請求     ¥21,500
来月予定       ¥18,500

Creators            8
Accounts             3
```

現在の月額、実請求額、来月予定額は別フィールドとして扱う。

---

# 11. 支援履歴

アプリが観測した支援状態の変更をローカル保存する。

```text
SupportHistory

timestamp
creatorID
accountID
oldPlan
newPlan
oldAmount
newAmount
observedSource
```

例:

```text
2026-09-01
Creator A
Account B
¥500 → ¥1,000

2026-09-03
Creator C
Account A
支援開始 ¥3,000
```

FANBOX 側が完全な履歴 API を提供しない場合でも、アプリが観測できた変更は保持する。

---

# 12. Payment Profile

カード情報そのものではなく、自分が識別するための論理 Payment Profile を持つ。

```text
PaymentProfile

id
nickname
type
brand
last4
memo
```

例:

```text
楽天カード
Visa •••• 1234

三井住友
Mastercard •••• 5678

PayPal
```

MUST NOT で保存するもの:

- PAN / カード番号
- CVC
- PIN
- 3D Secure Credential
- カードパスワード

有効期限も原則として保存しない。

---

# 13. Payment Assignment

支援単位に、自分が認識している決済手段を関連付ける。

```text
SupportPaymentAssignment

accountID
creatorID
planID
paymentProfileID
verificationState
lastVerifiedAt
```

`verificationState`:

```text
verified
inferred
manual
unknown
```

FANBOX 側の実際のカード状態を取得できない場合、推測を事実として表示してはならない。

---

# 14. 決済 Web Bridge

カード決済自体を独自実装しない。

```text
Creator
    ↓
Plan 選択
    ↓
Account 選択
    ↓
Payment Profile 選択
    ↓
Account-aware WKWebView
    ↓
FANBOX / pixiv Payment Flow
    ↓
状態再同期
```

目的:

- 正しい Account で決済ページを開く。
- カード番号等をアプリ側で保持しない。
- FANBOX / pixiv 側の決済処理へ委譲する。

---

# 15. 支援エラー / Recovery

支援状態に異常がある場合、Support Dashboard に集約する。

例:

```text
要確認

Creator A
Account B

以前:
¥1,000 / 月

現在:
支援なし

[状態を確認]
[再支援]
[Web で開く]
```

API 上で原因を確認できない場合、

- 「支援が消えた」
- 「決済状態を確認できない」

等の観測事実だけを表示する。

**決済失敗と推定して断定してはならない。**

---

# 16. Creator Mode

v1.0 に Creator 機能を含める。

```text
Creator

Dashboard
Posts
Drafts
New Post
Comments
Fans
Plans
```

---

# 17. Creator Dashboard

取得可能なデータのみ表示する。

例:

```text
今月

支援者      123
支援額      ¥xxx
投稿          8
コメント      24
```

取得不能な統計を推定値として通常表示しない。

推定する場合は明示的に `estimated` とする。

---

# 18. 投稿作成

ネイティブ投稿 Editor を実装する。

```text
タイトル

本文

+ Text
+ Image
+ File
+ URL
+ Embed
```

ブロックは並べ替え可能とする。

PhotosPicker:

```text
Photo Library
    ↓
Multiple Selection
    ↓
Reorder
    ↓
Resize / Convert if needed
    ↓
Upload Queue
```

---

# 19. ローカル下書き

下書きは FANBOX への通信なしで作成可能とする。

```text
Draft
- id
- accountID
- title
- blocks
- media
- targetPlan
- createdAt
- updatedAt
```

MUST:

- 自動保存
- 完全オフライン編集
- Upload 前のプレビュー
- 送信失敗時に下書きを失わない

---

# 20. Upload Queue

メディアアップロードは Job として管理する。

```text
UploadJob

queued
uploading
paused
failed
completed
```

例:

```text
1.jpg       ✓
2.jpg       Uploading 42%
3.png       Waiting
demo.zip    Waiting
```

失敗した Job のみ再送できること。

---

# 21. コメント

Viewer / Creator の両方でコメントを扱う。

Creator Mode:

- 未読
- 全件
- 投稿別
- Thread 表示

API で安全かつ安定して可能な場合:

- 投稿
- 返信
- 削除

不安定な操作は Account-aware WebView へフォールバックしてよい。

---

# 22. コメント返信キュー

通信不能時でも返信文を作成できる。

```text
Reply
    ↓
Queued Locally
    ↓
Network Available
    ↓
Sending
    ↓
Sent
```

状態:

```text
draft
queued
sending
sent
failed
needsConfirmation
```

短時間の回線切断では自動再送してよい。

長時間経過したコメントを自動送信するかは設定可能とし、デフォルトでは再確認を求める。

---

# 23. Fan 管理

Creator Mode で取得可能な範囲のファン情報を表示する。

```text
Fans

User
Plan
Support Period
Current State
```

検索・Plan フィルターを提供する。

---

# 24. Notification Architecture

通知は最優先システムとして扱う。

## 24.1 Event Types

最低限:

- 自分へのコメント
- コメント返信
- Creator 新着投稿
- おたより
- 支援状態変化
- 決済要確認
- Creator 側の新規支援
- その他 FANBOX 通知

## 24.2 優先度

| Event | Priority | Prefetch |
|---|---:|---|
| コメント | Critical | Comment + Thread |
| コメント返信 | Critical | Comment + Thread |
| 決済要確認 | Critical | Support Metadata |
| 新着投稿 | High | Title + Body |
| おたより | High | Body |
| 支援状態変化 | High | Support Metadata |
| 新規支援 | Normal | Metadata |
| その他 | Normal | Notification Metadata |

---

# 25. Notification Prefetch

通知を「見るための機能」ではなく、**必要な本文を先回りして取得するトリガー**として扱う。

優先順位:

```text
Priority 0
Notification Metadata

Priority 1
Post Title
Post Body
Comment Body
Author
Post ID
Comment ID

Priority 2
Small Avatar
Thumbnail

Priority 3
Display Image

Priority 4
Original Image
Video
Attachment
```

通信制限中でも Priority 0 / 1 を最優先する。

---

# 26. Notification Tap Performance

理想動作:

```text
FANBOX Event
    ↓
Event Detection
    ↓
Text Prefetch
    ↓
Local DB
    ↓
iOS Notification
    ↓
Tap
    ↓
Immediate Local Rendering
```

通知タップ後に初めて HTTP GET を開始する設計に依存してはならない。

目標:

```text
Cache 済み本文表示:
100 ms 程度を目標

Foreground event → UI:
2 秒以内を目標

Interactive Comment POST:
全 Background Media より優先
```

APNs 自体の配送時間は OS / Apple 側の制御であるため、アプリ側の保証対象とはしない。

---

# 27. Notification Inbox

複数 Account の通知を統合する。

例:

```text
通知

● user123 がコメントしました
  Creator Account
  1分前

● Creator A が投稿しました
  Account A / Account C
  3分前

● Creator B からおたより
  Account B
  12分前
```

内部:

```text
NotificationEvent
- id
- type
- accountIDs
- creatorID
- postID
- commentID
- timestamp
- prefetchState
- readState
```

同一イベントを複数 Account が受信した場合には dedupe する。

---

# 28. Notification Detection

iOS の BackgroundTasks のみでは即時通知を保証できないため、以下を組み合わせる。

```text
Local
├─ Foreground Polling
├─ App Launch Refresh
└─ Background Refresh

Optional Remote Relay
└─ APNs
```

Remote Relay を導入する場合にも、FANBOX Session Secret をサーバへ置くことは極力避ける。

候補:

```text
FANBOX Official Mail
    ↓
Mail Event Detection
    ↓
Private Notification Relay
    ↓
APNs
    ↓
iPhone
    ↓
App Direct Fetch
```

Relay へ投稿本文・支援者情報・Session Secret を恒常保存しない構成を優先する。

---

# 29. Network Scheduler

通信優先度を明示的に分離する。

```text
interactiveWrite         100
interactiveRead           90
notificationPrefetch      80
foregroundMedia           50
backgroundSync            20
mediaPrefetch              5
```

例:

```text
20 MB Original Image Download
    ↓
User sends comment
    ↓
Media pause / deprioritize
    ↓
Comment POST
    ↓
Resume Media
```

---

# 30. 通信モード

```text
Automatic
Normal
Low Data
Extreme
Offline
```

## Normal

```text
本文            ON
Thumbnail       ON
Display Image   ON
Prefetch        ON
```

## Low Data

```text
本文            ON
Thumbnail       ON
Original Prefetch OFF
Video Prefetch    OFF
```

## Extreme

```text
JSON / Text     ON
Thumbnail       Optional
Image           Manual
Audio           Manual
Video           Manual
File            Manual
```

## Offline

ネットワーク通信を完全停止する。

Automatic は Network.framework 等の状態とユーザー設定を参考に決定する。

キャリア側の単純な速度制限を OS が Low Data Mode として認識しない場合があるため、Extreme は手動指定可能とする。

---

# 31. Offline Library

専用画面を持つ。

```text
Offline

Posts
Creators
Images
Files
```

保存単位:

```text
この投稿
Creator の最近 N 件
今後閲覧した投稿を自動保存
```

無制限の過去履歴クロールを標準機能にしない。

---

# 32. Cache

キャッシュ容量設定:

```text
1 GB
5 GB
10 GB
20 GB
Unlimited
```

削除優先順位:

```text
Unpinned
    ↓
Old
    ↓
Original Image
    ↓
Display Image
    ↓
Thumbnail
```

本文、タイトル、Creator metadata 等の軽量データは極力保持する。

---

# 33. Search / Library

完全ローカル検索を提供する。

対象:

- Creator
- Post Title
- Post Body
- Comment
- Draft

ユーザー独自 metadata:

```text
Favorite
Unread
Read Later
Tags
Memo
```

例:

```text
#music
#reference
#illustration
```

これらは FANBOX へ送信しない。

---

# 34. Sync Engine

Account / Resource ごとに状態を持つ。

```text
SyncState
- accountID
- resource
- lastSuccessfulSync
- cursor
- lastKnownItemID
- error
```

同期対象:

- timeline
- creators
- supports
- plans
- notifications
- comments
- creator dashboard

同一リソースへの重複通信は可能な限り統合する。

---

# 35. Background Sync

Background Sync は軽量データを中心とする。

対象:

- 新着投稿 metadata
- 支援状態
- Notification metadata
- コメント metadata

Background で Original Image や Video の大量取得を行わない。

Media Prefetch は Wi-Fi 時のみ許可する設定を持つ。

---

# 36. Research Mode

v1.0 に正式搭載する。

目的:

- FANBOX 非公式 API の仕様把握
- Web フローの調査
- 支援 / 決済状態遷移の把握
- API 変更時の修正支援

表示対象:

```text
Requests
Responses
Navigation
API Schema
Account State
Support State
```

---

# 37. API Inspector

未知フィールドや schema 変化を検出する。

例:

```text
post.info

Known
- id
- title
- body
- creatorId

New
- fooBar
```

Decoder は未知フィールド追加によって壊れない設計とする。

可能な範囲で raw response を Research Mode から確認できるようにするが、Secret は必ず Redact する。

---

# 38. Secret Redaction

以下をログへ平文出力してはならない。

```text
Cookie
FANBOXSESSID
Authorization
CSRF Token
Password
Card Number
CVC
3D Secure Credential
```

表示:

```text
Cookie: <REDACTED>
FANBOXSESSID: <REDACTED>
X-CSRF-Token: <REDACTED>
```

**Debug Build であっても例外を設けない。**

---

# 39. Security / Storage

| Data | Storage |
|---|---|
| FANBOX Session Secret | Keychain |
| CSRF Token | Keychain または Memory |
| Web Cookie | Account 別 WebKit Store |
| Post Body | SwiftData |
| Comment | SwiftData |
| Thumbnail | File Cache |
| Media | File Cache |
| Card Last4 | SwiftData |
| Payment Memo | SwiftData |
| Card Number | 保存禁止 |
| CVC | 保存禁止 |
| Password | 保存禁止 |

可能であれば iOS Data Protection を利用する。

---

# 40. Web Bridge

ネイティブ化できない機能は Account-aware WKWebView へフォールバックする。

```text
openWeb(
    account: AccountB,
    destination: paymentSettings
)
```

通常 Safari に投げるだけではなく、選択 Account のログイン状態を維持する。

目的:

- 誤 Account 操作を防ぐ。
- Native / Web の境界を明確化する。
- API 仕様変更時の緊急フォールバックを確保する。

---

# 41. Data Model

v1.0 では最低限以下を持つ。

```text
Account

Creator
Plan

Post
PostBlock
PostAccess

Support
SupportHistory
PaymentProfile
SupportPaymentAssignment

Draft
DraftBlock
UploadJob

Comment
Fan

NotificationEvent

Media
MediaCacheEntry

Tag
PostTag

SyncState
ResearchLog
```

概略:

```text
Account ───────< PostAccess >────── Post
   │                                     │
   │                                     └──< PostBlock
   │
   └────< Support >──── Creator ────< Plan
              │
              └──── PaymentProfile

Creator ──────< Post

Account ──────< NotificationEvent

Draft ────────< DraftBlock
Draft ────────< UploadJob
```

---

# 42. Repository Architecture

```text
FANBOXClient
│
├─ App
│
├─ Features
│  ├─ Home
│  ├─ Creator
│  ├─ Support
│  ├─ CreatorMode
│  ├─ Notifications
│  ├─ Library
│  └─ Settings
│
├─ Core
│  ├─ Models
│  ├─ Database
│  ├─ Network
│  ├─ Authentication
│  ├─ Sync
│  ├─ Notifications
│  ├─ Media
│  ├─ Payments
│  ├─ Security
│  └─ Web
│
├─ Fanbox
│  ├─ API
│  ├─ DTO
│  ├─ Adapter
│  └─ Research
│
└─ UI
```

---

# 43. API Abstraction

SwiftUI が FANBOX endpoint や response schema を直接知ってはならない。

```text
SwiftUI
    ↓
UseCase
    ↓
Repository
   ├─ LocalDataSource
   └─ RemoteDataSource
          ↓
      FanboxAdapter
          ↓
    FANBOX API / Web
```

例:

```swift
protocol FanboxRepository {
    func timeline(account: AccountID) async throws -> [Post]
    func post(id: PostID, account: AccountID) async throws -> Post
    func creator(id: CreatorID, account: AccountID) async throws -> Creator
    func supports(account: AccountID) async throws -> [Support]
}
```

API 変更時は可能な限り `FanboxAdapter` / `DTO` の修正で吸収する。

---

# 44. Error Handling

通常 UI:

```text
同期できませんでした
キャッシュ済みデータを表示しています

最後の同期:
01:32
```

Research Mode:

```text
HTTP Status
Endpoint
Method
Safe Response Body
Account
Timestamp
```

Secret は表示しない。

ネットワークエラーによってローカルキャッシュを削除してはならない。

---

# 45. v1.0 完成条件

以下がすべて成立した時点を v1.0 とする。

## Reader

- [ ] 複数 Account
- [ ] Account ごとの独立 Session
- [ ] 統合 Timeline
- [ ] 投稿 Native 表示
- [ ] Image Viewer
- [ ] Account 自動選択
- [ ] Account 手動切り替え
- [ ] Local-first
- [ ] Offline 閲覧
- [ ] 全文検索
- [ ] Favorite / Tag / Memo

## Low Data

- [ ] Normal
- [ ] Low Data
- [ ] Extreme
- [ ] Offline
- [ ] Text-first Network Scheduler
- [ ] Media より Interactive Request を優先

## Notification

- [ ] Notification Inbox
- [ ] 新着投稿通知
- [ ] コメント通知
- [ ] コメント返信通知
- [ ] おたより通知
- [ ] 支援状態通知
- [ ] Notification Prefetch
- [ ] 通知から即本文表示
- [ ] 通知から即コメント返信
- [ ] Offline Reply Queue
- [ ] Background Refresh
- [ ] Optional APNs Relay 設計

## Support

- [ ] Creator 別支援集約
- [ ] Account 別支援一覧
- [ ] 総月額
- [ ] 今月実請求
- [ ] 来月予定
- [ ] Support History
- [ ] Payment Profile
- [ ] Support Payment Assignment
- [ ] Account-aware Payment Web
- [ ] 支援異常検出
- [ ] Recovery UI

## Creator

- [ ] Creator Dashboard
- [ ] Posts
- [ ] Local Draft
- [ ] Native Post Editor
- [ ] Media Upload Queue
- [ ] Post Edit
- [ ] Comments
- [ ] Fans
- [ ] Plans

## Research / Security

- [ ] Research Mode
- [ ] API Inspector
- [ ] Schema Change Detection
- [ ] Secret Redaction
- [ ] Keychain
- [ ] Account Cookie Isolation
- [ ] Sensitive Data Storage Policy
- [ ] Third-party License Inventory

## Legal / License

- [ ] All Rights Reserved 方針
- [ ] README に No License 明示
- [ ] LICENSE を安易に追加しない
- [ ] Third-party License Review
- [ ] PixiView / fankt のコードを直接流用しない
- [ ] 過剰な自動収集を実装しない
- [ ] 外部 Contribution 受け入れ前に権利方針を確定

---

# 46. v1.0 の核

一般的な FANBOX Client:

```text
Account
   ↓
FANBOX
```

本アプリ:

```text
                    自分
                     │
          ┌──────────┼──────────┐
      Account A  Account B  Account C
          │          │          │
          └──────────┼──────────┘
                     │
                 FANBOX Data
             ┌───────┼───────┐
           Posts   Support  Creator
                     │
              Payment Profiles
```

**複数の FANBOX アカウントを「自分」という一つの主体へ統合すること**を設計の中心とする。

特に通信制限時には、常に以下の優先順位を維持する。

```text
通知
 ↓
コメント
 ↓
投稿本文
 ↓
支援状態
 ↓
Thumbnail
 ↓
Display Image
 ↓
Original Image / Video / Attachment
```

画像が遅くてもよい。

**通知を受け取り、文章を読み、コメントを返す操作だけは低速回線でも高速に動作することを v1.0 の最重要 UX 要件とする。**

---

# 47. 参考資料

- GitHub Docs — Licensing a repository  
  https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository

- GitHub Terms of Service  
  https://docs.github.com/en/site-policy/github-terms/github-terms-of-service

- pixivFANBOX ガイドライン  
  https://fanbox.pixiv.help/hc/ja/articles/13239721816217

- pixivFANBOX — 登録したクレジットカードの変更・削除  
  https://fanbox.pixiv.help/hc/ja/articles/360008991393

- pixivFANBOX — 月初の自動支払いでエラーが発生した場合  
  https://fanbox.pixiv.help/hc/ja/articles/360003698854

- pixivFANBOX — プラン変更時の扱い  
  https://fanbox.pixiv.help/hc/ja/articles/360003723693

- pixivFANBOX — 通知設定  
  https://fanbox.pixiv.help/hc/ja/articles/360018253253

- pixivFANBOX — おたより機能  
  https://fanbox.pixiv.help/hc/ja/articles/900003410886

- Apple Developer — BackgroundTasks  
  https://developer.apple.com/documentation/backgroundtasks

- Apple Developer — UserNotifications / Remote Notifications  
  https://developer.apple.com/documentation/usernotifications

- Apple Developer — WebKit / WKWebsiteDataStore  
  https://developer.apple.com/documentation/webkit/wkwebsitedatastore

- PixiView-KMP  
  https://github.com/matsumo0922/PixiView-KMP

- fankt  
  https://github.com/matsumo0922/fankt
