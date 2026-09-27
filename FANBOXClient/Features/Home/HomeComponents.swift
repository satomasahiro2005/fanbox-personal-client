import SwiftUI

/// Simple wrapping layout for pills / tags (left-aligned, wraps to the next line).
struct HomeFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            let w = min(size.width, maxWidth)
            if x > 0 && x + w > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += w + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            let w = min(size.width, bounds.width)
            if x > bounds.minX && x + w > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: w, height: size.height))
            x += w + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// Feed / detail date text: relative for the last week, absolute otherwise.
enum HomeDateText {
    static func format(_ date: Date, now: Date = .now) -> String {
        let age = now.timeIntervalSince(date)
        // Small clock skew between FANBOX and the device must not read as "0 秒後".
        if abs(age) < 60 { return "たった今" }
        if age >= 0 && age < 7 * 24 * 3600 { return Formatters.relative(date, now: now) }
        return Formatters.shortDate(date)
    }
}

/// Filter chip button.
struct HomeFilterChip: View {
    let title: String
    var systemImage: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage).imageScale(.small) }
                Text(title)
            }
            .font(.subheadline.weight(isSelected ? .semibold : .regular))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Post status pills shared by the feed card and the detail header:
/// 対象 Plan / 閲覧不可 / Offline / 本文キャッシュ済 / favorite / read later.
struct HomePostStatusPills: View {
    let post: Post
    var plans: [Plan] = []
    /// 閲覧不可 when none of these can view the post.
    let enabledAccountIDs: Set<String>
    var showsUserFlags: Bool = true

    var body: some View {
        HomeFlowLayout(spacing: 4, lineSpacing: 4) {
            PillLabel(text: HomePlanLabel.text(feeRequired: post.feeRequired, plans: plans),
                      systemImage: post.feeRequired > 0 ? "yensign.circle" : "globe",
                      tint: post.feeRequired > 0 ? .purple : .teal)
            if PostAccountLogic.isRestricted(feeRequired: post.feeRequired, accessAccountIDs: post.accessAccountIDs,
                                             enabledAccountIDs: enabledAccountIDs, hasBlocks: false) {
                PillLabel(text: "閲覧不可", systemImage: "lock.fill", tint: .red)
                    .accessibilityIdentifier("postPill.restricted")
            }
            if post.offlineState != .none {
                PillLabel(text: "Offline", systemImage: "arrow.down.circle.fill", tint: .green)
                    .accessibilityIdentifier("postPill.offline")
            }
            if post.hasCachedBody {
                PillLabel(text: "本文キャッシュ済", systemImage: "doc.text", tint: .blue)
                    .accessibilityIdentifier("postPill.cached")
            }
            if showsUserFlags && post.isFavorite {
                PillLabel(text: "お気に入り", systemImage: "star.fill", tint: .yellow)
            }
            if showsUserFlags && post.isReadLater {
                PillLabel(text: "あとで読む", systemImage: "bookmark.fill", tint: .orange)
            }
        }
    }
}

/// User-metadata mutations shared by the feed swipe actions and the detail menu (never sent to FANBOX, SPEC §33).
@MainActor
enum HomePostUserActions {
    static func setRead(_ post: Post, _ read: Bool, store: LocalStore) {
        post.isRead = read
        post.readAt = read ? (post.readAt ?? .now) : nil
        store.save()
    }

    static func toggleFavorite(_ post: Post, store: LocalStore) {
        post.isFavorite.toggle()
        store.save()
    }

    static func toggleReadLater(_ post: Post, store: LocalStore) {
        post.isReadLater.toggle()
        store.save()
    }
}
