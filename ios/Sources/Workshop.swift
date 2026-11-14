// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import PhotosUI
import ImageIO

@main
struct CarCanvasWorkshopApp: App {
    @StateObject private var model = WorkshopModel()
    var body: some Scene { WindowGroup { WorkshopView().environmentObject(model) } }
}

struct WallpaperTarget: Identifiable {
    let raw: [String: Any]
    var id: String { raw["path"] as? String ?? "" }
    var name: String { raw["name"] as? String ?? "" }
    var mode: String { raw["mode"] as? String ?? "未知" }
    var width: Int { raw["width"] as? Int ?? 0 }
    var height: Int { raw["height"] as? Int ?? 0 }
    var editable: Bool { width > 0 && height > 0 && width <= 8192 && height <= 8192 && width * height <= 16_000_000 }
}

struct SavedWallpaper: Identifiable, Codable {
    let id: UUID
    let created: Date
    let width: Int
    let height: Int
    let mode: String
    var bitmap: URL { WorkshopModel.library.appendingPathComponent("\(id).cpbitmap") }
    var preview: URL { WorkshopModel.library.appendingPathComponent("\(id).jpg") }
}

@MainActor
final class WorkshopModel: ObservableObject {
    @Published var targets: [WallpaperTarget] = []
    @Published var history: [SavedWallpaper] = []
    @Published var backups: [[String: Any]] = []
    @Published var busy = false
    @Published var message = "首次使用：先连接车机，在 CarPlay 设置里切换内置图片壁纸，然后返回这里扫描。"
    @Published var issues: [String] = []
    @Published var root = ""
    @Published var reportURL: URL?
    let group = CCEngine.appGroup()
    nonisolated static var library: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Wallpapers")
    }
    private let queue = DispatchQueue(label: "carcanvas.io", qos: .userInitiated)

    init() {
        do {
            try FileManager.default.createDirectory(at: Self.library, withIntermediateDirectories: true)
            let files = try FileManager.default.contentsOfDirectory(at: Self.library, includingPropertiesForKeys: nil)
            history = files.filter { $0.pathExtension == "json" }.compactMap {
                guard let data = try? Data(contentsOf: $0) else { return nil }
                return try? JSONDecoder().decode(SavedWallpaper.self, from: data)
            }.sorted { $0.created > $1.created }
        } catch { message = "无法载入本地历史：\(error.localizedDescription)" }
        backups = CCEngine.backups() as? [[String: Any]] ?? []
    }

    private func work(_ task: @escaping () -> [String: Any], finish: @escaping ([String: Any]) -> Void) {
        guard !busy else { return }
        busy = true
        queue.async {
            let result = task()
            DispatchQueue.main.async {
                self.busy = false
                finish(result)
                self.backups = CCEngine.backups() as? [[String: Any]] ?? []
            }
        }
    }

    func scan(deep: Bool) {
        message = deep ? "正在完整扫描容器，请保持应用在前台。首次可能需要数分钟。" : "正在定位壁纸缓存…"
        work({ CCEngine.discover(deep) as? [String: Any] ?? [:] }) { result in
            self.targets = (result["files"] as? [[String: Any]] ?? []).map { WallpaperTarget(raw: $0) }
            self.issues = result["issues"] as? [String] ?? []
            self.root = result["root"] as? String ?? ""
            self.message = result["message"] as? String ?? "扫描失败"
            self.makeReport()
        }
    }

    func save(image: UIImage, target: WallpaperTarget, completion: @escaping (SavedWallpaper?) -> Void) {
        let entry = SavedWallpaper(id: UUID(), created: Date(), width: target.width, height: target.height, mode: target.mode)
        work({
            let encoded = CCEngine.encode(image, to: entry.bitmap.path) as? [String: Any] ?? [:]
            guard encoded["ok"] as? Bool == true else { return encoded }
            do {
                guard let jpeg = image.jpegData(compressionQuality: 0.85) else { throw CocoaError(.fileWriteUnknown) }
                try jpeg.write(to: entry.preview, options: .atomic)
                try JSONEncoder().encode(entry).write(to: Self.library.appendingPathComponent("\(entry.id).json"), options: .atomic)
                return ["ok": true]
            } catch { return ["ok": false, "message": error.localizedDescription] }
        }) { result in
            if result["ok"] as? Bool == true {
                self.history.insert(entry, at: 0)
                self.message = "壁纸已生成并保存。确认后可替换目标缓存。"
                completion(entry)
            } else { self.message = result["message"] as? String ?? "生成失败"; completion(nil) }
        }
    }

    func apply(entry: SavedWallpaper, target: WallpaperTarget) {
        message = "正在备份、写入并校验…"
        work({ CCEngine.apply(target.raw, source: entry.bitmap.path) as? [String: Any] ?? [:] }) { result in
            self.message = result["message"] as? String ?? "写入失败"
            // Snapshots are invalid after a mutation attempt; require a rescan.
            self.targets = []
            self.makeReport()
        }
    }

    func restore(_ backup: [String: Any]) {
        guard let path = backup["path"] as? String else { return }
        message = "正在恢复并校验…"
        work({ CCEngine.restore(path) as? [String: Any] ?? [:] }) { result in
            self.message = result["message"] as? String ?? "恢复失败"
            self.targets = []
            self.makeReport()
        }
    }

    func makeReport() {
        do {
            let object: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date()),
                "system": UIDevice.current.systemVersion, "model": UIDevice.current.model,
                "appGroup": group, "root": root, "message": message, "issues": issues,
                "targets": targets.map(\.raw), "log": CCEngine.logs()]
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("CarCanvas-\(UUID().uuidString).json")
            try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
            reportURL = url
        } catch { message = "导出报告失败：\(error.localizedDescription)" }
    }
}

