// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import PhotosUI
import ImageIO

enum CanvasTheme {
    static let accent = Color(red: 0.0, green: 0.55, blue: 0.58)
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
}

struct WallpaperCollection: Identifiable {
    let id: UUID
    let entries: [SavedWallpaper]
    var first: SavedWallpaper { entries[0] }
    var title: String {
        first.customName ?? "CarVista-\(first.created.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()))"
    }
    var mode: String {
        let names = Set(entries.map(\.mode))
        if names.contains("车机") { return "车机整屏与 CarPlay 右半" }
        return names.count > 1 ? "深色与浅色" : first.mode
    }
}

extension WorkshopModel {
    var collections: [WallpaperCollection] {
        Dictionary(grouping: history, by: { $0.batchID ?? $0.id }).map {
            WallpaperCollection(id: $0.key, entries: $0.value.sorted { $0.mode < $1.mode })
        }.sorted { $0.first.created > $1.first.created }
    }
}

struct CanvasHomeView: View {
    @EnvironmentObject var model: WorkshopModel
    @AppStorage("CCGuideSeen") private var guideSeen = false
    @State private var guide = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    HStack(spacing: 18) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("CarVista").font(.largeTitle.bold()).minimumScaleFactor(0.75).lineLimit(1)
                            Text("把喜欢的风景，带上车。").font(.subheadline)
                            Text("v\(CanvasTheme.version)").font(.caption).opacity(0.8)
                        }
                        Spacer(minLength: 0)
                        Image("BrandMark").resizable().frame(width: 76, height: 76)
                            .clipShape(RoundedRectangle(cornerRadius: 19)).accessibilityHidden(true)
                    }.foregroundStyle(.white).padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(LinearGradient(colors: [CanvasTheme.accent, Color(red: 0.15, green: 0.33, blue: 0.55)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 28))
                    NavigationLink { ComposeWallpaperView() } label: {
                        HomeRow(title: "壁纸", subtitle: "选择图片，制作并应用车机壁纸", symbol: "photo.on.rectangle.angled")
                    }.accessibilityIdentifier("home.wallpaper")
                    NavigationLink { CanvasHistoryView() } label: {
                        HomeRow(title: "历史记录", subtitle: "查看、分享和应用已保存的壁纸", symbol: "clock.arrow.circlepath")
                    }.accessibilityIdentifier("home.history")
                    NavigationLink { CacheBrowserView() } label: {
                        HomeRow(title: "CarPlay 壁纸缓存", subtitle: "查看车机壁纸，管理恢复备份", symbol: "folder.fill")
                    }.accessibilityIdentifier("home.cache")
                    NavigationLink { CanvasSettingsView() } label: {
                        HomeRow(title: "设置", subtitle: "使用指南、安装检查与关于", symbol: "gearshape.fill")
                    }.accessibilityIdentifier("home.settings")
                    Button("第一次使用？查看四步指南") { guide = true }
                        .font(.footnote).padding(.top, 14)
                    Text("让每次出发，都有喜欢的画面。")
                        .font(.caption).foregroundStyle(.secondary).padding(.bottom, 24)
                }.padding(20).frame(maxWidth: 660)
                    .frame(maxWidth: .infinity)
            }.background(Color(uiColor: .systemGroupedBackground))
                .toolbar(.hidden, for: .navigationBar)
                .task { if !guideSeen { guide = true } }
                .sheet(isPresented: $guide, onDismiss: { guideSeen = true }) { CanvasGuideView() }
        }.tint(CanvasTheme.accent)
    }
}

private struct HomeRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbol).font(.title2).foregroundStyle(CanvasTheme.accent)
                .frame(width: 52, height: 56).background(CanvasTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.headline).foregroundStyle(Color.primary)
                Text(subtitle).font(.subheadline).foregroundStyle(Color.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.bold()).foregroundStyle(Color.gray.opacity(0.65))
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 23))
            .contentShape(Rectangle())
    }
}

