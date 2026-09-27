import SwiftUI

/// Legal texts (SPEC §3.5 / §3.6 / §3.7 / §33). The copyright block is reproduced verbatim from SPEC §3.5.
enum LegalNotice {
    static let copyrightBlock = """
    Copyright © 2026 Masahiro Sato. All rights reserved.

    No license is granted for this source code.
    The source code is publicly available for inspection only.
    Permission to use, copy, modify, distribute, sublicense, or create
    derivative works is not granted unless separately authorized by
    the copyright holder.
    """

    static let policyPoints: [String] = [
        "Public Source ≠ Open Source。ソースコードを公開する場合も、閲覧のためだけに公開しています。",
        "OSSライセンスは付与していません（All Rights Reserved）。LICENSEファイルは意図的に置いていません。",
        "将来MIT / Apache-2.0 / MPLなどへ変更する可能性はありますが、現時点では許諾はありません。",
        "外部からのPull Requestは、著作権と再ライセンスの方針が決まるまで受け付けていません。",
    ]

    /// Apple SDK frameworks the app links (platform frameworks, not redistributed).
    static let appleFrameworks: [String] = [
        "SwiftUI", "SwiftData", "Foundation", "Observation", "UIKit", "WebKit", "Network", "UserNotifications",
        "BackgroundTasks", "Security (Keychain)", "CryptoKit", "ImageIO", "Photos", "PhotosUI", "UniformTypeIdentifiers",
        "QuickLook", "AVKit", "os (Logger)",
    ]

    static let thirdPartyPoints: [String] = [
        "アプリに組み込んでいる第三者のライブラリ・コードはありません（Swift Package / CocoaPods / Carthageも未使用）。",
        "使用しているのはiOS SDKのApple標準フレームワークのみです。これらはアプリに同梱・再配布されません。",
        "ビルド時のツールとしてXcodeGen（MIT License）を使いますが、アプリには含まれません。",
        "PixiView-KMP / fanktは、挙動・endpoint・データ構造を理解するための参考資料としてのみ参照しています。コードはコピーしていません。",
        "依存関係の台帳はTHIRD_PARTY.mdにあります。追加する前にライセンスとNOTICE / attributionの条件を確認します。",
    ]

    static let dataBoundaryPoints: [String] = [
        "本アプリはFANBOXのダウンローダーや一括保存ツールではありません。",
        "全Creator × 全履歴 × 全画像を定期的に総当たりで取得することはしません。",
        "通常の同期は最新ページから取得し、既に知っている投稿に到達した時点で止まります。",
        "オフライン保存は、閲覧した投稿と、自分で保存を指定した投稿（この投稿 / Creatorの最近N件）に限ります。",
        "Backgroundでは軽量なデータだけを取得し、Original画像や動画をまとめて取得しません。",
    ]

    static let privacyPoints: [String] = [
        "データはすべてこの端末の中に保存されます。開発者のサーバへ送るデータや、利用状況の計測はありません。",
        "お気に入り・タグ・メモ・既読状態・Read Laterはローカルだけの情報で、FANBOXへは送信しません。",
        "ログイン情報（Cookie / FANBOXSESSID / CSRF Token）はKeychainとアカウントごとのWebKitストアにだけ保存し、ログや画面に表示しません。",
        "決済手段はニックネーム・ブランド・下4桁・メモだけを保存します。カード番号・セキュリティコード・パスワードは保存しません。",
        "APNs Relay（任意・既定はオフ）を使う場合も、Relayへ渡すのはデバイストークンと不透明なアカウントのヒントだけです。",
    ]

    static let disclaimer = "本アプリは個人が自分のために作成した非公式クライアントです。pixiv / pixivFANBOXの公式アプリではなく、pixiv Inc.とは関係ありません。"
}

/// 法的情報 (SPEC §3.5 / §3.6 / §3.7).
struct LegalView: View {
    var body: some View {
        List {
            Section("著作権") {
                Text(LegalNotice.copyrightBlock)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .accessibilityIdentifier("copyrightNotice")
            }

            Section {
                BulletList(items: LegalNotice.policyPoints)
            } header: {
                Text("ライセンス方針")
            } footer: {
                Text("Public Source ≠ Open Source")
            }

            Section {
                BulletList(items: LegalNotice.thirdPartyPoints)
                DisclosureGroup("使用しているAppleフレームワーク") {
                    ForEach(LegalNotice.appleFrameworks, id: \.self) { name in
                        Text(name).font(.callout)
                    }
                }
            } header: {
                Text("第三者ライセンス")
            }

            Section("データ取得の範囲") {
                BulletList(items: LegalNotice.dataBoundaryPoints)
            }

            Section("プライバシー") {
                BulletList(items: LegalNotice.privacyPoints)
            }

            Section {
                Text(LegalNotice.disclaimer).font(.callout).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("法的情報")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("legalView")
    }
}

private struct BulletList: View {
    let items: [String]

    var body: some View {
        ForEach(items, id: \.self) { item in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                Text(item).font(.callout)
            }
        }
    }
}
