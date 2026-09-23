import SwiftUI

/// Title, creator, date, plan / access / cache state, FANBOX tags and local tags + memo.
struct PostDetailHeader: View {
    let post: Post
    var plans: [Plan] = []
    var localTags: [String] = []
    var editTags: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(post.title.isEmpty ? "(無題)" : post.title)
                .font(.title2.bold())
                .textSelection(.enabled)
                .accessibilityIdentifier("postTitle")

            NavigationLink(value: AppRoute.creator(creatorID: post.creatorID)) {
                HStack(spacing: 8) {
                    AvatarView(url: post.creatorIconURL, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(post.creatorName).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Text(Formatters.shortDate(post.publishedAt) + " " + Formatters.time(post.publishedAt)
                             + (post.updatedAt > post.publishedAt.addingTimeInterval(60) ? " (更新 \(Formatters.shortDate(post.updatedAt)))" : ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("postCreatorLink")

            if !post.accessAccountIDs.isEmpty {
                HStack(spacing: 6) {
                    Text("閲覧可能").font(.caption).foregroundStyle(.secondary)
                    AccountBadgeRow(accountIDs: post.accessAccountIDs)
                }
            }
            HomePostStatusPills(post: post, plans: plans)

            if !post.fanboxTags.isEmpty {
                HomeFlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(post.fanboxTags, id: \.self) { tag in
                        NavigationLink(value: AppRoute.search(query: tag)) {
                            Text("#\(tag)")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !localTags.isEmpty || !post.memo.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if !localTags.isEmpty {
                        HomeFlowLayout(spacing: 6, lineSpacing: 6) {
                            ForEach(localTags, id: \.self) { tag in
                                NavigationLink(value: AppRoute.tag(name: tag)) {
                                    PillLabel(text: "#\(tag)", systemImage: "tag", tint: .purple)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if !post.memo.isEmpty {
                        Label(post.memo, systemImage: "note.text")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onTapGesture(perform: editTags)
                .accessibilityIdentifier("postLocalMetadata")
            }
        }
    }
}

/// Paid post that none of my accounts can view (SPEC §6 / §14).
struct PostDetailRestrictedView: View {
    let excerpt: String
    let feeRequired: Int
    var planTitle: String?
    let showPlans: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !excerpt.isEmpty {
                Text(excerpt)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            VStack(spacing: 10) {
                Image(systemName: "lock.fill").font(.title2).foregroundStyle(.secondary)
                Text("支援が必要です (\(Formatters.yen(feeRequired))〜)")
                    .font(.headline)
                    .accessibilityIdentifier("postRestrictedMessage")
                if let planTitle {
                    Text(planTitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Button("プランを見る", action: showPlans)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("postViewPlansButton")
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// Like button + counters.
struct PostDetailFooter: View {
    let post: Post
    let isLiked: Bool
    let likeCount: Int
    let isLikeBusy: Bool
    let toggleLike: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Button(action: toggleLike) {
                Label("\(likeCount)", systemImage: isLiked ? "heart.fill" : "heart")
                    .foregroundStyle(isLiked ? Color.pink : Color.primary)
            }
            .buttonStyle(.bordered)
            .disabled(isLikeBusy)
            .accessibilityLabel(isLiked ? "いいね済み \(likeCount)" : "いいね \(likeCount)")
            .accessibilityIdentifier("postLikeButton")
            Label("\(post.commentCount)", systemImage: "bubble.left")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, 4)
    }
}

/// Latest comments + link to the full thread.
struct PostDetailCommentPreview: View {
    let postID: String
    let comments: [Comment]
    let totalCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("コメント").font(.headline)
                Spacer()
                NavigationLink(value: AppRoute.comments(postID: postID, focusCommentID: nil)) {
                    Text("コメント (\(totalCount))")
                }
                .accessibilityIdentifier("postCommentsLink")
            }
            if comments.isEmpty {
                NavigationLink(value: AppRoute.comments(postID: postID, focusCommentID: nil)) {
                    Label("コメントを書く", systemImage: "square.and.pencil")
                        .font(.subheadline)
                }
            } else {
                ForEach(comments) { comment in
                    NavigationLink(value: AppRoute.comments(postID: postID, focusCommentID: comment.commentID)) {
                        HStack(alignment: .top, spacing: 8) {
                            AvatarView(url: comment.authorIconURL, size: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(comment.authorName).font(.caption.weight(.semibold))
                                    Spacer()
                                    Text(HomeDateText.format(comment.createdAt)).font(.caption2).foregroundStyle(.secondary)
                                }
                                Text(comment.body)
                                    .font(.subheadline)
                                    .lineLimit(3)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("postCommentPreview")
    }
}
