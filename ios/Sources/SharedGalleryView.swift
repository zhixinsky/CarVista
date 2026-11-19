// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct SharedWallpaper: Identifiable, Equatable {
    let id: String
    let title: String
    let intro: String
    let author: String?
    let width: Int
    let height: Int
    let likes: Int
    let liked: Bool
    let previewURL: URL
    let originalURL: URL

    init(_ item: ShareItem) {
        id = item.id
        title = item.title
        intro = item.intro
        author = item.author
        width = item.width
        height = item.height
        likes = item.likes
        liked = item.liked
        previewURL = ServiceClient.publicURL(item.previewURL)
        originalURL = ServiceClient.publicURL(item.originalURL)
    }
}

struct ShareFeed: Decodable { let items: [ShareItem] }

struct ShareItem: Decodable {
    let id: String
    let title: String
    let intro: String
    let author: String?
    let width: Int
    let height: Int
    let likes: Int
    let liked: Bool
    let previewURL: URL
    let originalURL: URL

    enum CodingKeys: String, CodingKey {
        case id, title, width, height, likes, liked
        case intro = "description"
        case author
        case previewURL = "preview_url"
        case originalURL = "original_url"
    }
}

struct SharedWallpaperGalleryView: View {
    @EnvironmentObject private var model: WorkshopModel
    let use: (GalleryPick) -> Void
    @State private var items: [SharedWallpaper] = []
    @State private var note = ""
    @State private var busyID: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Button { select(item) } label: {
                            AsyncImage(url: item.previewURL) { phase in
                                switch phase {
                                case .success(let image):
                                    image.resizable().scaledToFit()
                                case .failure:
                                    Label("预览加载失败", systemImage: "photo")
                                        .frame(maxWidth: .infinity, minHeight: 92)
                                default:
                                    ProgressView()
                                        .frame(maxWidth: .infinity, minHeight: 92)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain).disabled(busyID != nil || model.busy)
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.subheadline)
                                if let author = item.author, !author.isEmpty {
                                    Text("作者：\(author)").font(.caption).foregroundStyle(.secondary)
                                }
                                if !item.intro.isEmpty {
                                    Text(item.intro).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                }
                                Text("\(item.width) × \(item.height)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { like(item) } label: {
                                Label("\(item.likes)", systemImage: item.liked ? "heart.fill" : "heart")
                            }.buttonStyle(.bordered).disabled(busyID != nil)
                            Button(busyID == item.id ? "正在导入…" : "选择") { select(item) }
                                .buttonStyle(.borderedProminent)
                                .disabled(busyID != nil || model.busy)
                        }
                    }
                }
            }.padding(16).frame(maxWidth: 720).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        guard ServiceGate.enabled else {
            note = "当前无法连接后台。"
            items = []
            return
        }
        guard let remote = await ServiceClient.shared.fetchShares() else {
            note = items.isEmpty ? "无法加载精选壁纸。" : ""
            return
        }
        items = remote
        note = remote.isEmpty ? "还没有人精选壁纸。" : "按点赞数排列，点图片可选为当前壁纸。"
    }

    private func like(_ item: SharedWallpaper) {
        Task {
            guard let result = await ServiceClient.shared.toggleLike(item.id),
                  let index = items.firstIndex(where: { $0.id == item.id }) else { return }
            let current = items[index]
            items[index] = SharedWallpaper(ShareItem(
                id: current.id, title: current.title, intro: current.intro, author: current.author, width: current.width, height: current.height,
                likes: result.likes, liked: result.liked, previewURL: current.previewURL, originalURL: current.originalURL
            ))
        }
    }

    private func select(_ item: SharedWallpaper) {
        guard busyID == nil, !model.busy else { return }
        busyID = item.id
        Task {
            defer { busyID = nil }
            do {
                let (data, response) = try await URLSession.shared.data(from: item.originalURL)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
                    note = "无法下载这张壁纸。"
                    return
                }
                use(GalleryPick(data: data, source: "share", assetID: item.id))
            } catch {
                note = "无法下载这张壁纸。"
            }
        }
    }
}
