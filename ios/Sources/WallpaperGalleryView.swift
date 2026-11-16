// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

private struct BingWallpaper: Decodable, Identifiable {
    let url: String
    let urlbase: String?
    let title: String?
    let copyright: String?
    var id: String { urlbase ?? url }
    var name: String { title.flatMap { $0.isEmpty ? nil : $0 } ?? "Bing 每日壁纸" }

    func imageURL(size: String? = nil) -> URL? {
        let path = size.flatMap { size in urlbase.map { "\($0)_\(size).jpg" } } ?? url
        guard let resolved = URL(string: path, relativeTo: BingGallery.baseURL)?.absoluteURL,
              resolved.scheme == "https", resolved.host == "www.bing.com" else { return nil }
        return resolved
    }
}

private enum BingGallery {
    static let baseURL = URL(string: "https://www.bing.com")!
    private struct Feed: Decodable { let images: [BingWallpaper] }
    private struct ArchiveEntry: Decodable {
        let date: String
        let title: String?
        let copyright: String?
        let bing_url: String

        var wallpaper: BingWallpaper? {
            guard let source = URLComponents(string: bing_url),
                  ["www.bing.com", "bing.com", "cn.bing.com"].contains(source.host ?? ""),
                  let imageID = source.queryItems?.first(where: { $0.name == "id" })?.value,
                  imageID.hasSuffix("_UHD.jpg") else { return nil }
            let base = "/th?id=\(imageID.dropLast("_UHD.jpg".count))"
            return BingWallpaper(url: "\(base)_UHD.jpg", urlbase: base, title: title, copyright: copyright)
        }
    }

    static func recent() async throws -> [BingWallpaper] {
        let url = URL(string: "https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=8&mkt=zh-CN")!
        let data = try await fetch(url)
        let images = try JSONDecoder().decode(Feed.self, from: data).images
        var seen = Set<String>()
        return images.filter { $0.imageURL() != nil && seen.insert($0.id).inserted }
    }

    static func download(_ item: BingWallpaper) async throws -> Data {
        guard let original = item.imageURL() else { throw URLError(.badURL) }
        if let large = item.imageURL(size: "UHD"), large != original {
            do { return try await fetch(large, image: true) }
            catch { try Task.checkCancellation() }
        }
        return try await fetch(original, image: true)
    }

    static func archive() async throws -> [BingWallpaper] {
        let url = URL(string: "https://bing.npanuhin.me/CN-zh.json")!
        let entries = try JSONDecoder().decode([ArchiveEntry].self, from: await fetch(url))
        return entries.sorted { $0.date > $1.date }.compactMap(\.wallpaper)
    }

    private static func fetch(_ url: URL, image: Bool = false) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty,
              !image || response.mimeType?.hasPrefix("image/") == true else { throw URLError(.badServerResponse) }
        return data
    }
}

struct WallpaperGalleryView: View {
    private enum Source: String, CaseIterable { case bing = "Bing 每日精选", commons = "Commons 主题找图" }
    let use: (Data) -> Void
    @State private var source: Source = .bing

