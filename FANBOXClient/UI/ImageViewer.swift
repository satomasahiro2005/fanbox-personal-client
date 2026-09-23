import SwiftUI

struct ImageViewerItem: Identifiable, Hashable {
    let id: String
    var thumbnailURL: String?
    var displayURL: String?
    var originalURL: String?
    var width: Int?
    var height: Int?
}

/// Full-screen image gallery with paging + zoom. Loads Display first, Original on demand (SPEC §6).
struct ImageViewer: View {
    let items: [ImageViewerItem]
    var startIndex: Int = 0
    var postID: String? = nil
    var accountID: String? = nil

    var body: some View {
        Text("ImageViewer")
    }
}
