import SwiftUI

/// Staged, policy-aware image view (Thumbnail → Display → Original) backed by `MediaService`.
struct RemoteImageView: View {
    var thumbnailURL: String?
    var displayURL: String?
    var originalURL: String?
    /// Highest variant to load automatically.
    var maxVariant: MediaVariant = .display
    var postID: String?
    var creatorID: String?
    var accountID: String?
    var contentMode: ContentMode = .fill
    var priority: RequestPriority = .foregroundMedia

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
    }
}

/// Circular avatar.
struct AvatarView: View {
    var url: String?
    var size: CGFloat = 32

    var body: some View {
        RemoteImageView(thumbnailURL: url, maxVariant: .thumbnail)
            .frame(width: size, height: size)
            .clipShape(Circle())
    }
}
