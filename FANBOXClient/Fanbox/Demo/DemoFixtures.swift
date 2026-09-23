import Foundation

/// Static, fictional fixture data of the demo world. Every name / title is prefixed or labeled "Demo".
/// Links point to `example.com` (reserved for documentation) — never to real services.
enum DemoFixtures {
    static let selfCreatorID = "demo-creator-self"
    static let timelinePageSize = 10
    static let commentPageSize = 10
    static let notificationPageSize = 10
    static let fanPageSize = 10

    // MARK: - Creators

    static let creators: [DemoCreatorFixture] = [
        DemoCreatorFixture(
            id: "demo-aoi", pixivUserID: "demo-u-1001", name: "Demo 絵描きアオイ",
            profileText: "（デモ用の架空クリエイターです）\n透明感のあるイラストを描いています。ラフ・メイキング・PSD を毎月公開中。",
            links: ["https://example.com/demo/aoi"],
            plans: [
                DemoPlanFixture(fee: 100, title: "応援プラン", description: "活動を応援していただけるプランです。"),
                DemoPlanFixture(fee: 500, title: "ラフプラン", description: "ラフや落書きを公開します。"),
                DemoPlanFixture(fee: 1000, title: "高解像度プラン", description: "完成イラストの高解像度版を公開します。"),
                DemoPlanFixture(fee: 3000, title: "メイキングプラン", description: "メイキング解説と PSD を公開します。"),
                DemoPlanFixture(fee: 5000, title: "スペシャルプラン", description: "すべての特典に加えて、月1回のリクエスト枠があります。"),
            ]),
        DemoCreatorFixture(
            id: "demo-mint", pixivUserID: "demo-u-1002", name: "Demo 作曲家ミント",
            profileText: "（デモ用の架空クリエイターです）\nゲームや動画向けの BGM を作っています。",
            links: ["https://example.com/demo/mint"],
            plans: [
                DemoPlanFixture(fee: 500, title: "リスナープラン", description: "新曲の試聴版と制作日記を公開します。"),
                DemoPlanFixture(fee: 1000, title: "フル音源プラン", description: "新曲のフル音源（mp3）を公開します。"),
                DemoPlanFixture(fee: 3000, title: "楽譜・ステムプラン", description: "楽譜 PDF とステムデータを公開します。"),
            ]),
        DemoCreatorFixture(
            id: "demo-shion", pixivUserID: "demo-u-1003", name: "Demo 小説家シオン",
            profileText: "（デモ用の架空クリエイターです）\n短編と連載小説を書いています。",
            links: ["https://example.com/demo/shion"],
            plans: [
                DemoPlanFixture(fee: 100, title: "読者プラン", description: "短編とあとがきを公開します。"),
                DemoPlanFixture(fee: 500, title: "連載プラン", description: "連載の最新話を先行公開します。"),
                DemoPlanFixture(fee: 1000, title: "書き下ろしプラン", description: "支援者限定の書き下ろしを公開します。"),
            ]),
        DemoCreatorFixture(
            id: "demo-kohaku", pixivUserID: "demo-u-1004", name: "Demo 3Dモデラーコハク",
            profileText: "（デモ用の架空クリエイターです）\n3D キャラクターモデルと衣装を制作しています。",
            links: ["https://example.com/demo/kohaku"],
            plans: [
                DemoPlanFixture(fee: 500, title: "プレビュープラン", description: "制作中モデルのプレビューを公開します。"),
                DemoPlanFixture(fee: 1000, title: "解説プラン", description: "モデリングやシェーダーの解説を公開します。"),
                DemoPlanFixture(fee: 5000, title: "モデル配布プラン", description: "モデルデータと制作ファイルを配布します。"),
            ]),
        DemoCreatorFixture(
            id: "demo-ruri", pixivUserID: "demo-u-1005", name: "Demo 漫画家ルリ",
            profileText: "（デモ用の架空クリエイターです）\n漫画『星の配達人』を連載中です。",
            links: ["https://example.com/demo/ruri"],
            plans: [
                DemoPlanFixture(fee: 100, title: "おためしプラン", description: "表紙ラフや 4 コマを公開します。"),
                DemoPlanFixture(fee: 500, title: "連載プラン", description: "最新話を 1 週間先行公開します。"),
                DemoPlanFixture(fee: 3000, title: "資料集プラン", description: "設定資料集 PDF を公開します。"),
            ]),
        DemoCreatorFixture(
            id: "demo-sora", pixivUserID: "demo-u-1006", name: "Demo 写真家ソラ",
            profileText: "（デモ用の架空クリエイターです）\n空と街の写真を撮っています。",
            links: ["https://example.com/demo/sora"],
            plans: [
                DemoPlanFixture(fee: 500, title: "フォトプラン", description: "未公開写真を毎週公開します。"),
                DemoPlanFixture(fee: 1000, title: "RAW プラン", description: "RAW データと現像レシピを公開します。"),
            ]),
        DemoCreatorFixture(
            id: "demo-hisui", pixivUserID: "demo-u-1007", name: "Demo ゲーム開発ヒスイ",
            profileText: "（デモ用の架空クリエイターです）\n個人でアドベンチャーゲームを開発しています。",
            links: ["https://example.com/demo/hisui"],
            plans: [
                DemoPlanFixture(fee: 1000, title: "テスタープラン", description: "開発中の体験版を配布します。"),
                DemoPlanFixture(fee: 5000, title: "開発支援プラン", description: "企画書やスタッフクレジットへの掲載があります。"),
            ]),
        DemoCreatorFixture(
            id: "demo-kuon", pixivUserID: "demo-u-1008", name: "Demo 動画クリエイタークオン",
            profileText: "（デモ用の架空クリエイターです）\n動画制作の Vlog とメイキングを投稿しています。",
            links: ["https://example.com/demo/kuon"],
            plans: [
                DemoPlanFixture(fee: 500, title: "メンバープラン", description: "限定動画を公開します。"),
                DemoPlanFixture(fee: 1000, title: "メイキングプラン", description: "編集プロジェクトの解説を公開します。"),
            ]),
        DemoCreatorFixture(
            id: selfCreatorID, pixivUserID: "demo-u-self", name: "Demo セルフ工房",
            profileText: "（デモ用の架空クリエイターです）\nこのアプリの Creator Mode を試すための自分のクリエイターページです。",
            links: ["https://example.com/demo/self"],
            plans: [
                DemoPlanFixture(fee: 100, title: "応援", description: "活動を応援していただけるプランです。"),
                DemoPlanFixture(fee: 500, title: "スタンダード", description: "新作イラストを公開します。"),
                DemoPlanFixture(fee: 1000, title: "メイキング", description: "メイキングと解説を公開します。"),
                DemoPlanFixture(fee: 3000, title: "プレミアム", description: "高解像度データと PSD を配布します。"),
            ]),
    ]

    static let creatorsByID: [String: DemoCreatorFixture] = Dictionary(uniqueKeysWithValues: creators.map { ($0.id, $0) })

    // MARK: - Profiles (who follows / supports what)