struct CanvasHistoryView: View {
    @EnvironmentObject var model: WorkshopModel
    @State private var clear = false
    @State private var remove: WallpaperCollection?
    var body: some View {
        List {
            if model.collections.isEmpty {
                ContentUnavailableView("还没有保存的壁纸", systemImage: "photo.stack", description: Text("到“壁纸”选择图片，保存后就会出现在这里。"))
            }
            ForEach(model.collections) { collection in
                NavigationLink { WallpaperDetailView(collectionID: collection.id) } label: {
                    HStack(spacing: 14) {
                        SavedThumbnail(entry: collection.first).frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 15))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(collection.title).font(.headline).lineLimit(2)
                            Text(collection.first.created, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                            Text("\(collection.mode) · 本地生成").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 5)
                }.swipeActions { Button("删除", role: .destructive) { remove = collection }.disabled(model.busy) }
            }
        }.navigationTitle("历史记录").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .toolbar { Button("全部清空") { clear = true }.disabled(model.history.isEmpty || model.busy) }
            .confirmationDialog("清空所有本地壁纸记录？已应用的车机壁纸和恢复备份会保留。", isPresented: $clear, titleVisibility: .visible) {
                Button("全部清空", role: .destructive) { model.deleteHistory(model.history) }
            }
            .confirmationDialog("删除这条本地记录？", isPresented: Binding(get: { remove != nil }, set: { if !$0 { remove = nil } }), titleVisibility: .visible) {
                Button("删除记录", role: .destructive) { if let remove { model.deleteHistory(remove.entries) }; remove = nil }
            }
    }
}

private struct SavedThumbnail: View {
    let entry: SavedWallpaper
    var body: some View {
        if let image = UIImage(contentsOfFile: entry.preview.path) { Image(uiImage: image).resizable().scaledToFill() }
        else { Image(systemName: "photo").frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary) }
    }
}

struct WallpaperDetailView: View {
    @EnvironmentObject var model: WorkshopModel
    @Environment(\.dismiss) private var dismiss
    let collectionID: UUID
    @State private var applying = false
    @State private var renaming = false
    @State private var deleting = false
    @State private var name = ""
    private var collection: WallpaperCollection? { model.collections.first { $0.id == collectionID } }
    var body: some View {
        Group {
            if let collection {
                List {
                    Section {
                        let shown = collection.entries.first { $0.mode == "车机" } ?? collection.first
                        SavedThumbnail(entry: shown)
                            .aspectRatio(CGFloat(shown.width) / CGFloat(max(shown.height, 1)), contentMode: .fit).clipped()
                        Text(collection.title).font(.headline)
                        Text("\(collection.mode) · \(shown.width) × \(shown.height)").foregroundStyle(.secondary)
                        if let preset = collection.first.outputPreset { Text("\(preset) · 生成后直接写入").font(.caption).foregroundStyle(.secondary) }
                        if collection.first.preservePixels == true { Text("原尺寸直接写入").font(.caption).foregroundStyle(.secondary) }
                    }
                    Section {
                        Button { applying = true } label: { Label("应用到 CarPlay 壁纸", systemImage: "car.side.fill").font(.headline) }.disabled(model.busy)
                        ShareLink(items: collection.entries.map(\.bitmap)) { Label("分享 CPBitmap 文件", systemImage: "square.and.arrow.up") }
                        if let dashboard = collection.entries.first(where: { $0.mode == "车机" }) {
                            ShareLink(item: dashboard.originalImage) { Label("分享车机整屏图片", systemImage: "photo") }
                        }
                        Button("重命名") { name = collection.title; renaming = true }.disabled(model.busy)
                    }
                    Section { Button("删除记录", role: .destructive) { deleting = true }.disabled(model.busy) }
                }
            } else { ContentUnavailableView("记录已删除", systemImage: "photo") }
        }.navigationTitle("壁纸详情").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $applying) { if let collection { NavigationStack { ApplyWallpaperView(entries: collection.entries) } } }
            .alert("重命名", isPresented: $renaming) {
                TextField("壁纸名称", text: $name)
                Button("保存") { if let collection { model.renameHistory(collection.entries, name: name) } }
                Button("取消", role: .cancel) {}
            }
            .confirmationDialog("只删除本地记录，车机壁纸与恢复备份会保留。", isPresented: $deleting, titleVisibility: .visible) {
                Button("删除记录", role: .destructive) { if let collection { model.deleteHistory(collection.entries); dismiss() } }
            }
    }
}

private struct TargetFamily: Identifiable {
    let id: String
    let targets: [WallpaperTarget]
    var title: String {
        let names = ["Blue": "蓝色", "Purple": "紫色", "Gray": "灰色", "Green": "绿色", "Brown": "棕色", "Red": "红色", "Black": "黑色"]
        for (key, value) in names where id.localizedCaseInsensitiveContains(key) { return "\(value)壁纸" }
        return URL(fileURLWithPath: id).lastPathComponent.replacingOccurrences(of: "CARWallpaper", with: "壁纸 ")
    }
}

private func targetFamilies(_ targets: [WallpaperTarget]) -> [TargetFamily] {
    Dictionary(grouping: targets, by: {
        $0.id.replacingOccurrences(of: "-Dark", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "-Light", with: "", options: .caseInsensitive)
    }).map { TargetFamily(id: $0.key, targets: $0.value) }.sorted { $0.id < $1.id }
}

