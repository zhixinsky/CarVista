// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import PhotosUI
import ImageIO
import Network

@main
struct CarVistaApp: App {
    @StateObject private var model = WorkshopModel()
    var body: some Scene {
        WindowGroup {
            CanvasHomeView().environmentObject(model)
                .task { await ServiceClient.shared.startup() }
        }
    }
}

struct WallpaperTarget: Identifiable {
    let raw: [String: Any]
    var id: String { raw["path"] as? String ?? "" }
    var name: String { raw["name"] as? String ?? "" }
    var mode: String { raw["mode"] as? String ?? "未知" }
    var width: Int { raw["width"] as? Int ?? 0 }
    var height: Int { raw["height"] as? Int ?? 0 }
    var editable: Bool { WallpaperStorage.validSize(width: width, height: height) }
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
    @Published var reportNote = ""
    @Published var reportFailed = false
    @Published var generationProgress = 0.0
    @Published var photoDownloadUnlocked = false
    @Published var lastDetectedWallpaperSize: CGSize?
    @Published private(set) var lastScanSummary: String?
    @Published private(set) var lastApplySummary: String?
    @Published private(set) var lastUnlockSummary: String?
    let group = CCEngine.appGroup()
    var appGroupStatus: String {
        guard !group.isEmpty else { return "未声明" }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) == nil
            ? "已声明，系统未返回容器" : "已声明，系统已返回容器"
    }
    var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
        return "\(version)（\(build)）"
    }
    nonisolated static var library: URL {
        WallpaperStorage.library
    }
    private let queue = DispatchQueue(label: "carvista.io", qos: .userInitiated)

    init() {
        let width = UserDefaults.standard.integer(forKey: "LMAutoWidth")
        let height = UserDefaults.standard.integer(forKey: "LMAutoHeight")
        if WallpaperStorage.validSize(width: width, height: height) { lastDetectedWallpaperSize = CGSize(width: width, height: height) }
        do {
            try FileManager.default.createDirectory(at: Self.library, withIntermediateDirectories: true)
            let files = try FileManager.default.contentsOfDirectory(at: Self.library, includingPropertiesForKeys: nil)
            history = files.filter { $0.pathExtension == "json" }.compactMap {
                guard let data = try? Data(contentsOf: $0) else { return nil }
                guard let entry = try? JSONDecoder().decode(SavedWallpaper.self, from: data),
                      WallpaperStorage.validSize(width: entry.width, height: entry.height),
                      $0.deletingPathExtension().lastPathComponent == entry.id.uuidString,
                      FileManager.default.fileExists(atPath: entry.bitmap.path) else { return nil }
                return entry
            }.sorted { $0.created > $1.created }
        } catch { message = "无法载入本地历史：\(error.localizedDescription)" }
        backups = CCEngine.backups() as? [[String: Any]] ?? []
    }

    func report(_ type: String, ok: Bool, _ payload: [String: Any]) {
        Task { await ServiceClient.shared.record(type: type, ok: ok, payload: payload) }
    }

    func prepareOriginal(_ data: Data, source: String, assetID: String?) async -> [SavedWallpaper] {
        guard !busy else { return [] }
        do {
            var incoming = try await Task.detached { try MakerDraft.importPhoto(data: data) }.value
            incoming.remoteSource = source
            incoming.remoteAssetID = assetID
            return await withCheckedContinuation { continuation in
                generatePhotos([incoming], preset: .original, size: .zero) { batches in
                    try? FileManager.default.removeItem(at: incoming.url)
                    continuation.resume(returning: batches.first ?? [])
                }
            }
        } catch {
            message = "无法准备壁纸。"
            return []
        }
    }

    func reportSaved(_ entries: [SavedWallpaper], source: String, assetID: String?) {
        let groups = Dictionary(grouping: entries) { $0.batchID ?? $0.id }
        for group in groups.values {
            guard let entry = group.first else { continue }
            Task { await ServiceClient.shared.submitSaved(entry, source: source, assetID: assetID) }
        }
    }

    func work(_ task: @escaping () -> [String: Any], finish: @escaping ([String: Any]) -> Void) {
        guard !busy else { return }
        busy = true
        queue.async {
            let result = autoreleasepool { task() }
            DispatchQueue.main.async {
                self.busy = false
                finish(result)
                self.backups = CCEngine.backups() as? [[String: Any]] ?? []
            }
        }
    }

    func scan(deep: Bool) {
        guard !busy else { return }
        message = deep ? "正在完整扫描容器，请保持应用在前台。首次可能需要数分钟。" : "正在定位壁纸缓存…"
        work({ CCEngine.discover(deep) as? [String: Any] ?? [:] }) { result in
            self.targets = (result["files"] as? [[String: Any]] ?? []).map { WallpaperTarget(raw: $0) }
            if let size = self.detectedWallpaperSize {
                self.lastDetectedWallpaperSize = size
                UserDefaults.standard.set(Int(size.width), forKey: "LMAutoWidth")
                UserDefaults.standard.set(Int(size.height), forKey: "LMAutoHeight")
            }
            self.issues = result["issues"] as? [String] ?? []
            self.root = result["root"] as? String ?? ""
            self.message = result["message"] as? String ?? "扫描失败"
            let editable = self.targets.filter(\.editable).count
            self.lastScanSummary = self.targets.isEmpty
                ? self.message : "找到 \(self.targets.count) 个，格式与尺寸符合要求 \(editable) 个"
            self.makeReport()
            let ok = result["ok"] as? Bool == true
            self.report("scan_result", ok: ok, [
                "message": self.message, "stage": "scan",
                "target_count": self.targets.count, "editable_count": editable,
                "app_group": !self.group.isEmpty
            ])
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
                self.reportSaved([entry], source: "photo", assetID: nil)
            } else { self.message = result["message"] as? String ?? "生成失败"; completion(nil) }
        }
    }

    func unlockWallpapers() {
        guard !busy else { return }
        message = "正在解除壁纸锁定…"
        work({ CCEngine.unlockWallpapers() as? [String: Any] ?? [:] }) { result in
            self.message = result["message"] as? String ?? "解锁失败"
            self.lastUnlockSummary = self.message
        }
    }

    func apply(entry: SavedWallpaper, target: WallpaperTarget) {
        message = "正在备份、写入并校验…"
        work({ CCEngine.apply(target.raw, source: entry.bitmap.path) as? [String: Any] ?? [:] }) { result in
            self.message = result["message"] as? String ?? "写入失败"
            self.lastApplySummary = self.message
            // Snapshots are invalid after a mutation attempt; require a rescan.
            self.targets = []
            self.makeReport()
            let ok = result["ok"] as? Bool == true
            self.report("apply_result", ok: ok, [
                "message": self.message, "stage": "apply", "completed": ok ? 1 : 0, "total": 1,
                "target_width": target.width, "target_height": target.height, "mode": target.mode,
                "output_width": entry.width, "output_height": entry.height,
                "app_group": !self.group.isEmpty
            ])
        }
    }

    func restore(_ backup: [String: Any]) {
        guard !busy, let path = backup["path"] as? String else { return }
        message = "正在恢复并校验…"
        work({ CCEngine.restore(path) as? [String: Any] ?? [:] }) { result in
            self.message = result["message"] as? String ?? "恢复失败"
            self.targets = []
            self.makeReport()
            self.report("restore_result", ok: result["ok"] as? Bool == true, [
                "message": self.message, "stage": "restore", "app_group": !self.group.isEmpty
            ])
        }
    }

    func makeReport(upload: Bool = false) {
        guard upload else {
            writeReport(upload: false, network: nil)
            return
        }
        guard !busy else { return }
        busy = true
        reportFailed = false
        reportNote = "正在检查网络…"
        Task {
            let network = await NetworkCheck.collect()
            self.busy = false
            self.writeReport(upload: true, network: network)
        }
    }

    private func writeReport(upload: Bool, network: [String: Any]?) {
        do {
            let clock = ISO8601DateFormatter()
            clock.formatOptions = [.withInternetDateTime]
            clock.timeZone = TimeZone(identifier: "Asia/Shanghai")
            var object: [String: Any] = ["date": clock.string(from: Date()),
                "system": UIDevice.current.systemVersion, "model": UIDevice.current.model,
                "appGroup": group, "root": root, "message": message, "issues": issues,
                "targets": targets.map(\.raw), "log": CCEngine.logs(),
                "appVersion": appVersion, "appGroupStatus": appGroupStatus,
                "lastScan": lastScanSummary ?? "本次启动尚未查找",
                "lastApply": lastApplySummary ?? "本次启动尚未应用"]
            if let network { object["network"] = network }
            var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            if data.count > 900_000 {
                object["log"] = "日志过长，已截断后上传"
                data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("CarVista-\(UUID().uuidString).json")
            try data.write(to: url, options: .atomic)
            reportURL = url
            if upload {
                let brief = network.map(NetworkCheck.brief) ?? ""
                let note = brief.isEmpty ? "诊断报告已生成" : "诊断报告已生成。\(brief)"
                reportFailed = false
                reportNote = note
                Task {
                    let ok = await ServiceClient.shared.submitReport(data)
                    self.reportFailed = !ok
                    self.reportNote = ok ? note : "诊断报告已生成，上传后台失败。\(brief)"
                }
            }
        } catch {
            message = "导出报告失败：\(error.localizedDescription)"
            if upload {
                reportFailed = true
                reportNote = message
            }
        }
    }

    func saveVariants(image: UIImage, modes: [String], preservePixels: Bool = false, completion: @escaping ([SavedWallpaper]) -> Void) {
        guard !busy else { return }
        guard let cg = image.cgImage, WallpaperStorage.validSize(width: cg.width, height: cg.height),
              !modes.isEmpty, Set(modes).count == modes.count,
              modes.allSatisfy({ ["深色", "浅色"].contains($0) }) else {
            message = "图片尺寸或外观选项无效"; completion([]); return
        }
        let batch = UUID()
        let entries = modes.map { SavedWallpaper(id: UUID(), created: Date(), width: cg.width,
            height: cg.height, mode: $0, batchID: batch, preservePixels: preservePixels) }
        message = "正在保存壁纸…"
        work({
            var failure: String?
            do {
                // Only the history thumbnail is reduced. The CPBitmap and PNG
                // retain every original pixel, including for very wide screens.
                let ratio = min(1, 512 / max(image.size.width, image.size.height))
                let previewSize = CGSize(width: max(1, image.size.width * ratio), height: max(1, image.size.height * ratio))
                let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
                let preview = UIGraphicsImageRenderer(size: previewSize, format: format).image { _ in
                    image.draw(in: CGRect(origin: .zero, size: previewSize))
                }
                guard let jpeg = preview.jpegData(compressionQuality: 0.85), let png = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
                for entry in entries {
                    let encoded = CCEngine.encode(image, to: entry.bitmap.path) as? [String: Any] ?? [:]
                    guard encoded["ok"] as? Bool == true else {
                        failure = encoded["message"] as? String ?? "当前系统无法生成壁纸文件"; break
                    }
                    try jpeg.write(to: entry.preview, options: .atomic)
                    try png.write(to: entry.originalImage, options: .atomic)
                    try JSONEncoder().encode(entry).write(to: Self.library.appendingPathComponent("\(entry.id).json"), options: .atomic)
                }
            } catch { failure = error.localizedDescription }
            if let failure {
                for entry in entries {
                    for url in [entry.bitmap, entry.preview, entry.originalImage, Self.library.appendingPathComponent("\(entry.id).json")] {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
                return ["ok": false, "message": failure]
            }
            return ["ok": true]
        }) { result in
            if result["ok"] as? Bool == true {
                self.history.insert(contentsOf: entries, at: 0)
                self.message = "已保存到历史记录，可随时应用或分享。"
                completion(entries)
                self.reportSaved(entries, source: "photo", assetID: nil)
            } else {
                self.message = result["message"] as? String ?? "保存失败"
                completion([])
            }
        }
    }

    func applyBatch(entries: [SavedWallpaper], targets: [WallpaperTarget], completion: @escaping (Int) -> Void) {
        guard !busy else { return }
        guard !targets.isEmpty, targets.allSatisfy(\.editable),
              Set(targets.map(\.id)).count == targets.count, !entries.isEmpty else {
            message = "所选缓存不可替换，请重新查找。"; completion(0); return
        }
        guard targets.allSatisfy({ target in entries.count == 1 || entries.contains(where: { $0.mode == target.mode }) }) else {
            message = "没有对应外观的壁纸，请重新选择。"; completion(0); return
        }
        message = "正在备份并应用壁纸…"
        work({
            var completed = 0
            for target in targets {
                guard let entry = entries.first(where: { $0.mode == target.mode }) ?? (entries.count == 1 ? entries.first : nil) else {
                    return ["completed": completed, "message": "已应用 \(completed)/\(targets.count) 个。没有对应外观的壁纸，请重新选择。"]
                }
                // Write the saved CPBitmap bytes directly; never resize to the old cache.
                let source = entry.bitmap.path
                let result = CCEngine.apply(target.raw, source: source) as? [String: Any] ?? [:]
                if result["ok"] as? Bool != true {
                    let failure = result["message"] as? String ?? "写入失败"
                    let recovery = completed > 0 ? "。已完成的项目可在备份与恢复中还原。" : ""
                    return ["completed": completed, "message": "已应用 \(completed)/\(targets.count) 个。\(failure)\(recovery)"]
                }
                completed += 1
            }
            return ["completed": completed, "message": "\(completed) 张壁纸已写入，原文件已备份。请在车机确认显示效果。"]
        }) { result in
            self.message = result["message"] as? String ?? "应用失败"
            self.lastApplySummary = self.message
            self.targets = []
            self.makeReport()
            let completed = result["completed"] as? Int ?? 0
            self.report("apply_result", ok: completed == targets.count && !targets.isEmpty, [
                "message": self.message, "stage": "apply", "completed": completed, "total": targets.count,
                "target_width": targets.first?.width ?? 0, "target_height": targets.first?.height ?? 0,
                "mode": targets.first?.mode ?? "",
                "output_width": entries.first?.width ?? 0, "output_height": entries.first?.height ?? 0,
                "app_group": !self.group.isEmpty
            ])
            completion(completed)
        }
    }

    func deleteHistory(_ entries: [SavedWallpaper]) {
        guard !busy else { return }
        var removed = Set<UUID>()
        var failures = 0
        for entry in entries {
            do {
                // Delete the index last: interrupted removal can be retried.
                for url in [entry.bitmap, entry.preview, entry.originalImage, Self.library.appendingPathComponent("\(entry.id).json")] {
                    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                }
                removed.insert(entry.id)
            } catch { failures += 1 }
        }
        history.removeAll { removed.contains($0.id) }
        message = failures == 0 ? "已删除本地记录，已应用的壁纸和恢复备份未改变。" : "部分记录未能删除，请重试。"
    }

    func renameHistory(_ entries: [SavedWallpaper], name: String) {
        let title = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !busy, !title.isEmpty else { return }
        for entry in entries {
            guard let index = history.firstIndex(where: { $0.id == entry.id }) else { continue }
            var updated = history[index]; updated.customName = title
            do {
                try JSONEncoder().encode(updated).write(to: Self.library.appendingPathComponent("\(entry.id).json"), options: .atomic)
                history[index] = updated
            } catch { message = "重命名失败：\(error.localizedDescription)" }
        }
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
                        Label("CarVista", systemImage: "car.side.fill").font(.title2.bold())
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
            Text("每个壁纸只在第一次替换前保存苹果自带的原图，之后不会覆盖。恢复始终回到这一份。恢复前先查找车机壁纸。")
            Button("查找车机壁纸") { model.scan(deep: false) }.disabled(model.busy || model.group.isEmpty)
            if model.busy { ProgressView("正在处理…") }
            Text(model.message)
            if model.backups.isEmpty { Text("还没有原始壁纸。第一次替换时会自动保存。") }
            ForEach(Array(model.backups.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading) {
                    Text(item["name"] as? String ?? "备份")
                    if let date = item["date"] as? Date { Text(date, style: .date); Text(date, style: .time) }
                    Button("恢复苹果原壁纸") { chosen = item; confirming = true }.disabled(model.busy)
                }
            }
        }.navigationTitle("备份与恢复")
        .confirmationDialog("恢复第一次保存的苹果原壁纸？车上现在的图会被换回这一份。", isPresented: $confirming, titleVisibility: .visible) {
            Button("确认恢复") { if let chosen { model.restore(chosen) } }
        }
    }
}

struct HelpView: View {
    @EnvironmentObject var model: WorkshopModel
    @State private var unlockConfirm = false
    var body: some View {
        List {
            Section {
                LabeledContent("系统", value: "iOS \(UIDevice.current.systemVersion)")
                LabeledContent("CarVista", value: model.appVersion)
                diagnosticRow("签名容器", result: model.appGroupStatus)
                diagnosticRow("最近查找", result: model.lastScanSummary ?? "本次启动尚未查找")
                diagnosticRow("最近应用", result: model.lastApplySummary ?? "本次启动尚未应用")
                diagnosticRow("最近解锁", result: model.lastUnlockSummary ?? "本次启动尚未解锁")
                Button("解锁壁纸") { unlockConfirm = true }
                    .disabled(model.busy || model.group.isEmpty)
            } header: {
                Text("诊断摘要")
            } footer: {
                Text("遇到应用失败时，可直接截取这一区域。解锁只去掉车机壁纸文件上的锁定，不改图片。查找、应用和解锁结果会保留到本次启动结束。")
            }
            Section("报告") {
                Button("生成诊断报告") { model.makeReport(upload: true) }.disabled(model.busy)
                if !model.reportNote.isEmpty {
                    Text(model.reportNote)
                        .font(.subheadline)
                        .foregroundStyle(model.reportFailed ? Color.red : Color.secondary)
                }
                if let reportURL = model.reportURL { ShareLink("导出报告", item: reportURL) }
            }
            Section("测试步骤") {
                Text("1. 签名时保留有效 App Group，再安装。")
                Text("2. 停车后，在车机 CarPlay 设置中切换几张内置图片壁纸，让系统生成缓存。")
                Text("3. 打开“壁纸”，选择照片与尺寸模式，生成后点击“应用当前照片”。也可以从历史记录再次应用。")
                Text("4. 确认备份并替换，然后点“重启 CarPlay”，尝试重载系统界面让壁纸生效。若仍显示旧图，请手动重启 iPhone 后重新连接车机。")
                Text("5. 不满意可在恢复页恢复备份，再重启 iPhone 并连接 CarPlay 检查。")
            }
            Section("签名与兼容性") {
                Text("App Group：\(model.group.isEmpty ? "未提供" : model.group)").textSelection(.enabled)
                Text("需要签名工具实际创建并授予 App Group，例如支持该功能的 AltStore / SideStore。只有 entitlement 字符串不代表已获得权限。企业通配符描述文件通常不支持此功能。")
                Text("本包使用公开的 worse_query 访问方案。iOS 27.2 和车机效果尚待实测；若系统拒绝访问或格式无法识别，会显示错误并停止写入。")
            }
            Section("开源") {
                Link("CarVista源码", destination: URL(string: "https://github.com/zhixinsky/CarVista")!)
                Link("WQFiles / kolbicz", destination: URL(string: "https://github.com/kolbicz/WQFiles")!)
                Link("worse_query / forcequitOS", destination: URL(string: "https://github.com/forcequitOS/worse_query")!)
                Text("GPL-3.0-or-later。访问模块版权属于原作者。")
                if let license = Bundle.main.url(forResource: "LICENSE", withExtension: nil) { ShareLink("查看 / 导出 GPL 许可证", item: license) }
            }
        }
        .navigationTitle("安装检查与诊断")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("解除车机壁纸锁定？解除后，其他软件或系统可能再次替换这些壁纸。", isPresented: $unlockConfirm, titleVisibility: .visible) {
            Button("解锁壁纸", role: .destructive) { model.unlockWallpapers() }
            Button("取消", role: .cancel) {}
        }
    }

    private func diagnosticRow(_ title: String, result: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(result).font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private enum NetworkCheck {
    private struct PathFacts: Sendable {
        var status: String
        var interface: String
        var expensive: Bool
        var constrained: Bool
    }

    private struct LinkProbe: Sendable {
        var url: String
        var status: Int
        var milliseconds: Int
        var bytes: Int
        var error: String

        var dictionary: [String: Any] {
            [
                "url": url,
                "ok": (200..<400).contains(status),
                "status": status,
                "milliseconds": milliseconds,
                "bytes": bytes,
                "error": error
            ]
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }()

    static func collect() async -> [String: Any] {
        async let path = pathFacts()
        async let baidu = probe(URL(string: "https://www.baidu.com")!)
        async let backend = probe(ServiceGate.baseURL)
        let facts = await path
        let baiduResult = await baidu
        let backendResult = await backend
        let image = await probeGalleryImage()
        return [
            "summary": summaryText(facts: facts, baidu: baiduResult, backend: backendResult, image: image),
            "status": facts.status,
            "interface": facts.interface,
            "expensive": facts.expensive,
            "constrained": facts.constrained,
            "baidu": baiduResult.dictionary,
            "backend": backendResult.dictionary,
            "image": image.dictionary
        ]
    }

    static func brief(_ network: [String: Any]) -> String {
        let image = network["image"] as? [String: Any] ?? [:]
        let picture = image["ok"] as? Bool == true ? "图库图片可打开" : "图库图片打不开"
        return "\(word(network["baidu"], "百度"))，\(word(network["backend"], "网站"))，\(picture)。"
    }

    private static func word(_ value: Any?, _ name: String) -> String {
        let item = value as? [String: Any] ?? [:]
        let status = item["status"] as? Int ?? 0
        if (200..<400).contains(status) { return "\(name)可访问" }
        if status > 0 { return "\(name)返回\(status)" }
        return "\(name)无法连接"
    }

    private static func summaryText(facts: PathFacts, baidu: LinkProbe, backend: LinkProbe, image: ImageProbe) -> String {
        var notes = ["\(facts.interface) \(facts.status)"]
        if facts.expensive { notes.append("计费网络") }
        if facts.constrained { notes.append("低数据模式") }
        return "\(notes.joined(separator: "，"))。\(detail("百度", baidu))。\(detail("网站", backend))。\(image.sentence)。"
    }

    private static func detail(_ name: String, _ probe: LinkProbe) -> String {
        if (200..<400).contains(probe.status) {
            return "\(name)可访问（\(probe.status)，\(probe.milliseconds)毫秒）"
        }
        if probe.status > 0 {
            return "\(name)已连通但返回 \(probe.status)（\(probe.milliseconds)毫秒）"
        }
        let reason = probe.error.isEmpty ? "无法连接" : probe.error
        return "\(name)无法连接（\(reason)）"
    }

    private static func probe(_ url: URL) async -> LinkProbe {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "GET"
        let start = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return LinkProbe(url: url.absoluteString, status: code,
                             milliseconds: elapsed(since: start), bytes: data.count, error: "")
        } catch {
            let reason = (error as? URLError).map { "\($0.localizedDescription)（\($0.code.rawValue)）" } ?? error.localizedDescription
            return LinkProbe(url: url.absoluteString, status: 0,
                             milliseconds: elapsed(since: start), bytes: 0, error: String(reason.prefix(180)))
        }
    }

    private struct ImageProbe: Sendable {
        var url = ""
        var resolved = ""
        var status = 0
        var milliseconds = 0
        var bytes = 0
        var contentType = ""
        var error: String

        var ok: Bool { (200..<300).contains(status) && error.isEmpty }

        var dictionary: [String: Any] {
            [
                "url": url, "resolved": resolved, "ok": ok, "status": status,
                "milliseconds": milliseconds, "bytes": bytes, "contentType": contentType, "error": error
            ]
        }

        var sentence: String {
            if ok { return "图库预览图可打开（\(status)，\(milliseconds)毫秒，\(bytes)字节）" }
            let reason = error.isEmpty ? "无法下载" : error
            let address = resolved.isEmpty ? url : resolved
            return address.isEmpty ? "图库预览图打不开（\(reason)）" : "图库预览图打不开（\(reason)）。地址 \(address)"
        }
    }

    private struct CategoryList: Decodable { let items: [CategoryRow] }
    private struct CategoryRow: Decodable { let id: String }
    private struct PreviewList: Decodable { let items: [PreviewRow] }
    private struct PreviewRow: Decodable {
        let previewURL: URL
        enum CodingKeys: String, CodingKey { case previewURL = "preview_url" }
    }

    private static func probeGalleryImage() async -> ImageProbe {
        do {
            let categories = try await get(ServiceGate.join("v1/gallery/categories"))
            guard let listed = try? JSONDecoder().decode(CategoryList.self, from: categories.data),
                  categories.status == 200 else {
                return ImageProbe(error: "壁纸分类无法打开")
            }
            for category in listed.items {
                let catalog = try await get(ServiceGate.join("v1/catalog/\(category.id)"))
                guard catalog.status == 200, let feed = try? JSONDecoder().decode(PreviewList.self, from: catalog.data),
                      let preview = feed.items.first?.previewURL else { continue }
                return await downloadPreview(preview)
            }
            return ImageProbe(error: "后台没有可下载的图库图片")
        } catch {
            return ImageProbe(error: String(errorText(error).prefix(180)))
        }
    }

    private static func downloadPreview(_ preview: URL) async -> ImageProbe {
        let resolved = ServiceClient.publicURL(preview)
        let start = Date()
        do {
            let result = try await get(resolved)
            let type = (result.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
            let magic = imageData(result.data)
            var failure = ""
            if !(200..<300).contains(result.status) {
                failure = "状态 \(result.status)"
            } else if !magic {
                failure = "返回的不是图片（\(type.isEmpty ? "未知类型" : type)）"
            }
            return ImageProbe(url: preview.absoluteString, resolved: resolved.absoluteString, status: result.status,
                              milliseconds: elapsed(since: start), bytes: result.data.count, contentType: type, error: failure)
        } catch {
            return ImageProbe(url: preview.absoluteString, resolved: resolved.absoluteString,
                              milliseconds: elapsed(since: start), error: errorText(error))
        }
    }

    private struct Body { let data: Data; let response: URLResponse; var status: Int { (response as? HTTPURLResponse)?.statusCode ?? 0 } }

    private static func get(_ url: URL) async throws -> Body {
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 12))
        return Body(data: data, response: response)
    }

    private static func imageData(_ data: Data) -> Bool {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
        return data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    private static func errorText(_ error: Error) -> String {
        let reason = (error as? URLError).map { "\($0.localizedDescription)（\($0.code.rawValue)）" } ?? error.localizedDescription
        return String(reason.prefix(180))
    }

    private static func elapsed(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    private static func pathFacts() async -> PathFacts {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "carvista.netpath")
            let lock = NSLock()
            var resumed = false
            func finish(_ facts: PathFacts) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                monitor.cancel()
                continuation.resume(returning: facts)
            }
            monitor.pathUpdateHandler = { path in
                let interface: String
                if path.usesInterfaceType(.wifi) { interface = "Wi-Fi" }
                else if path.usesInterfaceType(.cellular) { interface = "蜂窝" }
                else if path.usesInterfaceType(.wiredEthernet) { interface = "有线" }
                else { interface = path.status == .satisfied ? "其他" : "无" }
                finish(PathFacts(
                    status: path.status == .satisfied ? "可用" : "不可用",
                    interface: interface,
                    expensive: path.isExpensive,
                    constrained: path.isConstrained
                ))
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 2) {
                finish(PathFacts(status: "未知", interface: "未知", expensive: false, constrained: false))
            }
        }
    }
}