    static let profiles: [DemoProfile: DemoProfileFixture] = [
        .viewerA: DemoProfileFixture(
            profile: .viewerA, userName: "Demo 読者ハル",
            supports: [
                DemoSupportFixture(creatorID: "demo-aoi", fee: 500, paymentMethod: "card"),
                DemoSupportFixture(creatorID: "demo-mint", fee: 1000, paymentMethod: "card"),
                DemoSupportFixture(creatorID: "demo-shion", fee: 100, paymentMethod: "paypal", stopping: true),
                DemoSupportFixture(creatorID: "demo-ruri", fee: 3000, paymentMethod: "card"),
            ],
            followOnly: ["demo-sora", "demo-kohaku"],
            disappearingSupportCreatorID: nil),
        .viewerB: DemoProfileFixture(
            profile: .viewerB, userName: "Demo 読者ナツ",
            supports: [
                DemoSupportFixture(creatorID: "demo-aoi", fee: 1000, paymentMethod: "paypal"),
                DemoSupportFixture(creatorID: "demo-kohaku", fee: 5000, paymentMethod: "card"),
                DemoSupportFixture(creatorID: "demo-sora", fee: 500, paymentMethod: "card"),
                DemoSupportFixture(creatorID: "demo-kuon", fee: 500, paymentMethod: "card"),
            ],
            followOnly: ["demo-mint", "demo-hisui"],
            disappearingSupportCreatorID: "demo-kuon"),
        .creator: DemoProfileFixture(
            profile: .creator, userName: "Demo セルフ工房",
            supports: [
                DemoSupportFixture(creatorID: "demo-aoi", fee: 5000, paymentMethod: "card"),
            ],
            followOnly: ["demo-shion"],
            disappearingSupportCreatorID: nil),
    ]

    static func profile(_ p: DemoProfile) -> DemoProfileFixture { profiles[p]! }

    // MARK: - Fans (fictional users; also the commenters)

    static let fans: [DemoFanFixture] = [
        DemoFanFixture(userID: "demo-fan-01", name: "Demo ファン・ユキ", fee: 1000, state: .supporting, startedMinutesAgo: 400 * 1440, months: nil),
        DemoFanFixture(userID: "demo-fan-02", name: "Demo ファン・ケン", fee: 500, state: .supporting, startedMinutesAgo: 200 * 1440, months: nil),
        DemoFanFixture(userID: "demo-fan-03", name: "Demo ファン・ミオ", fee: 1000, state: .supporting, startedMinutesAgo: 130, months: nil),
        DemoFanFixture(userID: "demo-fan-04", name: "Demo ファン・リク", fee: 3000, state: .supporting, startedMinutesAgo: 90 * 1440, months: nil),
        DemoFanFixture(userID: "demo-fan-05", name: "Demo ファン・ハナ", fee: 100, state: .supporting, startedMinutesAgo: 30 * 1440, months: nil),
        DemoFanFixture(userID: "demo-fan-06", name: "Demo ファン・ソウタ", fee: 500, state: .supporting, startedMinutesAgo: 150 * 1440, months: nil),
        DemoFanFixture(userID: "demo-fan-07", name: "Demo ファン・アカリ", fee: 1000, state: .supporting, startedMinutesAgo: 60 * 1440, months: nil),
        DemoFanFixture(userID: "demo-fan-08", name: "Demo ファン・レン", fee: 500, state: .ended, startedMinutesAgo: 300 * 1440, months: 6),
        DemoFanFixture(userID: "demo-fan-09", name: "Demo ファン・ツムギ", fee: 500, state: .supporting, startedMinutesAgo: 1500, months: nil),
        DemoFanFixture(userID: "demo-fan-10", name: "Demo ファン・ユウト", fee: nil, state: .following, startedMinutesAgo: nil, months: nil),
        DemoFanFixture(userID: "demo-fan-11", name: "Demo ファン・メイ", fee: 3000, state: .supporting, startedMinutesAgo: 365 * 1440, months: nil),
        DemoFanFixture(userID: "demo-fan-12", name: "Demo ファン・カイ", fee: 100, state: .supporting, startedMinutesAgo: 20 * 1440, months: nil),
        DemoFanFixture(userID: "demo-fan-13", name: "Demo ファン・ノア", fee: nil, state: .following, startedMinutesAgo: nil, months: nil),
        DemoFanFixture(userID: "demo-fan-14", name: "Demo ファン・イオリ", fee: 1000, state: .ended, startedMinutesAgo: 120 * 1440, months: 2),
        DemoFanFixture(userID: "demo-fan-15", name: "Demo ファン・サク", fee: 500, state: .supporting, startedMinutesAgo: 45 * 1440, months: nil),
    ]

    // MARK: - Reader posts (8 creators, newest first)

