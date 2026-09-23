import Foundation
import SwiftData

/// All SwiftData models of v1.0 (SPEC §41).
enum AppSchema {
    static let models: [any PersistentModel.Type] = [
        Account.self,
        Creator.self,
        Plan.self,
        Post.self,
        PostBlock.self,
        PostAccess.self,
        Support.self,
        SupportHistory.self,
        PaymentRecord.self,
        PaymentProfile.self,
        SupportPaymentAssignment.self,
        Draft.self,
        DraftBlock.self,
        UploadJob.self,
        Comment.self,
        OutgoingComment.self,
        Newsletter.self,
        Fan.self,
        CreatorDashboardSnapshot.self,
        NotificationEvent.self,
        Media.self,
        MediaCacheEntry.self,
        Tag.self,
        PostTag.self,
        SyncState.self,
        ResearchLog.self,
        APISchemaSnapshot.self,
    ]

    static var schema: Schema { Schema(models) }
}

enum PersistenceController {
    /// Directory holding the SwiftData store. Protected with iOS Data Protection (SPEC §39).
    static var storeDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Store", isDirectory: true)
    }

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        if inMemory {
            let config = ModelConfiguration("FANBOXClient", schema: AppSchema.schema, isStoredInMemoryOnly: true)
            return try ModelContainer(for: AppSchema.schema, configurations: [config])
        }
        let dir = storeDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let url = dir.appendingPathComponent("FANBOXClient.store")
        let config = ModelConfiguration("FANBOXClient", schema: AppSchema.schema, url: url)
        let container = try ModelContainer(for: AppSchema.schema, configurations: [config])
        applyProtection(to: dir)
        return container
    }

    /// Re-applies Data Protection to the store files (sqlite, -wal, -shm).
    static func applyProtection(to directory: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files {
            try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
        }
    }
}
