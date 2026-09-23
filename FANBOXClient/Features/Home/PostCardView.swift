import SwiftUI

/// Feed card (SPEC §5): creator icon + name, 投稿日, タイトル, 本文冒頭, Thumbnail, 閲覧可能 Account, 対象 Plan,
/// 既読状態, Offline / Cache 状態.
struct PostCardView: View {
    let post: Post
    /// Plans of the post's creator (for the "対象 Plan" label). Optional.
    var plans: [Plan] = []

    @Environment(AppEnvironment.self) private var env

    private var excerpt: String {
        let raw = post.excerpt.isEmpty ? String(post.bodyText.prefix(200)) : post.excerpt
        return raw.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private var hidesThumbnail: Bool { post.hasAdultContent && !env.settings.showAdultContent }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                header
                Text(post.title.isEmpty ? "(無題)" : post.title)
                    .font(.headline)
                    .fontWeight(post.isRead ? .regular : .semibold)
                    .foregroundStyle(post.isRead ? .secondary : .primary)
                    .lineLimit(2)
                if !excerpt.isEmpty {
                    Text(excerpt)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if !post.accessAccountIDs.isEmpty {
                    AccountBadgeRow(accountIDs: post.accessAccountIDs)
                        .accessibilityLabel("閲覧可能: \(post.accessAccountIDs.count) アカウント")
                }
                HomePostStatusPills(post: post, plans: plans)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if post.coverImageURL != nil {
                thumbnail
            }
        }
        .padding(.vertical, 4)
        .opacity(post.isRead ? 0.85 : 1)
        .contentShape(Rectangle())
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(post.isRead ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .accessibilityLabel(post.isRead ? "既読" : "未読")
                .accessibilityIdentifier(post.isRead ? "postCard.read" : "postCard.unread")
            AvatarView(url: post.creatorIconURL, size: 22)
            Text(post.creatorName)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(HomeDateText.format(post.publishedAt))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        Group {
            if hidesThumbnail {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .overlay(Text("R-18").font(.caption2.bold()).foregroundStyle(.secondary))
            } else {
                RemoteImageView(thumbnailURL: post.coverImageURL, maxVariant: .thumbnail, postID: post.postID, creatorID: post.creatorID,
                                accountID: post.accessAccountIDs.first ?? post.seenByAccountIDs.first, contentMode: .fill)
            }
        }
        .frame(width: 76, height: 76)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }
}