    static let readerPosts: [DemoPostFixture] = [
        DemoPostFixture(id: "demo-post-101", creatorID: "demo-aoi", time: .minutesAgo(12), type: .image,
                        title: "Demo 新作イラスト「夏の終わり」", fee: 500, tags: ["イラスト", "オリジナル"], likes: 128, body: [
                            .paragraph("（デモ用の架空の投稿です）\n夏の終わりの夕暮れをテーマに描きました。"),
                            .images(count: 3, width: 2400, height: 3200),
                            .paragraph("高解像度版は高解像度プランで後日公開します。"),
                        ]),
        DemoPostFixture(id: "demo-post-102", creatorID: "demo-mint", time: .minutesAgo(45), type: .file,
                        title: "Demo BGM「朝の港」フル版", fee: 1000, tags: ["BGM", "作曲"], likes: 64, body: [
                            .paragraph("朝の港をイメージしたフル尺の BGM です。ループ版も同梱しています。"),
                            .audio(name: "asa-no-minato_full", size: 5_800_000),
                            .audio(name: "asa-no-minato_loop", size: 2_100_000),
                            .paragraph("動画などで使う場合はプロフィールの利用ガイド（デモ）をご確認ください。"),
                        ]),
        DemoPostFixture(id: "demo-post-103", creatorID: "demo-kohaku", time: .minutesAgo(120), type: .image,
                        title: "Demo 3Dモデル 新衣装プレビュー", fee: 1000, tags: ["3DCG", "モデリング"], likes: 92, body: [
                            .paragraph("秋向けの新衣装を制作中です。4 アングルのプレビューです。"),
                            .images(count: 4, width: 1920, height: 1080),
                            .paragraph("配布は来月を予定しています。"),
                        ]),
        DemoPostFixture(id: "demo-post-104", creatorID: "demo-ruri", time: .minutesAgo(180), type: .article,
                        title: "Demo 漫画『星の配達人』第12話", fee: 500, tags: ["漫画", "連載"], likes: 210, body: [
                            .header("第12話　約束の灯"),
                            .paragraph("配達人ミナは、灯台の町に最後の手紙を届けに向かいます。"),
                            .images(count: 5, width: 1600, height: 2400),
                            .styled("次回、第13話は来週公開予定です！", bold: ["第13話"], large: []),
                            .paragraph("感想はコメント欄にいただけると励みになります。"),
                        ]),
        DemoPostFixture(id: "demo-post-105", creatorID: "demo-shion", time: .minutesAgo(300), type: .text,
                        title: "Demo 短編小説『雨宿りの午後』", fee: 100, tags: ["小説", "短編"], likes: 45, body: [
                            .paragraph("商店街のアーケードの端で、私は古い傘を持った少年と並んで雨がやむのを待っていた。"),
                            .paragraph("「この雨、あと七分でやみますよ」と少年は言った。根拠を尋ねると、彼は空ではなく、自分の靴の先を見つめた。"),
                            .paragraph("七分後、本当に雨はやんだ。振り返ると、少年も傘も、最初からそこにいなかったかのように消えていた。"),
                            .paragraph("（おわり）"),
                        ]),
        DemoPostFixture(id: "demo-post-106", creatorID: "demo-aoi", time: .minutesAgo(480), type: .image,
                        title: "Demo ラフ詰め合わせ", fee: 1000, tags: ["ラフ", "イラスト"], likes: 77, body: [
                            .paragraph("今月描いたラフをまとめました。6 枚あります。"),
                            .images(count: 6, width: 1500, height: 2000),
                        ]),
        DemoPostFixture(id: "demo-post-107", creatorID: "demo-kuon", time: .minutesAgo(660), type: .video,
                        title: "Demo 制作Vlog #8", fee: 0, tags: ["Vlog", "動画制作"], likes: 51, body: [
                            .paragraph("今回は撮影機材の入れ替えについて話しています。"),
                            .externalVideo(provider: "youtube", id: "demoVlog0008"),
                            .paragraph("次回は編集ソフトの設定を紹介する予定です。"),
                        ]),
        DemoPostFixture(id: "demo-post-108", creatorID: "demo-sora", time: .minutesAgo(840), type: .image,
                        title: "Demo 写真 秋の空 6枚", fee: 500, tags: ["写真", "風景"], likes: 88, body: [
                            .paragraph("高い雲が気持ちいい季節になりました。"),
                            .images(count: 6, width: 3000, height: 2000),
                        ]),
        DemoPostFixture(id: "demo-post-109", creatorID: "demo-hisui", time: .minutesAgo(1200), type: .file,
                        title: "Demo 体験版 v0.3 配布", fee: 1000, tags: ["ゲーム制作", "体験版"], likes: 40, body: [
                            .paragraph("第 2 章の途中までプレイできます。不具合報告はコメントへお願いします。"),
                            .file(name: "demo-game_v0.3", ext: "zip", size: 48_000_000),
                            .file(name: "readme", ext: "pdf", size: 350_000),
                        ]),
        DemoPostFixture(id: "demo-post-110", creatorID: "demo-aoi", time: .daysAgo(1), type: .text,
                        title: "Demo 次回の予定について", fee: 0, tags: ["お知らせ"], likes: 150, body: [
                            .paragraph("いつも応援ありがとうございます。"),
                            .paragraph("来週はメイキング解説、再来週は PSD 配布を予定しています。"),
                            .paragraph("リクエストはスペシャルプランの方から受け付けています。"),
                        ]),
        DemoPostFixture(id: "demo-post-111", creatorID: "demo-mint", time: .daysAgo(1, hours: 4), type: .file,
                        title: "Demo 楽譜と音源セット", fee: 3000, tags: ["楽譜", "作曲"], likes: 33, body: [
                            .paragraph("ワルツ「星の庭」の楽譜・音源・ステムのセットです。"),
                            .audio(name: "hoshi-no-niwa", size: 4_200_000),
                            .file(name: "hoshi-no-niwa_score", ext: "pdf", size: 1_200_000),
                            .file(name: "hoshi-no-niwa_stems", ext: "zip", size: 88_000_000),
                        ]),
        DemoPostFixture(id: "demo-post-112", creatorID: "demo-ruri", time: .daysAgo(1, hours: 9), type: .image,
                        title: "Demo 表紙ラフ", fee: 100, tags: ["漫画", "ラフ"], likes: 60, body: [
                            .paragraph("単行本（デモ）の表紙ラフです。"),
                            .images(count: 1, width: 1600, height: 2400),
                        ]),
        DemoPostFixture(id: "demo-post-113", creatorID: "demo-kohaku", time: .daysAgo(2), type: .file,
                        title: "Demo モデリング タイムラプス", fee: 5000, tags: ["3DCG", "タイムラプス"], likes: 25, body: [
                            .paragraph("新衣装のモデリング工程を 20 分に圧縮したタイムラプスです。"),
                            .videoFile(name: "timelapse_1080p", size: 156_000_000),
                            .file(name: "project_files", ext: "zip", size: 240_000_000),
                        ]),
        DemoPostFixture(id: "demo-post-114", creatorID: "demo-shion", time: .daysAgo(2, hours: 6), type: .article,
                        title: "Demo 連載『灯台守の手紙』第3章", fee: 500, tags: ["小説", "連載"], likes: 38, body: [
                            .header("第3章　凪"),
                            .paragraph("風のない朝、灯台守は三通目の手紙を書き始めた。"),
                            .styled("宛先は、まだ一度も会ったことのない誰かだった。", bold: ["一度も会ったことのない誰か"], large: []),
                            .paragraph("海は鏡のように静かで、手紙の続きを急かす者は誰もいなかった。"),
                            .header("あとがき"),
                            .paragraph("第4章は少し間が空きます。気長にお待ちください。"),
                        ]),
        DemoPostFixture(id: "demo-post-115", creatorID: "demo-kuon", time: .daysAgo(2, hours: 20), type: .file,
                        title: "Demo 限定メイキング動画", fee: 500, tags: ["メイキング", "動画制作"], likes: 29, body: [
                            .paragraph("Vlog #8 の編集過程を収録した限定動画です。"),
                            .videoFile(name: "making_vlog08", size: 98_000_000),
                        ]),
        DemoPostFixture(id: "demo-post-116", creatorID: "demo-aoi", time: .daysAgo(3), type: .article,
                        title: "Demo 厚塗りメイキング解説", fee: 3000, tags: ["メイキング", "イラスト"], likes: 140, body: [
                            .header("1. ラフ"),
                            .paragraph("最初は 3 色だけで大きな形を決めます。"),
                            .images(count: 1, width: 1600, height: 1200),
                            .header("2. 色置き"),
                            .styled("ポイントは光の方向を最初に決めることです。", bold: [], large: ["光の方向"]),
                            .images(count: 2, width: 1600, height: 1200),
                            .header("3. 仕上げ"),
                            .styled("仕上げでは彩度を上げすぎないことが大切です。", bold: ["彩度を上げすぎない"], large: []),
                            .file(name: "demo-brush-set", ext: "zip", size: 2_400_000),
                            .link(url: "https://example.com/demo/aoi/brush-guide", title: "Demo ブラシ設定ガイド", subtitle: "example.com"),
                        ]),
        DemoPostFixture(id: "demo-post-117", creatorID: "demo-sora", time: .daysAgo(3, hours: 12), type: .text,
                        title: "Demo 撮影機材の話", fee: 0, tags: ["写真", "機材"], likes: 20, body: [
                            .paragraph("最近は単焦点レンズ 1 本で出かけることが多いです。"),
                            .paragraph("荷物が軽いと、歩く距離が伸びて、結果的に良い写真が増える気がします。"),
                        ]),
        DemoPostFixture(id: "demo-post-118", creatorID: "demo-mint", time: .daysAgo(4), type: .video,
                        title: "Demo 新曲MV公開", fee: 0, tags: ["MV", "作曲"], likes: 180, body: [
                            .paragraph("新曲のミュージックビデオを公開しました。"),
                            .externalVideo(provider: "youtube", id: "demoMV000012"),
                            .link(url: "https://example.com/demo/mint/lyrics", title: "Demo 歌詞ページ", subtitle: "example.com"),
                        ]),
        DemoPostFixture(id: "demo-post-119", creatorID: "demo-hisui", time: .daysAgo(4, hours: 8), type: .image,
                        title: "Demo 開発中スクリーンショット", fee: 0, tags: ["ゲーム制作"], likes: 55, body: [
                            .paragraph("第 3 章の背景を差し替えました。"),
                            .images(count: 3, width: 1920, height: 1080),
                        ]),
        DemoPostFixture(id: "demo-post-120", creatorID: "demo-ruri", time: .daysAgo(5), type: .file,
                        title: "Demo 設定資料集 PDF", fee: 3000, tags: ["設定資料", "漫画"], likes: 70, body: [
                            .paragraph("キャラクターと舞台の設定資料集 第 2 弾です。"),
                            .file(name: "settei_vol2", ext: "pdf", size: 24_000_000),
                        ]),
        DemoPostFixture(id: "demo-post-121", creatorID: "demo-kohaku", time: .daysAgo(5, hours: 10), type: .article,
                        title: "Demo 自作シェーダーの解説", fee: 1000, tags: ["3DCG", "シェーダー"], likes: 48, body: [
                            .header("トゥーン調の影を作る"),
                            .paragraph("法線とライト方向の内積を 2 段階に量子化しています。"),
                            .images(count: 2, width: 1600, height: 900),
                            .embed(provider: "gist", id: "demo-toon-shader-snippet"),
                            .paragraph("質問はコメントへどうぞ。"),
                        ]),
        DemoPostFixture(id: "demo-post-122", creatorID: "demo-aoi", time: .daysAgo(6), type: .image,
                        title: "Demo 落書き", fee: 100, tags: ["落書き"], likes: 66, body: [
                            .images(count: 1, width: 1200, height: 1200),
                            .paragraph("息抜きの落書きです。"),
                        ]),
        DemoPostFixture(id: "demo-post-123", creatorID: "demo-shion", time: .daysAgo(7), type: .text,
                        title: "Demo あとがき", fee: 0, tags: ["小説"], likes: 22, body: [
                            .paragraph("短編『雨宿りの午後』のあとがきです。"),
                            .paragraph("七分という数字には特に意味はありません。たぶん。"),
                        ]),
        DemoPostFixture(id: "demo-post-124", creatorID: "demo-kuon", time: .daysAgo(7, hours: 12), type: .article,
                        title: "Demo おすすめ機材リンク集", fee: 0, tags: ["機材", "動画制作"], likes: 31, body: [
                            .header("よく聞かれる機材まとめ"),
                            .link(url: "https://example.com/demo/kuon/mic", title: "Demo マイクの選び方", subtitle: "example.com"),
                            .link(url: "https://example.com/demo/kuon/light", title: "Demo 照明セットの比較", subtitle: "example.com"),
                            .link(url: "https://example.com/demo/kuon/edit", title: "Demo 編集環境の作り方", subtitle: "example.com"),
                            .paragraph("リンク先はすべてデモ用のダミーページです。"),
                        ]),
        DemoPostFixture(id: "demo-post-125", creatorID: "demo-mint", time: .daysAgo(8), type: .file,
                        title: "Demo ボツ曲供養", fee: 500, tags: ["BGM"], likes: 27, body: [
                            .paragraph("採用されなかった 2 曲を供養します。"),
                            .audio(name: "botsu_01", size: 3_300_000),
                            .audio(name: "botsu_02", size: 2_900_000),
                        ]),
        DemoPostFixture(id: "demo-post-126", creatorID: "demo-sora", time: .daysAgo(9), type: .image,
                        title: "Demo 夜景 3枚", fee: 1000, tags: ["写真", "夜景"], likes: 74, body: [
                            .paragraph("橋の上から撮った夜景です。"),
                            .images(count: 3, width: 3000, height: 2000),
                        ]),
        DemoPostFixture(id: "demo-post-127", creatorID: "demo-aoi", time: .daysAgo(10), type: .file,
                        title: "Demo PSD配布 今月分", fee: 3000, tags: ["PSD", "配布"], likes: 58, body: [
                            .paragraph("今月のイラスト 3 点の PSD です。レイヤー構成はそのままです。"),
                            .file(name: "demo-psd-set", ext: "zip", size: 180_000_000),
                        ]),
        DemoPostFixture(id: "demo-post-128", creatorID: "demo-hisui", time: .daysAgo(11), type: .text,
                        title: "Demo 開発ロードマップ", fee: 0, tags: ["ゲーム制作", "お知らせ"], likes: 37, body: [
                            .paragraph("今後の予定です。"),
                            .paragraph("・第 3 章 シナリオ完成\n・体験版 v0.4\n・BGM 差し替え"),
                        ]),
        DemoPostFixture(id: "demo-post-129", creatorID: "demo-ruri", time: .daysAgo(12), type: .image,
                        title: "Demo 4コマ", fee: 0, tags: ["4コマ", "漫画"], likes: 95, body: [
                            .images(count: 1, width: 1200, height: 3600),
                        ]),
        DemoPostFixture(id: "demo-post-130", creatorID: "demo-kohaku", time: .daysAgo(13), type: .image,
                        title: "Demo 素体モデル 配布告知", fee: 500, tags: ["3DCG", "配布"], likes: 43, body: [
                            .paragraph("素体モデルの配布を予定しています。仕様のプレビューです。"),
                            .images(count: 2, width: 1920, height: 1080),
                        ]),
        DemoPostFixture(id: "demo-post-131", creatorID: "demo-shion", time: .daysAgo(14), type: .entry,
                        title: "Demo 旧ブログ再掲", fee: 0, tags: ["小説"], likes: 12, body: [
                            .paragraph("昔のブログに書いた掌編を再掲します。"),
                            .paragraph("夜行バスの窓に映る自分の顔が、少しだけ知らない人に見えた。"),
                        ]),
        DemoPostFixture(id: "demo-post-132", creatorID: "demo-kuon", time: .daysAgo(15), type: .article,
                        title: "Demo 動画編集ワークフロー", fee: 1000, tags: ["動画制作", "メイキング"], likes: 34, body: [
                            .header("素材整理からの流れ"),
                            .paragraph("撮影後はまず素材を日付と場面ごとにフォルダ分けします。"),
                            .images(count: 2, width: 1920, height: 1080),
                            .externalVideo(provider: "vimeo", id: "demo-77881"),
                        ]),
        DemoPostFixture(id: "demo-post-133", creatorID: "demo-mint", time: .daysAgo(16), type: .text,
                        title: "Demo 制作近況", fee: 500, tags: ["お知らせ"], likes: 19, body: [
                            .paragraph("新しい音源ライブラリを試しています。次の曲は少しにぎやかになりそうです。"),
                        ]),
        DemoPostFixture(id: "demo-post-134", creatorID: "demo-aoi", time: .daysAgo(18), type: .image,
                        title: "Demo 過去絵リメイク", fee: 500, tags: ["イラスト", "リメイク"], likes: 101, body: [
                            .paragraph("3 年前の絵を描き直しました。左が昔、右が今です。"),
                            .images(count: 2, width: 1500, height: 2000),
                        ]),
        DemoPostFixture(id: "demo-post-135", creatorID: "demo-sora", time: .daysAgo(20), type: .file,
                        title: "Demo RAW データ配布", fee: 1000, tags: ["写真", "RAW"], likes: 16, body: [
                            .paragraph("秋の空シリーズの RAW データです。"),
                            .file(name: "autumn_sky_raw", ext: "zip", size: 320_000_000),
                        ]),
        DemoPostFixture(id: "demo-post-136", creatorID: "demo-ruri", time: .daysAgo(22), type: .article,
                        title: "Demo ネーム公開", fee: 500, tags: ["ネーム", "漫画"], likes: 49, body: [
                            .header("第11話 ネーム"),
                            .images(count: 3, width: 1600, height: 2400),
                            .paragraph("完成原稿との違いを見比べてみてください。"),
                        ]),
        DemoPostFixture(id: "demo-post-137", creatorID: "demo-kohaku", time: .daysAgo(24), type: .video,
                        title: "Demo ポートフォリオ動画", fee: 0, tags: ["3DCG"], likes: 63, body: [
                            .externalVideo(provider: "youtube", id: "demoPortfolio1"),
                            .paragraph("これまでの制作物をまとめた動画です。"),
                        ]),
        DemoPostFixture(id: "demo-post-138", creatorID: "demo-hisui", time: .daysAgo(26), type: .file,
                        title: "Demo 企画書", fee: 5000, tags: ["ゲーム制作", "企画"], likes: 8, body: [
                            .paragraph("次回作の企画書です。開発支援プランの方向けです。"),
                            .file(name: "kikakusho", ext: "pdf", size: 5_000_000),
                        ]),
        DemoPostFixture(id: "demo-post-139", creatorID: "demo-shion", time: .daysAgo(28), type: .text,
                        title: "Demo 短歌十首", fee: 0, tags: ["短歌"], likes: 18, body: [
                            .paragraph("改札の音だけ残して夏が行く　白いシャツにはまだ海の塩"),
                            .paragraph("（ほか九首は後日まとめて掲載します）"),
                        ]),
        DemoPostFixture(id: "demo-post-140", creatorID: "demo-aoi", time: .daysAgo(30), type: .text,
                        title: "Demo 支援プラン改定のお知らせ", fee: 0, tags: ["お知らせ"], likes: 84, body: [
                            .paragraph("来月からプランの内容を一部見直します。"),
                            .styled("料金の変更はありません。", bold: ["料金の変更はありません"], large: []),
                        ]),
    ]

