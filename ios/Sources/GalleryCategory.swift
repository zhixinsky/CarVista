// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct GalleryCategory: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let kind: String
    let hidden: Int
    let published: Int
    var rawValue: String { title }
    var key: String { id == "buick_gallery" ? "buick" : id }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static let stock = Self(id: "stock", title: "默认壁纸", kind: "stock", hidden: 0)
    static let share = Self(id: "share", title: "精选壁纸", kind: "share", hidden: 0)
    static let bing = Self(id: "bing", title: "必应壁纸", kind: "bing", hidden: 0)
    static let commons = Self(id: "commons", title: "主题搜图", kind: "commons", hidden: 0)
    static let buick = Self(id: "buick_gallery", title: "别克车机壁纸", kind: "buick", hidden: 0)
    static let test = Self(id: "test", title: "测试", kind: "test", hidden: 1, published: 1)
    static let allCases: [Self] = [.stock, .share, .bing, .commons, .buick, .test]

    init(id: String, title: String, kind: String, hidden: Int, published: Int = 1) {
        self.id = id
        self.title = title
        self.kind = kind
        self.hidden = hidden
        self.published = published
    }

    private enum CodingKeys: String, CodingKey { case id, title, kind, hidden, published }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        kind = try container.decode(String.self, forKey: .kind)
        hidden = try container.decodeIfPresent(Int.self, forKey: .hidden) ?? 0
        published = try container.decodeIfPresent(Int.self, forKey: .published) ?? 1
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(kind, forKey: .kind)
        try container.encode(hidden, forKey: .hidden)
        try container.encode(published, forKey: .published)
    }

    private struct Feed: Decodable { let items: [GalleryCategory] }
    private struct AssetFeed: Decodable { let items: [RemoteAsset] }
    static func assets(_ id: String) async throws -> [CatalogItem] {
        var request = URLRequest(url: ServiceGate.join("v1/catalog/\(id)"), timeoutInterval: 12)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(AssetFeed.self, from: data).items.map {
            CatalogItem(id: $0.id, title: $0.title, kind: .remote, remote: $0)
        }
    }
    static var cached: [Self] {
        guard let data = UserDefaults.standard.data(forKey: "CarVistaGalleryCategories"),
              let items = try? JSONDecoder().decode([Self].self, from: data) else { return allCases }
        return items
    }

    static func fetch() async -> [Self]? {
        guard ServiceGate.enabled else { return nil }
        var request = URLRequest(url: ServiceGate.join("v1/gallery/categories"), timeoutInterval: 12)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let items = try JSONDecoder().decode(Feed.self, from: data).items
            guard Set(items.map(\.id)).count == items.count else { return nil }
            UserDefaults.standard.set(try JSONEncoder().encode(items), forKey: "CarVistaGalleryCategories")
            return items
        } catch { return nil }
    }
}

struct ServerWallpaperGalleryView: View {
    let category: GalleryCategory
    let use: (GalleryPick) -> Void
    @EnvironmentObject private var model: WorkshopModel
    @State private var items: [CatalogItem] = []
    @State private var loading = false
    @State private var importing = false
    @State private var problem: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let problem { Text(problem).font(.footnote).foregroundStyle(.secondary) }
                if loading && items.isEmpty { ProgressView("正在加载…") }
                if !loading && items.isEmpty && problem == nil {
                    ContentUnavailableView("暂无壁纸", systemImage: "photo")
                }
                if category.kind == "stock" {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 16) {
                        ForEach(items) { item in wallpaperButton(item) }
                    }
                } else {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(items) { item in wallpaperButton(item) }
                    }
                }
            }.padding(16).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }
        .task(id: category.id) { await reload() }
        .refreshable { await reload() }
    }

    private func thumbRatio(_ item: CatalogItem) -> CGFloat? {
        guard let remote = item.remote, remote.width > 0, remote.height > 0 else { return nil }
        return CGFloat(remote.width) / CGFloat(remote.height)
    }

    private func wallpaperButton(_ item: CatalogItem) -> some View {
        Button { select(item) } label: {
            VStack(alignment: .leading, spacing: 6) {
                CatalogThumb(item: item)
                    .aspectRatio(thumbRatio(item), contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.title).font(.subheadline).lineLimit(1)
                    Spacer(minLength: 4)
                    if let remote = item.remote, remote.width > 0, remote.height > 0 {
                        Text("\(remote.width) × \(remote.height)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain).disabled(importing || model.busy)
    }

    private func reload() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            items = try await GalleryCategory.assets(category.id)
            problem = nil
        } catch { problem = "无法加载壁纸，请下拉重试。" }
    }

    private func select(_ item: CatalogItem) {
        guard !importing, !model.busy else { return }
        importing = true
        Task {
            defer { importing = false }
            do {
                let data = try await CatalogLibrary.originalData(item)
                use(GalleryPick(data: data, source: category.id == "test" ? "test" : "catalog", assetID: item.id))
            } catch {
                problem = "无法导入壁纸，请重试。"
            }
        }
    }
}