struct WorkshopView: View {
    @EnvironmentObject var model: WorkshopModel
    @State private var deepScan = false
    var body: some View {
        TabView {
            NavigationStack {
                List {
                    Section {
                        Label("CarCanvas Workshop", systemImage: "car.side.fill").font(.title2.bold())
                        Text("自定义你的车机壁纸").foregroundStyle(.secondary)
                        Text("实验测试版 · iOS 27.2 尚待真机验证").font(.caption)
                    }
                    Section("缓存与连接") {
                        Text(model.message).textSelection(.enabled)
                        if model.busy {
                            ProgressView()
                            Button("停止完整扫描") { CCEngine.cancelScan() }
                        }
                        Button("查找 / 刷新车机壁纸") { model.scan(deep: false) }.disabled(model.busy || model.group.isEmpty)
                        Button("首次完整扫描") { deepScan = true }.disabled(model.busy || model.group.isEmpty)
                        if model.group.isEmpty { Text("缺少 App Group 权限，请重新签名安装。详见使用说明。").foregroundStyle(.red) }
                    }
                    Section("选择要替换的壁纸") {
                        if model.targets.isEmpty { Text("扫描后显示实际缓存文件。深色与浅色需要分别选择和应用。").foregroundStyle(.secondary) }
                        ForEach(model.targets) { target in
                            NavigationLink {
                                EditorView(target: target)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(target.name).font(.headline)
                                    Text("\(target.mode) · \(target.width) × \(target.height)").font(.caption)
                                    if !target.editable { Text("格式或尺寸无法确认，禁止替换").foregroundStyle(.red).font(.caption) }
                                }
                            }.disabled(!target.editable || model.busy)
                        }
                    }
                    if !model.issues.isEmpty {
                        Section("扫描详情") { ForEach(Array(model.issues.prefix(30).enumerated()), id: \.offset) { _, item in Text(item).font(.caption) } }
                    }
                }
                .navigationTitle("壁纸")
                .confirmationDialog("完整扫描可能需要数分钟，请保持应用在前台。", isPresented: $deepScan, titleVisibility: .visible) {
                    Button("开始完整扫描") { model.scan(deep: true) }
                }
            }.tabItem { Label("壁纸", systemImage: "photo") }
            NavigationStack { HistoryView() }.tabItem { Label("历史", systemImage: "clock") }
            NavigationStack { BackupsView() }.tabItem { Label("恢复", systemImage: "arrow.uturn.backward") }
            NavigationStack { HelpView() }.tabItem { Label("说明", systemImage: "info.circle") }
        }.tint(.teal)
    }
}