    // MARK: - Self creator (Creator Mode): 4 published + 2 drafts

    static let managedPosts: [DemoPostFixture] = [
        DemoPostFixture(id: "demo-post-901", creatorID: selfCreatorID, time: .minutesAgo(90), type: .image,
                        title: "Demo 新作イラスト『星降る丘』", fee: 500, tags: ["イラスト", "オリジナル"], likes: 42, body: [
                            .paragraph("流れ星がたくさん見える丘を描きました。"),
                            .images(count: 2, width: 2000, height: 2800),
                            .paragraph("高解像度版はプレミアムプランで公開予定です。"),
                        ]),
        DemoPostFixture(id: "demo-post-902", creatorID: selfCreatorID, time: .daysAgo(2), type: .text,
                        title: "Demo 今月の制作予定", fee: 0, tags: ["お知らせ"], likes: 18, body: [
                            .paragraph("今月は新作 2 枚とメイキング 1 本を予定しています。"),
                            .paragraph("リクエストは来月から受付を検討しています。"),
                        ]),
        DemoPostFixture(id: "demo-post-903", creatorID: selfCreatorID, time: .daysAgo(6), type: .article,
                        title: "Demo メイキング：線画から仕上げまで", fee: 1000, tags: ["メイキング"], likes: 27, body: [
                            .header("線画"),
                            .paragraph("線画は 2 本のペンを使い分けています。"),
                            .images(count: 1, width: 1600, height: 1200),
                            .header("仕上げ"),
                            .styled("最後にグロー効果を少しだけ足します。", bold: ["少しだけ"], large: []),
                            .file(name: "demo-actions", ext: "zip", size: 1_500_000),
                        ]),
        DemoPostFixture(id: "demo-post-904", creatorID: selfCreatorID, time: .daysAgo(12), type: .file,
                        title: "Demo 高解像度データ配布", fee: 3000, tags: ["配布"], likes: 11, body: [
                            .paragraph("先月のイラストの高解像度データです。"),
                            .file(name: "demo-highres-set", ext: "zip", size: 95_000_000),
                        ]),
        DemoPostFixture(id: "demo-post-905", creatorID: selfCreatorID, time: .hoursAgo(3), type: .image,
                        title: "Demo（下書き）次回作のラフ", fee: 500, tags: ["ラフ"], likes: 0, body: [
                            .paragraph("次回作のラフです（下書き）。"),
                            .images(count: 1, width: 1500, height: 2000),
                        ], status: .draft),
        DemoPostFixture(id: "demo-post-906", creatorID: selfCreatorID, time: .daysAgo(1), type: .article,
                        title: "Demo（下書き）年末企画のお知らせ", fee: 0, tags: ["お知らせ"], likes: 0, body: [
                            .header("年末企画"),
                            .paragraph("年末に支援者向けの企画を予定しています（下書き）。"),
                            .link(url: "https://example.com/demo/self/event", title: "Demo 企画詳細", subtitle: "example.com"),
                        ], status: .draft),
    ]