struct ApplyWallpaperView: View {
    @EnvironmentObject var model: WorkshopModel
    @Environment(\.dismiss) private var dismiss
    let entries: [SavedWallpaper]
    @State private var selected: [WallpaperTarget] = []
    @State private var confirmation = false
    @State private var finished = false
    private var modes: Set<String> { Set(entries.map(\.mode)) }
    var body: some View {
        List {
            Section {
                Text(finished ? model.message : "选择要替换的内置壁纸。原壁纸会自动备份。")
                if !finished { Text("直接写入已保存的 CPBitmap，不按旧缓存尺寸缩放、裁剪或补边。车机如何显示由系统决定。").font(.caption).foregroundStyle(.secondary) }
                if model.busy { ProgressView("正在处理，请保持应用在前台…") }
            }
            if finished {
                Section {
                    LogoutCarPlayButton()
                    Text("注销会结束这次 CarPlay 连接。重新连上车机后，系统才会读取刚写入的壁纸。").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !finished {
                if model.targets.filter(\.editable).isEmpty {
                    Section {
                        if !model.targets.isEmpty { Text("找到缓存，但当前格式或尺寸无法替换。请重新查找，或在设置中导出诊断报告。") }
                        Text(model.group.isEmpty ? "当前安装缺少车机访问权限，需重新签名。已保存的壁纸不受影响。" : model.message)
                        Button("重新查找") { model.scan(deep: false) }.disabled(model.busy || model.group.isEmpty)
                        Button("继续查找（首次可能需要几分钟）") { model.scan(deep: true) }.disabled(model.busy || model.group.isEmpty)
                        if model.busy { Button("停止查找") { CCEngine.cancelScan() } }
                    }
                }
                ForEach(targetFamilies(model.targets.filter(\.editable))) { family in
                    Section(family.title) {
                        let matching = family.targets.filter { modes.contains($0.mode) }
                        if modes.count > 1 && Set(matching.map(\.mode)) == modes {
                            Button("同时应用到深色与浅色") { selected = matching; confirmation = true }.disabled(model.busy)
                        }
                        ForEach(family.targets) { target in
                            Button("应用到\(target.mode) · \(target.width) × \(target.height)") { selected = [target]; confirmation = true }.disabled(model.busy || (entries.count > 1 && !modes.contains(target.mode)))
                        }
                    }
                }
            }
        }.navigationTitle("应用到 CarPlay").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button(finished ? "完成" : "关闭") { dismiss() }.disabled(model.busy) }
            .interactiveDismissDisabled(model.busy)
            .task { if model.targets.isEmpty && !model.busy && !model.group.isEmpty { model.scan(deep: false) } }
            .confirmationDialog("备份并按原尺寸直接替换 \(selected.count) 个文件？", isPresented: $confirmation, titleVisibility: .visible) {
                Button("原尺寸直接替换") { model.applyBatch(entries: entries, targets: selected) { finished = true } }
            }
    }
}

struct CacheBrowserView: View {
    @EnvironmentObject var model: WorkshopModel
    var body: some View {
        List {
            Section {
                if model.busy { ProgressView("正在查找车机壁纸…"); Button("停止查找") { CCEngine.cancelScan() } }
                if model.targets.isEmpty {
                    Text(model.group.isEmpty ? "当前安装无法访问车机壁纸。你仍可在首页制作和保存壁纸。" : model.message)
                    Button("查找车机壁纸") { model.scan(deep: false) }.disabled(model.busy || model.group.isEmpty)
                    Button("继续查找（首次使用）") { model.scan(deep: true) }.disabled(model.busy || model.group.isEmpty)
                } else { Text("找到 \(model.targets.count) 个壁纸文件").foregroundStyle(.secondary) }
            }
            ForEach(targetFamilies(model.targets)) { family in
                Section(family.title) {
                    ForEach(family.targets) { target in
                        NavigationLink { CacheDetailView(target: target) } label: {
                            Label("\(target.mode) · \(target.width) × \(target.height)", systemImage: target.mode == "深色" ? "moon.fill" : "sun.max.fill")
                        }.disabled(model.busy)
                    }
                }
            }
            Section { NavigationLink { BackupsView() } label: { Label("备份与恢复", systemImage: "arrow.uturn.backward") } }
        }.navigationTitle("CarPlay 壁纸缓存").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .toolbar { Button("刷新") { model.scan(deep: false) }.disabled(model.busy || model.group.isEmpty) }
            .task { if model.targets.isEmpty && !model.busy && !model.group.isEmpty { model.scan(deep: false) } }
    }
}

private struct CacheDetailView: View {
    let target: WallpaperTarget
    @State private var preview: UIImage?
    @State private var loading = true
    var body: some View {
        List {
            Section {
                if let preview { Image(uiImage: preview).resizable().scaledToFit() }
                else if loading { ProgressView("载入预览…") }
                else { ContentUnavailableView("暂时无法预览", systemImage: "photo") }
                Text("\(target.mode) · \(target.width) × \(target.height)")
            }
            Section { NavigationLink("从历史记录选择壁纸") { CanvasHistoryView() }; NavigationLink("制作新壁纸") { ComposeWallpaperView() } }
            Section { DisclosureGroup("文件信息") { Text(target.name).font(.caption); Text(target.id).font(.caption).textSelection(.enabled) } }
        }.navigationTitle("缓存预览").navigationBarTitleDisplayMode(.inline)
            .task { preview = await Task.detached { CCEngine.preview(target.id) }.value; loading = false }
    }
}

struct CanvasGuideView: View {
    @Environment(\.dismiss) private var dismiss
    private let steps = [
        ("生成车机壁纸缓存", "停车后，在车机 CarPlay 的“设置 → 壁纸”中切换几张内置图片壁纸。不同系统的排列可能不同。"),
        ("制作自己的壁纸", "打开“壁纸”，选择照片与尺寸模式，点击“生成壁纸文件”。深色与浅色会一起保存，不调整也可以。"),
        ("选择目标并应用", "点击“应用当前照片”，选择要替换的内置壁纸。也可从历史记录再次应用，原文件会自动备份。"),
        ("注销 CarPlay", "替换后点“注销 CarPlay”。应用会结束会话，或打开「设置 → 通用 → CarPlay」让你断开这辆车。等几秒后重新连接，不必关机。需要还原时，在缓存页进入“备份与恢复”。")]
    var body: some View {
        NavigationStack {
            List {
                Section("只需四步") {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, item in
                        HStack(alignment: .top, spacing: 15) {
                            Text("\(index + 1)").font(.title3.bold()).foregroundStyle(CanvasTheme.accent)
                                .frame(width: 38, height: 42).background(CanvasTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 8) { Text(item.0).font(.headline); Text(item.1).font(.subheadline).foregroundStyle(.secondary) }
                        }.padding(.vertical, 10)
                    }
                }
                Text("你可以随时在“设置”里重新打开此指南。").font(.footnote).foregroundStyle(.secondary)
            }.navigationTitle("使用指南").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("知道了") { dismiss() }.fontWeight(.semibold).accessibilityIdentifier("guide.done") }
        }.tint(CanvasTheme.accent)
    }
}

