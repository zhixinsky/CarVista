// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct TestWallpaperGalleryView: View {
    private struct Wallpaper: Decodable, Identifiable {
        let id: String
        let title: String
        let file: String
        let width: Int
        let height: Int
    }

    let use: (GalleryPick) -> Void
    @EnvironmentObject private var model: WorkshopModel
    @State private var wallpapers: [Wallpaper] = []
    @State private var remote: [CatalogItem] = []
    @State private var loadingID: String?
    @State private var problem: String?

    private func resource(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "BuiltinWallpapers/TestGallery")
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
                ForEach(remote) { item in
                    Button { selectRemote(item) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            CatalogThumb(item: item).clipShape(RoundedRectangle(cornerRadius: 12))
                            Text(item.title).font(.subheadline)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain).disabled(loadingID != nil || model.busy)
                }
                ForEach(wallpapers) { wallpaper in
                    Button { select(wallpaper) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            if let url = resource("\(wallpaper.id)-preview.jpg"),
                               let image = UIImage(contentsOfFile: url.path) {
                                Image(uiImage: image).resizable().scaledToFit()
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            Text(wallpaper.title).font(.subheadline)
                            Text(loadingID == wallpaper.id ? "正在导入…" : "\(wallpaper.width) × \(wallpaper.height)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(loadingID != nil || model.busy)
                }
            }
            .padding(16).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }
        .task {
            do {
                guard let url = resource("catalog.json") else { throw CocoaError(.fileNoSuchFile) }
                wallpapers = try JSONDecoder().decode([Wallpaper].self, from: Data(contentsOf: url))
            } catch { problem = "无法读取测试图库。" }
            if ServiceGate.enabled { remote = (try? await GalleryCategory.assets("test")) ?? [] }
        }
        .refreshable {
            if ServiceGate.enabled { remote = (try? await GalleryCategory.assets("test")) ?? remote }
        }
    }

    private func selectRemote(_ item: CatalogItem) {
        guard loadingID == nil, !model.busy else { return }
        loadingID = item.id
        Task {
            defer { loadingID = nil }
            do { use(GalleryPick(data: try await CatalogLibrary.originalData(item), source: "test", assetID: item.id)) }
            catch { problem = "无法导入这张测试壁纸。" }
        }
    }

    private func select(_ wallpaper: Wallpaper) {
        guard loadingID == nil, !model.busy else { return }
        loadingID = wallpaper.id
        problem = nil
        Task {
            defer { loadingID = nil }
            do {
                guard let url = resource(wallpaper.file) else { throw CocoaError(.fileNoSuchFile) }
                let data = try await Task.detached { try Data(contentsOf: url) }.value
                use(GalleryPick(data: data, source: "test"))
            } catch { problem = "无法导入这张测试壁纸。" }
        }
    }
}