    // MARK: - Comments

    static let comments: [DemoCommentFixture] = [
        // demo-post-101 (Demo 絵描きアオイ)
        DemoCommentFixture(id: "demo-c-101-1", postID: "demo-post-101", parentID: nil, author: .fan(0), time: .minutesAgo(10),
                           body: "色使いがとても綺麗です！", likes: 3),
        DemoCommentFixture(id: "demo-c-101-2", postID: "demo-post-101", parentID: "demo-c-101-1", author: .postCreator,
                           time: .minutesAgo(8), body: "ありがとうございます！今回は夕方の光を意識しました。"),
        DemoCommentFixture(id: "demo-c-101-3", postID: "demo-post-101", parentID: nil, author: .profile(.viewerA), time: .minutesAgo(9),
                           body: "待ってました！空気感が最高です。", likes: 1),
        DemoCommentFixture(id: "demo-c-101-4", postID: "demo-post-101", parentID: "demo-c-101-3", author: .postCreator,
                           time: .minutesAgo(5), body: "いつもありがとうございます！"),
        DemoCommentFixture(id: "demo-c-101-5", postID: "demo-post-101", parentID: nil, author: .fan(2), time: .minutesAgo(3),
                           body: "壁紙にしたいです。"),
        // demo-post-102 (Demo 作曲家ミント)
        DemoCommentFixture(id: "demo-c-102-1", postID: "demo-post-102", parentID: nil, author: .fan(6), time: .minutesAgo(30),
                           body: "イントロから好きです。"),
        // demo-post-103 (Demo 3Dモデラーコハク)
        DemoCommentFixture(id: "demo-c-103-1", postID: "demo-post-103", parentID: nil, author: .profile(.viewerB), time: .minutesAgo(100),
                           body: "新衣装かわいいです！"),
        DemoCommentFixture(id: "demo-c-103-2", postID: "demo-post-103", parentID: "demo-c-103-1", author: .postCreator,
                           time: .minutesAgo(70), body: "ありがとうございます、細部も見てもらえると嬉しいです。"),
        DemoCommentFixture(id: "demo-c-103-3", postID: "demo-post-103", parentID: nil, author: .fan(3), time: .minutesAgo(60),
                           body: "ボーンの入れ方が気になります。"),
        // demo-post-104 (Demo 漫画家ルリ)
        DemoCommentFixture(id: "demo-c-104-1", postID: "demo-post-104", parentID: nil, author: .profile(.viewerA), time: .minutesAgo(150),
                           body: "続きが気になります！", likes: 4),
        DemoCommentFixture(id: "demo-c-104-2", postID: "demo-post-104", parentID: "demo-c-104-1", author: .postCreator,
                           time: .minutesAgo(120), body: "来週更新予定です！"),
        DemoCommentFixture(id: "demo-c-104-3", postID: "demo-post-104", parentID: "demo-c-104-2", author: .fan(1),
                           time: .minutesAgo(100), body: "私も楽しみです。"),
        DemoCommentFixture(id: "demo-c-104-4", postID: "demo-post-104", parentID: nil, author: .fan(10), time: .minutesAgo(90),
                           body: "ミナの表情が良かったです。"),
        // demo-post-106 (Demo 絵描きアオイ, ¥1,000)
        DemoCommentFixture(id: "demo-c-106-1", postID: "demo-post-106", parentID: nil, author: .profile(.viewerB), time: .minutesAgo(420),
                           body: "ラフの線が好きです。"),
        DemoCommentFixture(id: "demo-c-106-2", postID: "demo-post-106", parentID: nil, author: .fan(3), time: .minutesAgo(360),
                           body: "3 枚目の構図が好きです。"),
        DemoCommentFixture(id: "demo-c-106-3", postID: "demo-post-106", parentID: "demo-c-106-2", author: .postCreator,
                           time: .minutesAgo(300), body: "ありがとうございます！清書するかもしれません。"),
        // demo-post-107 (Demo 動画クリエイタークオン, free)
        DemoCommentFixture(id: "demo-c-107-1", postID: "demo-post-107", parentID: nil, author: .fan(7), time: .minutesAgo(600),
                           body: "Vlog いつも楽しみにしています。"),
        DemoCommentFixture(id: "demo-c-107-2", postID: "demo-post-107", parentID: nil, author: .profile(.viewerB), time: .minutesAgo(540),
                           body: "機材紹介、助かります。"),
        DemoCommentFixture(id: "demo-c-107-3", postID: "demo-post-107", parentID: "demo-c-107-2", author: .postCreator,
                           time: .minutesAgo(480), body: "参考になれば嬉しいです！"),
        // demo-post-110 (Demo 絵描きアオイ, free)
        DemoCommentFixture(id: "demo-c-110-1", postID: "demo-post-110", parentID: nil, author: .fan(4), time: .minutesAgo(1380),
                           body: "メイキング楽しみにしています。"),
        DemoCommentFixture(id: "demo-c-110-2", postID: "demo-post-110", parentID: nil, author: .profile(.creator), time: .minutesAgo(1200),
                           body: "いつも応援しています！"),
        // demo-post-901 (self creator)
        DemoCommentFixture(id: "demo-c-901-1", postID: "demo-post-901", parentID: nil, author: .fan(0), time: .minutesAgo(60),
                           body: "星の描き込みがすごい…！", likes: 2),
        DemoCommentFixture(id: "demo-c-901-2", postID: "demo-post-901", parentID: "demo-c-901-1", author: .postCreator,
                           time: .minutesAgo(40), body: "ありがとうございます！時間をかけました。"),
        DemoCommentFixture(id: "demo-c-901-3", postID: "demo-post-901", parentID: "demo-c-901-2", author: .fan(0),
                           time: .minutesAgo(25), body: "次回作も楽しみにしています。"),
        DemoCommentFixture(id: "demo-c-901-4", postID: "demo-post-901", parentID: nil, author: .fan(2), time: .minutesAgo(18),
                           body: "色合いが優しくて好きです。"),
        DemoCommentFixture(id: "demo-c-901-5", postID: "demo-post-901", parentID: nil, author: .fan(8), time: .minutesAgo(6),
                           body: "壁紙サイズも欲しいです！"),
        // demo-post-902 (self creator)
        DemoCommentFixture(id: "demo-c-902-1", postID: "demo-post-902", parentID: nil, author: .fan(1), time: .daysAgo(1, hours: 21),
                           body: "無理せず頑張ってください。"),
        DemoCommentFixture(id: "demo-c-902-2", postID: "demo-post-902", parentID: nil, author: .fan(3), time: .daysAgo(1),
                           body: "リクエスト枠はありますか？"),
        DemoCommentFixture(id: "demo-c-902-3", postID: "demo-post-902", parentID: "demo-c-902-2", author: .postCreator,
                           time: .hoursAgo(20), body: "来月から検討しています！"),
        // demo-post-903 (self creator)
        DemoCommentFixture(id: "demo-c-903-1", postID: "demo-post-903", parentID: nil, author: .fan(5), time: .daysAgo(5),
                           body: "とても参考になりました。"),
    ]