struct CanvasSettingsView: View {
    @EnvironmentObject var model: WorkshopModel
    @State private var guide = false
    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    Image("BrandMark").resizable().frame(width: 60, height: 60).clipShape(RoundedRectangle(cornerRadius: 15))
                    VStack(alignment: .leading, spacing: 5) { Text("CarVista").font(.headline); Text("v\(CanvasTheme.version)").font(.subheadline).foregroundStyle(.secondary) }
                }.padding(.vertical, 6)
            }
            Section {
                LogoutCarPlayButton()
                Text("结束当前连接并重新进入车机，用来让新壁纸生效。").font(.caption).foregroundStyle(.secondary)
                Button { guide = true } label: { Label("使用指南", systemImage: "book") }
                NavigationLink { BackupsView() } label: { Label("备份与恢复", systemImage: "arrow.uturn.backward") }
                NavigationLink { HelpView() } label: { Label("安装检查与诊断", systemImage: "stethoscope") }
            }
            Section("关于") {
                Link("项目源码", destination: URL(string: "https://github.com/zhixinsky/car")!)
                Text("基于公开研究实现。感谢 WQFiles 与 worse_query 作者。GPL-3.0-or-later。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("iOS 27.2 与实际车机效果仍需设备验证。").font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("设置").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .sheet(isPresented: $guide) { CanvasGuideView() }
    }
}

struct LogoutCarPlayButton: View {
    @State private var message: String?
    var body: some View {
        Button { message = (CCEngine.logoutCarPlay() as? [String: Any])?["message"] as? String ?? "无法注销 CarPlay" } label: {
            Label("注销 CarPlay", systemImage: "rectangle.portrait.and.arrow.right")
        }.accessibilityIdentifier("carplay.logout")
            .alert("注销 CarPlay", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("知道了", role: .cancel) { message = nil }
            } message: { Text(message ?? "") }
    }
}