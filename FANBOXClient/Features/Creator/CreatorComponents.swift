import SwiftUI
import SwiftData

/// Capsule filter chip used by the creator list.
struct CreatorsFilterChip: View {
    let title: String
    var systemImage: String? = nil
    var count: Int? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage).imageScale(.small) }
                Text(title)
                if let count {
                    Text("\(count)")
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                }
            }
            .font(.subheadline.weight(isSelected ? .semibold : .regular))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Lightweight account badges for list rows: renders from already-fetched `Account`s
/// (avoids one `@Query` per badge in long lists). Same look as `AccountBadge`.
struct CreatorAccountDots: View {
    let accounts: [Account]
    /// Names are shown when there are at most this many accounts; otherwise only colored dots.
    var maxNamed: Int = 2

    var body: some View {
        HStack(spacing: 6) {
            ForEach(accounts, id: \.id) { account in
                HStack(spacing: 3) {
                    Circle()
                        .fill(Color(hex: account.colorHex))
                        .frame(width: 8, height: 8)
                    if accounts.count <= maxNamed {
                        Text(account.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accounts.map(\.displayName).joined(separator: "、"))
    }
}

/// "Web で開く" menu that asks which account to use (SPEC §7.1 / §40: never mix sessions).
struct CreatorWebAccountMenu<Label: View>: View {
    /// Accounts to offer, in preferred order.
    let accounts: [Account]
    let destination: WebDestination
    @ViewBuilder var label: () -> Label
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Menu {
            if accounts.isEmpty {
                Text("有効なアカウントがありません")
            } else {
                Section("どのアカウントで開くか") {
                    ForEach(accounts, id: \.id) { account in
                        Button {
                            env.web.openWeb(account: account.id, destination: destination)
                        } label: {
                            Text(account.displayName)
                        }
                    }
                }
            }
        } label: {
            label()
        }
    }
}

/// Orders accounts so the ones related to a creator (supporting / following / owner) come first.
enum CreatorAccountOrdering {
    static func preferred(_ accounts: [Account], first related: [String]) -> [Account] {
        let relatedSet = Set(related)
        let head = related.compactMap { id in accounts.first { $0.id == id } }
        let tail = accounts.filter { !relatedSet.contains($0.id) }
        var seen: Set<String> = []
        return (head + tail).filter { seen.insert($0.id).inserted }
    }
}

/// Compact post card for the creator's Posts section.
struct CreatorPostCompactRow: View {
    let post: Post
    let accountsByID: [String: Account]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RemoteImageView(thumbnailURL: post.coverImageURL, maxVariant: .thumbnail, postID: post.postID, creatorID: post.creatorID)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if !post.isRead {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 7, height: 7)
                            .alignmentGuide(.firstTextBaseline) { d in d[.bottom] }
                            .accessibilityLabel("未読")
                    }
                    Text(post.title.isEmpty ? "(無題)" : post.title)
                        .font(.subheadline.weight(post.isRead ? .regular : .semibold))
                        .lineLimit(2)
                }
                if !post.excerpt.isEmpty {
                    Text(post.excerpt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(Formatters.shortDate(post.publishedAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if post.feeRequired > 0 {
                        PillLabel(text: Formatters.yen(post.feeRequired))
                    }
                    if post.offlineState != .none {
                        PillLabel(text: "Offline", systemImage: "arrow.down.circle.fill", tint: .green)
                    } else if post.hasCachedBody {
                        PillLabel(text: "本文あり", systemImage: "text.alignleft", tint: .blue)
                    }
                    if post.isFavorite {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                }
                let viewers = post.accessAccountIDs.compactMap { accountsByID[$0] }
                if !viewers.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "eye")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        CreatorAccountDots(accounts: viewers)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("閲覧可能: \(viewers.map(\.displayName).joined(separator: "、"))")
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