    var body: some View {
        Group {
            switch source {
            case .bing: BingWallpaperGalleryView(use: use)
            case .commons: CommonsWallpaperGalleryView(use: use)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("图库来源", selection: $source) {
                ForEach(Source.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(12)
            .background(.background)
        }
        .navigationTitle("图库")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}

private struct BingWallpaperGalleryView: View {
    @EnvironmentObject private var model: WorkshopModel
    let use: (Data) -> Void
    @State private var images: [BingWallpaper] = []
    @State private var selection: BingWallpaper?
    @State private var loading = false
    @State private var problem: String?
    @State private var archive: [BingWallpaper]?
    @State private var archiveIndex = 0
    @State private var loadingMore = false
    @State private var archiveFailed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Bing 每日壁纸", systemImage: "photo.stack").font(.headline)
                if loading && images.isEmpty { ProgressView("正在加载…") }
                if let problem {
                    Text(problem).foregroundStyle(.secondary)
                    Button("重试") { Task { await reload() } }.disabled(loading)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 12)], spacing: 16) {
                    ForEach(images) { item in
                        Button { selection = item } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                GalleryImage(url: item.imageURL(size: "640x360"), mode: .fill)
                                    .aspectRatio(16 / 9, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                Text(item.name).font(.subheadline).lineLimit(2)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                }
                if !images.isEmpty || archiveFailed {
                    if loadingMore {
                        ProgressView("正在加载历史壁纸…")
                    } else if archive == nil || archiveIndex < (archive?.count ?? 0) {
                        Button(archiveFailed ? "重试加载历史壁纸" : "加载更多") { Task { await loadMore() } }
                            .buttonStyle(.bordered).disabled(loading)
                    }
                    if archiveFailed { Text("历史壁纸暂时无法加载。").font(.caption).foregroundStyle(.secondary) }
                    if archive != nil { Text("历史目录来自 Bing Wallpaper Archive").font(.caption).foregroundStyle(.secondary) }
                }
            }.frame(maxWidth: 720).padding(16).frame(maxWidth: .infinity)
        }
        .refreshable { await reload() }
        .task { if images.isEmpty { await reload() } }
        .sheet(item: $selection) { item in
            BingWallpaperDetail(item: item, busy: model.busy) { data in
                selection = nil
                use(data)
            }
        }
    }

    private func reload() async {
        guard !loading, !loadingMore else { return }
        loading = true
        problem = nil
        defer { loading = false }
        do {
            images = try await BingGallery.recent()
            if images.isEmpty { problem = "Bing 暂时没有返回壁纸。" }
        } catch {
            if !Task.isCancelled { problem = "Bing 图库加载失败，请检查网络后重试。" }
        }
        guard !Task.isCancelled else { return }
        archive = nil
        archiveIndex = 0
        await loadMore()
    }

    private func loadMore() async {
        guard !loadingMore else { return }
        loadingMore = true
        archiveFailed = false
        defer { loadingMore = false }
        do {
            let available: [BingWallpaper]
            if let archive { available = archive }
            else { available = try await BingGallery.archive(); archive = available }
            var seen = Set(images.map(\.id))
            var page: [BingWallpaper] = []
            while archiveIndex < available.count && page.count < 16 {
                let item = available[archiveIndex]
                archiveIndex += 1
                if seen.insert(item.id).inserted { page.append(item) }
            }
            images.append(contentsOf: page)
            if !images.isEmpty { problem = nil }
        } catch {
            if !Task.isCancelled { archiveFailed = true }
        }
    }
}

private struct BingWallpaperDetail: View {
    @Environment(\.dismiss) private var dismiss
    let item: BingWallpaper
    let busy: Bool
    let use: (Data) -> Void
    @State private var downloading = false
    @State private var failed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    GalleryImage(url: item.imageURL(), mode: .fit).aspectRatio(16 / 9, contentMode: .fit)
                    Text(item.name).font(.headline)
                    if let credit = item.copyright { Text(credit).font(.caption).foregroundStyle(.secondary) }
                    Button(downloading ? "正在下载…" : "用作壁纸") { download() }
                        .buttonStyle(.borderedProminent).disabled(downloading || busy)
                    if failed { Text("下载失败，请重试。").foregroundStyle(.red) }
                }.padding(16)
            }
            .navigationTitle("Bing 壁纸")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("关闭") { dismiss() }.disabled(downloading) }
            .interactiveDismissDisabled(downloading)
        }
    }

    private func download() {
        downloading = true
        failed = false
        Task {
            defer { downloading = false }
            do { use(try await BingGallery.download(item)) }
            catch { failed = true }
        }
    }
}

struct GalleryImage: View {
    let url: URL?
    let mode: ContentMode

    var body: some View {
        Rectangle().fill(.quaternary).overlay {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().aspectRatio(contentMode: mode)
                case .failure: Image(systemName: "photo").foregroundStyle(.secondary)
                default: ProgressView()
                }
            }
        }.clipped().accessibilityHidden(true)
    }
}
