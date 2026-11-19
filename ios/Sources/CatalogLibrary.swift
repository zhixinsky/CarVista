// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import UIKit

enum CatalogCollection: String {
    case builtin
    case buick
}

struct RemoteAsset: Codable, Equatable {
    let id: String
    let title: String
    let width: Int
    let height: Int
    let previewURL: URL
    let originalURL: URL
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, title, width, height
        case previewURL = "preview_url"
        case originalURL = "original_url"
        case updatedAt = "updated_at"
    }
}

struct CatalogItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case bundledBuiltin(Int)
        case bundledBuick(Int)
        case remote
    }
    let id: String
    let title: String
    let kind: Kind
    let remote: RemoteAsset?
}

enum CatalogPolicy {
    /// A published remote list replaces the bundled wallpapers. An empty or failed
    /// response keeps the last cache, then the images shipped in the app.
    static func choose(offline: Bool, remote: [CatalogItem], cached: [CatalogItem], bundled: [CatalogItem]) -> [CatalogItem] {
        if offline || remote.isEmpty {
            return cached.isEmpty || offline ? bundled : cached
        }
        return remote
    }
}

enum ServiceGate {
    static var enabled: Bool {
        if ProcessInfo.processInfo.arguments.contains("-CarVistaOfflineCatalog") { return false }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return false }
        return true
    }

    static var baseURL: URL {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-CarVistaAPIBase"), index + 1 < args.count, let url = URL(string: args[index + 1]) {
            return url
        }
        return URL(string: "https://carplay.dokor.cn")!
    }

    static func join(_ path: String) -> URL {
        path.split(separator: "/").reduce(baseURL) { url, part in
            url.appending(path: String(part))
        }
    }
}

enum CatalogLibrary {
    private struct Feed: Decodable { let items: [RemoteAsset] }

    static func bundled(_ collection: CatalogCollection) -> [CatalogItem] {
        switch collection {
        case .builtin:
            return BuiltinWallpaper.all.map { item in
                CatalogItem(id: item.id, title: item.title, kind: .bundledBuiltin(item.index), remote: nil)
            }
        case .buick:
            return (1...16).map { index in
                CatalogItem(id: String(format: "buick-%02d", index), title: "别克壁纸 \(index)", kind: .bundledBuick(index), remote: nil)
            }
        }
    }

    static func initial(_ collection: CatalogCollection) -> [CatalogItem] {
        CatalogPolicy.choose(offline: !ServiceGate.enabled, remote: [], cached: cached(collection), bundled: bundled(collection))
    }

    static func refresh(_ collection: CatalogCollection) async -> [CatalogItem] {
        let bundled = bundled(collection)
        guard ServiceGate.enabled else { return bundled }
        let cached = cached(collection)
        let remote = await fetch(collection) ?? []
        let chosen = CatalogPolicy.choose(offline: false, remote: remote, cached: cached, bundled: bundled)
        if !remote.isEmpty { store(remote, collection) }
        return chosen
    }

    static func thumbnail(_ item: CatalogItem) async -> UIImage? {
        switch item.kind {
        case .bundledBuiltin(let index):
            return UIImage(named: BuiltinWallpaper(index: index).previewName)
        case .bundledBuick(let index):
            let stem = String(format: "%02d-preview", index)
            guard let url = Bundle.main.url(forResource: stem, withExtension: "jpg", subdirectory: "BuiltinWallpapers/BuickGallery") else { return nil }
            return UIImage(contentsOfFile: url.path)
        case .remote:
            guard let asset = item.remote else { return nil }
            guard let file = try? await cachedFile(asset.previewURL, name: fileName("preview", asset, "jpg")) else { return nil }
            return UIImage(contentsOfFile: file.path)
        }
    }

    static func originalData(_ item: CatalogItem) async throws -> Data {
        switch item.kind {
        case .bundledBuiltin(let index):
            return try Data(contentsOf: BuiltinWallpaper(index: index).originalURL())
        case .bundledBuick(let index):
            let stem = String(format: "%02d", index)
            guard let url = Bundle.main.url(forResource: stem, withExtension: "jpeg", subdirectory: "BuiltinWallpapers/BuickGallery") else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            return try Data(contentsOf: url)
        case .remote:
            guard let asset = item.remote else { throw CocoaError(.fileReadNoSuchFile) }
            let ext = asset.originalURL.pathExtension.isEmpty ? "jpg" : asset.originalURL.pathExtension
            let file = try await cachedFile(asset.originalURL, name: fileName("original", asset, ext))
            return try Data(contentsOf: file)
        }
    }

    private static func fetch(_ collection: CatalogCollection) async -> [CatalogItem]? {
        let path = collection == .builtin ? "builtin" : "buick"
        let url = ServiceGate.join("v1/catalog/\(path)")
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return try JSONDecoder().decode(Feed.self, from: data).items.map {
                CatalogItem(id: $0.id, title: $0.title, kind: .remote, remote: $0)
            }
        } catch {
            return nil
        }
    }

    private static func cached(_ collection: CatalogCollection) -> [CatalogItem] {
        guard let url = try? directory().appendingPathComponent("catalog-\(collection.rawValue).json"),
              let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([RemoteAsset].self, from: data) else { return [] }
        return items.map { CatalogItem(id: $0.id, title: $0.title, kind: .remote, remote: $0) }
    }

    private static func store(_ items: [CatalogItem], _ collection: CatalogCollection) {
        let assets = items.compactMap(\.remote)
        guard let url = try? directory().appendingPathComponent("catalog-\(collection.rawValue).json"),
              let data = try? JSONEncoder().encode(assets) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func cachedFile(_ remote: URL, name: String) async throws -> URL {
        let destination = try directory().appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        let request = URLRequest(url: remote, timeoutInterval: 30)
        let (temporary, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    private static func fileName(_ prefix: String, _ asset: RemoteAsset, _ ext: String) -> String {
        let stamp = asset.updatedAt.replacingOccurrences(of: ":", with: "-")
        return "\(prefix)-\(asset.id)-\(stamp).\(ext)"
    }

    private static func directory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("CarVistaService", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

struct CatalogThumb: View {
    let item: CatalogItem
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Color(uiColor: .tertiarySystemFill) }
        }
        .task(id: "\(item.id)-\(item.remote?.updatedAt ?? "")") { image = await CatalogLibrary.thumbnail(item) }
    }
}

@MainActor
final class CatalogStore: ObservableObject {
    let collection: CatalogCollection
    @Published private(set) var items: [CatalogItem]

    init(collection: CatalogCollection) {
        self.collection = collection
        items = CatalogLibrary.initial(collection)
    }

    func refresh() async {
        items = await CatalogLibrary.refresh(collection)
    }
}
