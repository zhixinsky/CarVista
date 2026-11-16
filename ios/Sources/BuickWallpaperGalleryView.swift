// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct BuickWallpaperGalleryView: View {
    private struct Wallpaper: Identifiable {
        let id: Int
        var name: String { "别克壁纸 \(id)" }
        private var stem: String { String(format: "%02d", id) }
        var originalURL: URL? { resource(stem, withExtension: "jpeg") }
        var thumbnail: UIImage? {
            resource("\(stem)-preview", withExtension: "jpg").flatMap { UIImage(contentsOfFile: $0.path) }
        }

        private func resource(_ name: String, withExtension ext: String) -> URL? {
            Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "BuiltinWallpapers/BuickGallery")
        }
    }

    @EnvironmentObject private var model: WorkshopModel
    let use: (Data) -> Void
    @State private var selection: Wallpaper?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label("别克大连屏用户请自行裁剪尺寸", systemImage: "crop")
                    .font(.subheadline).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 12)], spacing: 16) {
                    ForEach((1...15).map { Wallpaper(id: $0) }) { wallpaper in
                        Button { error = nil; selection = wallpaper } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                thumbnail(wallpaper).frame(height: 64)
                                Text(wallpaper.name).font(.subheadline)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(maxWidth: 720).padding(16).frame(maxWidth: .infinity)
        }
        .sheet(item: $selection) { wallpaper in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        thumbnail(wallpaper)
                        Text("别克大连屏用户请自行裁剪尺寸").font(.subheadline)
                        Text("导入整张原图后，回到壁纸页点「裁剪」。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button(loading ? "正在导入…" : "使用原图") { importOriginal(wallpaper) }
                            .buttonStyle(.borderedProminent).disabled(loading || model.busy)
                        if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                    }.padding(16)
                }
                .navigationTitle(wallpaper.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("关闭") { selection = nil }.disabled(loading) }
                .interactiveDismissDisabled(loading)
            }
        }
    }

    private func thumbnail(_ wallpaper: Wallpaper) -> some View {
        Group {
            if let image = wallpaper.thumbnail { Image(uiImage: image).resizable().scaledToFit() }
            else { Label("预览不可用", systemImage: "photo").font(.caption) }
        }.frame(maxWidth: .infinity)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true)
    }

    private func importOriginal(_ wallpaper: Wallpaper) {
        guard !loading, !model.busy else { return }
        guard let url = wallpaper.originalURL else { error = "无法找到原图。"; return }
        loading = true
        error = nil
        Task {
            defer { loading = false }
            do {
                let data = try await Task.detached { try Data(contentsOf: url) }.value
                selection = nil
                use(data)
            } catch {
                self.error = "无法读取原图，请重试。"
            }
        }
    }
}