    // MARK: - Notifications

    /// The same FANBOX event (new post of a creator supported by every demo profile). Each account receives it with its
    /// own remote id but identical type / postID / creatorID, which exercises cross-account dedupe (SPEC §27).
    static let sharedNewPost = DemoNotificationFixture(
        key: "newpost-101", type: .newPost, rawType: "post_published", time: .minutesAgo(12), creatorID: "demo-aoi",
        postID: "demo-post-101", commentID: nil, newsletterID: nil, actorName: "Demo 絵描きアオイ",
        actorIconURL: creatorsByID["demo-aoi"]?.iconURL, title: "Demo 絵描きアオイ が新しい投稿を公開しました",
        message: "Demo 新作イラスト「夏の終わり」", unread: true)

    private static func newPost(_ postID: String, unread: Bool) -> DemoNotificationFixture {
        let post = readerPosts.first { $0.id == postID }!
        let creator = creatorsByID[post.creatorID]!
        return DemoNotificationFixture(
            key: "newpost-\(postID)", type: .newPost, rawType: "post_published", time: post.time, creatorID: creator.id,
            postID: postID, commentID: nil, newsletterID: nil, actorName: creator.name, actorIconURL: creator.iconURL,
            title: "\(creator.name) が新しい投稿を公開しました", message: post.title, unread: unread)
    }

