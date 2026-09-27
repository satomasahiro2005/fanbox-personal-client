import SwiftUI
import UIKit

/// Checklist for finishing a text-first send in the account web editor (SPEC §18 / §20 / §40): what to add, where, in
/// which order, with the app's processed (resized / converted) media exported so the web file picker can reach them.
struct DraftWebHandoffView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let draft: Draft
    let items: [DraftWebItem]
    @Binding var checked: Set<String>
    let openWeb: () -> Void
    /// nil = delete the local draft.
    let complete: (DraftService.WebCompletion?) -> Void

    @State private var exported: [String: URL] = [:]
    @State private var copiedID: String?
    @State private var confirmDelete = false

    private var exportedFiles: [URL] { items.compactMap { exported[$0.id] } }

    var body: some View {
        List {
            Section {
                if items.isEmpty {
                    Text("Webで追加する項目はありません").foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    itemRow(item)
                }
            } header: {
                Text("Webで追加する項目（\(checked.intersection(items.map(\.id)).count)/\(items.count)）")
            }

            if !exportedFiles.isEmpty {
                Section {
                    ShareLink(items: exportedFiles) {
                        Label("画像・ファイルをまとめて書き出す（\(exportedFiles.count)件）", systemImage: "square.and.arrow.up.on.square")
                    }
                    .accessibilityIdentifier("handoffExportAll")
                }
            }

            Section {
                Button {
                    openWeb()
                } label: {
                    Label("Webエディタを開く", systemImage: "safari")
                }
                .disabled(draft.remotePostID == nil)
                .accessibilityIdentifier("handoffOpenWebButton")
            } footer: {
                if draft.remotePostID == nil {
                    Text("先に「送信」から本文をFANBOXに保存してください")
                }
            }

            if draft.remotePostID != nil {
                Section {
                    Button("Webで公開した") { complete(.published) }
                    Button("Webで下書き保存した") { complete(.savedAsDraft) }
                    Button("ローカル下書きを削除", role: .destructive) { confirmDelete = true }
                } header: {
                    Text("Webで仕上げたら")
                }
            }
        }
        .navigationTitle("Webで仕上げる")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("閉じる") { dismiss() }
            }
        }
        .confirmationDialog("ローカル下書きを削除しますか？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("削除", role: .destructive) { complete(nil) }
        } message: {
            Text("FANBOX上の投稿は削除されません。")
        }
        .task(id: items.map(\.id)) {
            exported = env.drafts.exportWebItemFiles(draftID: draft.id, items: items)
        }
        .accessibilityIdentifier("draftWebHandoff")
    }

    private func itemRow(_ item: DraftWebItem) -> some View {
        let isDone = checked.contains(item.id)
        return HStack(alignment: .top, spacing: 10) {
            Button {
                if isDone { checked.remove(item.id) } else { checked.insert(item.id) }
            } label: {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isDone ? Color.green : Color.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isDone ? "追加済み" : "未追加")

            if item.kind == .image, let block = draft.blocks.first(where: { $0.id == item.id }) {
                DraftBlockImage(block: block)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("\(item.position). \(item.kindLabel)").font(.caption).foregroundStyle(.secondary)
                Text(item.title).font(.subheadline).lineLimit(2)
                Text(item.afterLabel.map { "\($0)の後に追加" } ?? "本文の先頭に追加")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    if let url = exported[item.id] {
                        ShareLink(item: url) {
                            Label("書き出す", systemImage: "square.and.arrow.up")
                        }
                    }
                    if let value = item.value, !value.isEmpty {
                        Button {
                            UIPasteboard.general.string = value
                            copiedID = item.id
                        } label: {
                            Label(copiedID == item.id ? "コピーしました" : "URLをコピー", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .font(.caption)
            }
            Spacer(minLength: 0)
        }
        .opacity(isDone ? 0.6 : 1)
        .accessibilityIdentifier("handoffItemRow")
    }
}