struct EditorView: View {
    @EnvironmentObject var model: WorkshopModel
    let target: WallpaperTarget
    @State private var selection: PhotosPickerItem?
    @State private var source: UIImage?
    @State private var zoom = 1.0
    @State private var x = 0.5
    @State private var y = 0.5
    @State private var saved: SavedWallpaper?
    @State private var confirm = false
    @State private var loading = false
    @State private var error: String?
    private var rendered: UIImage? {
        guard let source, target.editable else { return nil }
        let targetSize = CGSize(width: target.width, height: target.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true; format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            UIColor.black.setFill(); UIRectFill(CGRect(origin: .zero, size: targetSize))
            source.draw(in: CropGeometry.rect(source: source.size, target: targetSize, zoom: zoom, x: x, y: y))
        }
    }
    var body: some View {
        Form {
            Section("目标") { Text(target.name); Text("\(target.mode) · \(target.width) × \(target.height)") }
            Section("选图与裁剪") {
                PhotosPicker(selection: $selection, matching: .images) { Label("从相册选择图片", systemImage: "photo.on.rectangle") }
                    .disabled(model.busy || loading)
                if loading { ProgressView("载入图片…") }
                if let source {
                    GeometryReader { proxy in
                        let size = CGSize(width: proxy.size.width, height: proxy.size.height)
                        let rect = CropGeometry.rect(source: source.size, target: size, zoom: zoom, x: x, y: y)
                        Image(uiImage: source).resizable().frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }
                    .aspectRatio(CGFloat(target.width) / CGFloat(target.height), contentMode: .fit)
                    .clipped().background(.black)
                    Text("缩放"); Slider(value: $zoom, in: 1...4)
                    Text("左右位置"); Slider(value: $x, in: 0...1)
                    Text("上下位置"); Slider(value: $y, in: 0...1)
                }
                Button("生成并保存壁纸") {
                    guard let image = rendered else { return }
                    model.save(image: image, target: target) { saved = $0 }
                }.disabled(source == nil || model.busy)
                if let saved { ShareLink("导出 CPBitmap", item: saved.bitmap) }
            }.disabled(model.busy)
            Section("应用") {
                Text("只替换上面选中的一个文件。写入前自动备份，完成后校验；另一种外观需单独操作。")
                Button("备份并替换这个壁纸") { confirm = true }.disabled(saved == nil || model.busy)
                Text(model.message).textSelection(.enabled)
                if let error { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("编辑\(target.mode)壁纸")
        .onChange(of: zoom) { _, _ in saved = nil }
        .onChange(of: x) { _, _ in saved = nil }
        .onChange(of: y) { _, _ in saved = nil }
        .task(id: selection) {
            guard let selection else { return }
            loading = true; saved = nil; error = nil
            do {
                guard let data = try await selection.loadTransferable(type: Data.self),
                      let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 4096] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
                source = UIImage(cgImage: cg); zoom = 1; x = 0.5; y = 0.5
            } catch { source = nil; self.error = error.localizedDescription }
            loading = false
        }
        .confirmationDialog("替换 \(target.name)？原文件将自动备份。", isPresented: $confirm, titleVisibility: .visible) {
            Button("确认备份并替换") { if let saved { model.apply(entry: saved, target: target) } }
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject var model: WorkshopModel
    @State private var pending: SavedWallpaper?
    var body: some View {
        List {
            Text(model.message)
            if model.history.isEmpty { Text("生成的壁纸会保存在这里，重开应用后仍可使用。") }
            ForEach(model.history) { entry in
                VStack(alignment: .leading, spacing: 10) {
                    if let image = UIImage(contentsOfFile: entry.preview.path) { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 140) }
                    Text("\(entry.mode) · \(entry.width) × \(entry.height)")
                    Text(entry.created, style: .date).font(.caption)
                    ShareLink("导出 CPBitmap", item: entry.bitmap)
                    Button("选择目标并应用") { pending = entry }.disabled(model.busy)
                }
            }
        }.navigationTitle("壁纸历史")
        .sheet(item: $pending) { entry in
            NavigationStack {
                List {
                    Text("请选择相同尺寸的缓存文件。点击后自动备份并替换。")
                    ForEach(model.targets.filter { $0.width == entry.width && $0.height == entry.height }) { target in
                        Button(target.name) { model.apply(entry: entry, target: target); pending = nil }.disabled(model.busy)
                    }
                    if model.targets.isEmpty { Text("请先回到壁纸页扫描缓存。") }
                }.navigationTitle("应用到哪个壁纸")
                    .toolbar { Button("取消") { pending = nil } }
            }
        }
    }
}

struct BackupsView: View {
    @EnvironmentObject var model: WorkshopModel
    @State private var chosen: [String: Any]?
    @State private var confirming = false
    var body: some View {
        List {
            Text("每次替换都会保留原文件。恢复前请先在壁纸页扫描，确认目标容器。")
            Text(model.message)
            if model.backups.isEmpty { Text("尚无备份") }
            ForEach(Array(model.backups.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading) {
                    Text(item["name"] as? String ?? "备份")
                    if let date = item["date"] as? Date { Text(date, style: .date); Text(date, style: .time) }
                    Button("恢复这个版本") { chosen = item; confirming = true }.disabled(model.busy)
                }
            }
        }.navigationTitle("备份与恢复")
        .confirmationDialog("恢复选中的备份？当前文件也会先备份。", isPresented: $confirming, titleVisibility: .visible) {
            Button("确认恢复") { if let chosen { model.restore(chosen) } }
        }
    }
}

struct HelpView: View {
    @EnvironmentObject var model: WorkshopModel
    var body: some View {
        List {
            Section("测试步骤") {
                Text("1. 签名时保留有效 App Group，再安装。")
                Text("2. 停车后，在车机 CarPlay 设置中切换几张内置图片壁纸，让系统生成缓存。")
                Text("3. 回到壁纸页扫描，选中深色或浅色文件，选图、调整裁剪并生成。")
                Text("4. 确认备份并替换。重启 iPhone，重新连接车机检查效果。")
                Text("5. 不满意可在恢复页恢复备份，重启后检查。")
            }
            Section("签名与兼容性") {
                Text("系统：\(UIDevice.current.systemVersion)")
                Text("App Group：\(model.group.isEmpty ? "未提供" : model.group)").textSelection(.enabled)
                Text("需要签名工具实际创建并授予 App Group，例如支持该功能的 AltStore / SideStore。只有 entitlement 字符串不代表已获得权限。企业通配符描述文件通常不支持此功能。")
                Text("本包使用公开的 worse_query 访问方案。iOS 27.2 和车机效果尚待实测；若系统拒绝访问或格式无法识别，会显示错误并停止写入。")
            }
            Section("日志") {
                Button("生成诊断报告") { model.makeReport() }.disabled(model.busy)
                if let reportURL = model.reportURL { ShareLink("导出报告", item: reportURL) }
                Text("报告含目录路径与访问日志，分享前可自行查看。")
            }
            Section("开源") {
                Link("CarCanvas Workshop 源码", destination: URL(string: "https://github.com/zhixinsky/car")!)
                Link("WQFiles / kolbicz", destination: URL(string: "https://github.com/kolbicz/WQFiles")!)
                Link("worse_query / forcequitOS", destination: URL(string: "https://github.com/forcequitOS/worse_query")!)
                Text("GPL-3.0-or-later。访问模块版权属于原作者。")
                if let license = Bundle.main.url(forResource: "LICENSE", withExtension: nil) { ShareLink("查看 / 导出 GPL 许可证", item: license) }
            }
        }.navigationTitle("使用说明")
    }
}