    private static func reply(_ commentID: String, unread: Bool) -> DemoNotificationFixture {
        let comment = comments.first { $0.id == commentID }!
        let post = (readerPosts + managedPosts).first { $0.id == comment.postID }!
        let creator = creatorsByID[post.creatorID]!
        let actor: (String, String?)
        switch comment.author {
        case .fan(let i): actor = (fans[i].name, fans[i].iconURL)
        default: actor = (creator.name, creator.iconURL)
        }
        return DemoNotificationFixture(
            key: "reply-\(commentID)", type: .commentReply, rawType: "comment_reply", time: comment.time, creatorID: creator.id,
            postID: post.id, commentID: commentID, newsletterID: nil, actorName: actor.0, actorIconURL: actor.1,
            title: "\(actor.0) さんがあなたのコメントに返信しました", message: comment.body, unread: unread)
    }

    private static func ownPostComment(_ commentID: String, unread: Bool) -> DemoNotificationFixture {
        let comment = comments.first { $0.id == commentID }!
        guard case .fan(let i) = comment.author else { fatalError("fixture comment must be from a fan") }
        let post = managedPosts.first { $0.id == comment.postID }!
        return DemoNotificationFixture(
            key: "comment-\(commentID)", type: .comment, rawType: "post_comment", time: comment.time, creatorID: selfCreatorID,
            postID: post.id, commentID: commentID, newsletterID: nil, actorName: fans[i].name, actorIconURL: fans[i].iconURL,
            title: "\(fans[i].name) さんが「\(post.title)」にコメントしました", message: comment.body, unread: unread)
    }

    private static func newsletterNotice(_ id: String, unread: Bool) -> DemoNotificationFixture {
        let letter = newsletters.values.flatMap { $0 }.first { $0.id == id }!
        let creator = creatorsByID[letter.creatorID]!
        return DemoNotificationFixture(
            key: "newsletter-\(id)", type: .newsletter, rawType: "newsletter", time: letter.time, creatorID: creator.id,
            postID: nil, commentID: nil, newsletterID: id, actorName: creator.name, actorIconURL: creator.iconURL,
            title: "\(creator.name) からおたよりが届きました", message: letter.title, unread: unread)
    }

    static let notifications: [DemoProfile: [DemoNotificationFixture]] = [
        .viewerA: [
            sharedNewPost,
            reply("demo-c-101-4", unread: true),
            newPost("demo-post-102", unread: true),
            reply("demo-c-104-2", unread: false),
            newPost("demo-post-104", unread: true),
            newsletterNotice("demo-nl-a-1", unread: true),
            newPost("demo-post-105", unread: false),
            newPost("demo-post-110", unread: false),
            newsletterNotice("demo-nl-a-2", unread: false),
            newPost("demo-post-112", unread: false),
            DemoNotificationFixture(
                key: "support-mint-change", type: .supportChanged, rawType: "support_plan_changed", time: .thisMonth(0.6),
                creatorID: "demo-mint", postID: nil, commentID: nil, newsletterID: nil, actorName: "Demo 作曲家ミント",
                actorIconURL: creatorsByID["demo-mint"]?.iconURL, title: "支援プランが変更されました",
                message: "Demo 作曲家ミント：リスナープラン ¥500 → フル音源プラン ¥1,000", unread: false),
            DemoNotificationFixture(
                key: "other-maintenance", type: .other, rawType: "announcement", time: .daysAgo(3), creatorID: nil, postID: nil,
                commentID: nil, newsletterID: nil, actorName: nil, actorIconURL: nil, title: "お知らせ（Demo）",
                message: "デモ用のお知らせです。実在のサービスとは関係ありません。", unread: false),
        ],
        .viewerB: [
            sharedNewPost,
            reply("demo-c-103-2", unread: true),
            newPost("demo-post-103", unread: true),
            newsletterNotice("demo-nl-b-1", unread: true),
            reply("demo-c-107-3", unread: false),
            newPost("demo-post-108", unread: false),
            DemoNotificationFixture(
                key: "payment-kuon", type: .paymentAttention, rawType: "payment_attention", time: .daysAgo(1, hours: 2),
                creatorID: "demo-kuon", postID: nil, commentID: nil, newsletterID: nil, actorName: nil, actorIconURL: nil,
                title: "お支払い状況をご確認ください（Demo）",
                message: "Demo 動画クリエイタークオン への支援について、お支払い状況の確認をお願いします。", unread: true),
            DemoNotificationFixture(
                key: "support-sora-start", type: .supportChanged, rawType: "support_started", time: .thisMonth(0.3),
                creatorID: "demo-sora", postID: nil, commentID: nil, newsletterID: nil, actorName: "Demo 写真家ソラ",
                actorIconURL: creatorsByID["demo-sora"]?.iconURL, title: "支援を開始しました",
                message: "Demo 写真家ソラ：フォトプラン ¥500", unread: false),
            newPost("demo-post-113", unread: false),
            newsletterNotice("demo-nl-b-2", unread: false),
            DemoNotificationFixture(
                key: "other-feature", type: .other, rawType: "announcement", time: .daysAgo(5), creatorID: nil, postID: nil,
                commentID: nil, newsletterID: nil, actorName: nil, actorIconURL: nil, title: "お知らせ（Demo）",
                message: "デモ用の新機能のお知らせです。実在のサービスとは関係ありません。", unread: false),
        ],
        .creator: [
            ownPostComment("demo-c-901-5", unread: true),
            sharedNewPost,
            ownPostComment("demo-c-901-4", unread: true),
            reply("demo-c-901-3", unread: true),
            DemoNotificationFixture(
                key: "supporter-fan-03", type: .newSupporter, rawType: "new_supporter", time: .minutesAgo(130),
                creatorID: selfCreatorID, postID: nil, commentID: nil, newsletterID: nil, actorName: fans[2].name,
                actorIconURL: fans[2].iconURL, title: "新しい支援者がいます",
                message: "\(fans[2].name) さんが「メイキング」プラン（¥1,000）で支援を開始しました", unread: true),
            ownPostComment("demo-c-902-2", unread: false),
            DemoNotificationFixture(
                key: "supporter-fan-09", type: .newSupporter, rawType: "new_supporter", time: .minutesAgo(1500),
                creatorID: selfCreatorID, postID: nil, commentID: nil, newsletterID: nil, actorName: fans[8].name,
                actorIconURL: fans[8].iconURL, title: "新しい支援者がいます",
                message: "\(fans[8].name) さんが「スタンダード」プラン（¥500）で支援を開始しました", unread: false),
            newsletterNotice("demo-nl-c-1", unread: false),
            DemoNotificationFixture(
                key: "other-creator-tips", type: .other, rawType: "creator_announcement", time: .daysAgo(4), creatorID: nil,
                postID: nil, commentID: nil, newsletterID: nil, actorName: nil, actorIconURL: nil, title: "クリエイター向けのお知らせ（Demo）",
                message: "デモ用のお知らせです。実在のサービスとは関係ありません。", unread: false),
        ],
    ]

    // MARK: - おたより

