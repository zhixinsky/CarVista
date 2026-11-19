// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct GalleryCategory: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let kind: String
    let hidden: Int
    var rawValue: String { title }
    var key: String { id == "buick_gallery" ? "buick" : id }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static let stock = Self(id: "stock", title: "默认壁纸", kind: "stock", hidden: 0)
    static let share = Self(id: "share", title: "精选壁纸", kind: "share", hidden: 0)
    static let bing = Self(id: "bing", title: "必应壁纸", kind: "bing", hidden: 0)
    static let commons = Self(id: "commons", title: "主题搜图", kind: "commons", hidden: 0)
    static let buick = Self(id: "buick_gallery", title: "别克车机壁纸", kind: "buick", hidden: 0)
    static let test = Self(id: "test", title: "测试", kind: "test", hidden: 1)
    static let allCases: [Self] = [.stock, .share, .bing, .commons, .buick, .test]

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
              let items = try? JSONDecoder().decode([Self].self, from: data), !items.isEmpty else { return allCases }
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
            guard !items.isEmpty, Set(items.map(\.id)).count == items.count,
                  items.contains(where: { $0.id == "stock" }) else { return nil }
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
            LazyVStack(alignment: .leading, spacing: 16) {
                if let problem { Text(problem).font(.footnote).foregroundStyle(.secondary) }
                if loading && items.isEmpty { ProgressView("正在加载…") }
                if !loading && items.isEmpty && problem == nil {
                    ContentUnavailableView("暂无壁纸", systemImage: "photo")
                }
                ForEach(items) { item in
                    Button { select(item) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            CatalogThumb(item: item).clipShape(RoundedRectangle(cornerRadius: 12))
                            Text(item.title).font(.subheadline)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain).disabled(importing || model.busy)
                }
            }.padding(16).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }
        .task(id: category.id) { await reload() }
        .refreshable { await reload() }
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
            do { use(GalleryPick(data: try await CatalogLibrary.originalData(item), source: "catalog", assetID: item.id)) }
            catch { problem = "无法导入壁纸，请重试。" }
        }
    }
}