    static let newsletters: [DemoProfile: [DemoNewsletterFixture]] = [
        .viewerA: [
            DemoNewsletterFixture(id: "demo-nl-a-1", creatorID: "demo-mint", title: "Demo 新曲の制作裏話",
                                  body: "いつも支援ありがとうございます。\n\n「朝の港」は、早朝の散歩中に聞こえた汽笛から着想しました。\nフル版では後半にストリングスを足しています。\n\n次回もよろしくお願いします。（デモ用のおたよりです）",
                                  time: .hoursAgo(2), isRead: false),
            DemoNewsletterFixture(id: "demo-nl-a-2", creatorID: "demo-ruri", title: "Demo 第12話の制作メモ",
                                  body: "第12話は背景を描き込みすぎて締切ぎりぎりでした。\n感想ありがとうございます！（デモ用のおたよりです）",
                                  time: .daysAgo(1), isRead: true),
        ],
        .viewerB: [
            DemoNewsletterFixture(id: "demo-nl-b-1", creatorID: "demo-kohaku", title: "Demo 新衣装のこだわり",
                                  body: "モデル配布プランの皆さまへ。\n\n今回の衣装は布の厚みを表現するために、裏地も別メッシュで作っています。\n配布まで少々お待ちください。（デモ用のおたよりです）",
                                  time: .hoursAgo(6), isRead: false),
            DemoNewsletterFixture(id: "demo-nl-b-2", creatorID: "demo-aoi", title: "Demo いつも支援ありがとうございます",
                                  body: "高解像度プランの皆さま、いつもありがとうございます。\n来月もよろしくお願いします。（デモ用のおたよりです）",
                                  time: .daysAgo(4), isRead: true),
        ],
        .creator: [
            DemoNewsletterFixture(id: "demo-nl-c-1", creatorID: "demo-aoi", title: "Demo スペシャルプランの皆さまへ",
                                  body: "今月のリクエストを受け付けています。コメントかメッセージでお知らせください。（デモ用のおたよりです）",
                                  time: .daysAgo(3), isRead: false),
        ],
    ]

    // MARK: - Paid payment records
    // viewerA: mid-month plan change (ミント ¥500 → ¥1,000) ⇒ 今月実請求 ¥5,100 ≠ 定常月額 ¥4,600.
    // viewerB: a support that ended after this month's payment (シオン) ⇒ 今月実請求 ¥7,000; クオン has no payment this month.

    static let payments: [DemoProfile: [DemoPaymentFixture]] = [
        .viewerA: [
            DemoPaymentFixture(id: "demo-pay-a-01", creatorID: "demo-aoi", amount: 500, time: .thisMonth(0.05), paymentMethod: "card"),
            DemoPaymentFixture(id: "demo-pay-a-02", creatorID: "demo-mint", amount: 500, time: .thisMonth(0.05), paymentMethod: "card"),
            DemoPaymentFixture(id: "demo-pay-a-03", creatorID: "demo-shion", amount: 100, time: .thisMonth(0.05), paymentMethod: "paypal"),
            DemoPaymentFixture(id: "demo-pay-a-04", creatorID: "demo-ruri", amount: 3000, time: .thisMonth(0.05), paymentMethod: "card"),
            DemoPaymentFixture(id: "demo-pay-a-05", creatorID: "demo-mint", amount: 1000, time: .thisMonth(0.6), paymentMethod: "card"),
            DemoPaymentFixture(id: "demo-pay-a-11", creatorID: "demo-aoi", amount: 500, time: .monthsAgo(1, day: 1, hour: 9), paymentMethod: "card"),
            DemoPaymentFixture(id: "demo-pay-a-12", creatorID: "demo-mint", amount: 500, time: .monthsAgo(1, day: 1, hour: 9), paymentMethod: "card"),
            DemoPaymentFixture(id: "demo-pay-a-13", creatorID: "demo-shion", amount: 100, time: .monthsAgo(1, day: 1, hour: 9), paymentMethod: "paypal"),
            DemoPaymentFixture(id: "demo-pay-a-14", creatorID: "demo-ruri", amount: 3000, time: .monthsAgo(1, day: 1, hour: 9), paymentMethod: "card"),
            DemoPaymentFixture(id: "demo-pay-a-21", creatorID: "demo-aoi", amount: 500, time: .monthsAgo(2, day: 1, hour: 9), paymentMethod: "card"),
            DemoPaymentFixture(id: "demo-pay-a-22", creatorID: "demo-mint", amount: 500, time: .monthsAgo(2, day: 1, hour: 9), paymentMethod: "card"),
            DemoPaymentFixture(id: "demo-pay-a-23", creatorID: "demo-ruri", amount: 3000, time: .monthsAgo(2, day: 1, hour: 9), paymentMethod: "card"),
        ],
        .viewerB: [
            DemoPaymentFixture(id: "demo-pay-b-01", creatorID: "demo-aoi", amount: 1000, time: .thisMonth(0.05), paymentMethod: "paypal"),
            DemoPaymentFixture(id: "demo-pay-b-02", creatorID: "demo-kohaku", amount: 5000, time: .thisMonth(0.05), paymentMethod: "card"),
            DemoPaymentFixture(id: "demo-pay-b-03", creatorID: "demo-shion", amount: 500, time: .thisMonth(0.05), paymentMethod: "card"),
            DemoPaymentFixture(id: "demo-pay-b-04", creatorID: "demo-sora", amount: 500, time: .thisMonth(0.3), paymentMethod: "card"),
            DemoPaymentFixture(id: "demo-pay-b-11", creatorID: "demo-aoi", amount: 1000, time: .monthsAgo(1, day: 1, hour: 10), paymentMethod: "paypal"),
            DemoPaymentFixture(id: "demo-pay-b-12", creatorID: "demo-kohaku", amount: 5000, time: .monthsAgo(1, day: 1, hour: 10), paymentMethod: "card"),
            DemoPaymentFixture(id: "demo-pay-b-13", creatorID: "demo-kuon", amount: 500, time: .monthsAgo(1, day: 1, hour: 10), paymentMethod: "card"),
            DemoPaymentFixture(id: "demo-pay-b-14", creatorID: "demo-shion", amount: 500, time: .monthsAgo(1, day: 1, hour: 10), paymentMethod: "card"),
            DemoPaymentFixture(id: "demo-pay-b-21", creatorID: "demo-aoi", amount: 1000, time: .monthsAgo(2, day: 1, hour: 10), paymentMethod: "paypal"),
            DemoPaymentFixture(id: "demo-pay-b-22", creatorID: "demo-kohaku", amount: 5000, time: .monthsAgo(2, day: 1, hour: 10), paymentMethod: "card"),
            DemoPaymentFixture(id: "demo-pay-b-23", creatorID: "demo-kuon", amount: 500, time: .monthsAgo(2, day: 1, hour: 10), paymentMethod: "card"),
        ],
        .creator: [
            DemoPaymentFixture(id: "demo-pay-c-01", creatorID: "demo-aoi", amount: 5000, time: .thisMonth(0.05), paymentMethod: "card"),
            DemoPaymentFixture(id: "demo-pay-c-11", creatorID: "demo-aoi", amount: 5000, time: .monthsAgo(1, day: 1, hour: 8), paymentMethod: "card"),
            DemoPaymentFixture(id: "demo-pay-c-21", creatorID: "demo-aoi", amount: 5000, time: .monthsAgo(2, day: 1, hour: 8), paymentMethod: "card"),
        ],
    ]
}
