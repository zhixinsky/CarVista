// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import PhotosUI

struct ComposeWallpaperView: View {
    @EnvironmentObject var model: WorkshopModel
    @AppStorage("LMPreset") private var presetValue = WallpaperPreset.automatic.rawValue
    @AppStorage("LMCustomWidth") private var customWidth = 1920
    @AppStorage("LMCustomHeight") private var customHeight = 810
    @State private var photos: [MakerPhoto] = []
    @State private var selection: [PhotosPickerItem] = []
    @State private var current = 0
    @State private var loading = false
    @State private var adjusting = false
    @State private var builtin: BuiltinWallpaper?
    @State private var applying = false
    @State private var problem: String?
    @State private var generated: [UUID: [SavedWallpaper]] = [:]
    @State private var preview: UIImage?
    @State private var previewing = false
    @State private var initialized = false
    @State private var sourcePixels: CGSize?
    private var preset: WallpaperPreset { WallpaperPreset(rawValue: presetValue) ?? .automatic }
    private var photo: MakerPhoto? { photos.indices.contains(current) ? photos[current] : nil }
    private var outputSize: CGSize {
        if preset == .custom { return CGSize(width: customWidth, height: customHeight) }
        guard preset.preservesSourceSize else { return preset.size(detected: model.detectedWallpaperSize) }
        guard let sourcePixels, sourcePixels.width > 0, sourcePixels.height > 0 else { return .zero }
        let turns = (((photo?.adjustment.turns ?? 0) % 4) + 4) % 4
        return turns % 2 == 0 ? sourcePixels : CGSize(width: sourcePixels.height, height: sourcePixels.width)
    }
    private var filesPerPhoto: Int { 2 }
    private var outputLabel: String {
        guard outputSize.width > 0, outputSize.height > 0 else { return "读取原图尺寸…" }
        return "\(Int(outputSize.width)) × \(Int(outputSize.height))"
    }
    private var locked: Bool { loading || model.busy }
    private var renderKey: String { "\(photo?.id.uuidString ?? "empty")-\(String(describing: photo?.adjustment))-\(presetValue)-\(outputLabel)" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    Image("BrandMark").resizable().frame(width: 58, height: 58).clipShape(RoundedRectangle(cornerRadius: 15))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("CarVista").font(.title.bold()); Text("v\(CanvasTheme.version)").font(.caption).foregroundStyle(.secondary) }
                        Text("制作并替换 CarPlay 壁纸").foregroundStyle(.secondary)
                    }
                }
                step("01", "选择照片", "一次最多选 6 张。点缩略图切换，默认不需要调整。")
                VStack(spacing: 14) {
                    Group {
                        if let preview { Image(uiImage: preview).resizable().scaledToFit() }
                        else if photos.isEmpty { ContentUnavailableView("选一张喜欢的照片", systemImage: "photo.on.rectangle.angled", description: Text("先选照片，再选适合车机的尺寸。")) }
                        else { ProgressView("正在生成预览…").frame(height: 160) }
                    }.frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay(alignment: .topTrailing) { if previewing && preview != nil { ProgressView().padding(12).background(.regularMaterial, in: Capsule()) } }
                    if !photos.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(Array(photos.enumerated()), id: \.element.id) { index, item in
                                    Button { current = index } label: {
                                        VStack(spacing: 4) {
                                            MakerThumbnail(url: item.url).frame(width: 72, height: 48).clipped().clipShape(RoundedRectangle(cornerRadius: 9))
                                            Text("第 \(index + 1) 张").font(.caption2)
                                        }.padding(5).background(current == index ? CanvasTheme.accent.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                                    }.buttonStyle(.plain).disabled(locked)
                                }
                            }
                        }
                    }
                    HStack {
                        Text("已选 \(photos.count) / 6 张").font(.subheadline.bold())
                        Spacer()
                        Text("输出 \(outputLabel)").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("maker.output")
                    }
                    HStack(spacing: 10) {
                        PhotosPicker(selection: $selection, maxSelectionCount: 6, selectionBehavior: .ordered, matching: .images) {
                            Label(photos.isEmpty ? "选择照片" : "更换照片", systemImage: "photo.badge.plus").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).disabled(locked).accessibilityIdentifier("maker.select")
                        Button("调整") { adjusting = true }.buttonStyle(.bordered).disabled(photo == nil || locked)
                            .accessibilityIdentifier("maker.adjust")
                        Button(role: .destructive) { removeCurrent() } label: { Image(systemName: "trash") }
                            .buttonStyle(.bordered).disabled(photo == nil || locked).accessibilityLabel("移除当前照片")
                    }
                    if loading { ProgressView("正在导入照片…") }
                }.padding(16).background(cardColor, in: RoundedRectangle(cornerRadius: 24))

                VStack(alignment: .leading, spacing: 12) {
                    Text("内置壁纸").font(.headline)
                    Text("选择整屏壁纸，拖动分界线截取右侧 CarPlay 画面。").font(.caption).foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(BuiltinWallpaper.all) { item in
                                Button { builtin = item } label: {
                                    VStack {
                                        BuiltinWallpaperPreview(wallpaper: item)
                                            .frame(width: 160, height: 44)
                                            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                                            .accessibilityHidden(true)
                                        Text(item.title).font(.caption)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(locked)
                            }
                        }
                    }
                }.padding(16).background(cardColor, in: RoundedRectangle(cornerRadius: 24))
                VStack(alignment: .leading, spacing: 16) {
                    step("02", "生成壁纸文件", "每张照片自动生成深色与浅色两个版本。")
                    Text("输出 · \(outputLabel)").font(.subheadline).foregroundStyle(.secondary)
                    Button { generate() } label: {
                        Label("生成壁纸文件", systemImage: "sparkles").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 9)
                    }.buttonStyle(.borderedProminent).disabled(photos.isEmpty || locked).accessibilityIdentifier("wallpaper.generate")
                    if model.busy { ProgressView(value: model.generationProgress); Text("正在处理，请保持应用在前台…").font(.caption) }
                    Text("已生成 \(generated.values.reduce(0) { $0 + $1.count }) / \(photos.count * filesPerPhoto)").font(.caption).foregroundStyle(.secondary)
                    if let problem { Text(problem).font(.subheadline).foregroundStyle(.red) }
                }.padding(18).background(cardColor, in: RoundedRectangle(cornerRadius: 24))

                VStack(alignment: .leading, spacing: 16) {
                    step("03", "替换 CarPlay 壁纸", "选择目标后自动备份，再直接写入生成的文件。")
                    Label(model.group.isEmpty ? "本地制作可用，车机访问需有效签名" : "签名组已提供", systemImage: "checkmark.shield")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button("检测车机壁纸") { model.scan(deep: false) }.disabled(locked || model.group.isEmpty)
                    if !model.targets.isEmpty { Text("已找到 \(model.targets.count) 个缓存文件").font(.caption).foregroundStyle(.secondary) }
                    Button { applying = true } label: {
                        Label("应用当前照片", systemImage: "car.side.fill").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.buttonStyle(.borderedProminent).disabled(photo.flatMap { generated[$0.id] } == nil || locked)
                    WallpaperRefreshButton()
                    NavigationLink("查看历史记录与已生成文件") { CanvasHistoryView() }
                    Text(model.message).font(.caption).foregroundStyle(.secondary)
                }.padding(18).background(cardColor, in: RoundedRectangle(cornerRadius: 24))
            }.padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }.background(Color(uiColor: .systemGroupedBackground)).tint(CanvasTheme.accent)
            .navigationTitle("壁纸").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .onAppear { initialize() }
            .onChange(of: presetValue) { _, _ in generated = [:] }
            .onChange(of: outputLabel) { _, _ in generated = [:] }
            .task(id: selection) { await importSelection() }
            .task(id: photo?.id) { await loadSourcePixels() }
            .task(id: renderKey) { await refreshPreview() }
            .sheet(item: $builtin) { item in
                BuiltinWallpaperView(wallpaper: item) { incoming in
                    var updated = photos
                    let old: MakerPhoto?
                    if updated.indices.contains(current) { old = updated[current]; updated[current] = incoming }
                    else { old = nil; updated.append(incoming) }
                    do {
                        try MakerDraft.save(updated)
                        photos = updated; generated = [:]; presetValue = WallpaperPreset.original.rawValue
                        if let old { try? FileManager.default.removeItem(at: old.url) }
                    } catch {
                        try? FileManager.default.removeItem(at: incoming.url)
                        problem = "保存壁纸失败：\(error.localizedDescription)"
                    }
                }.id(item.id)
            }
            .sheet(isPresented: $adjusting) {
                if let photo { WallpaperAdjustmentView(photo: photo, preset: preset, outputSize: outputSize, detectedSize: model.detectedWallpaperSize, sourceSize: sourcePixels) { adjustment, selectedPreset, size in
                    guard let index = photos.firstIndex(where: { $0.id == photo.id }) else { return }
                    if selectedPreset == .custom { customWidth = Int(size.width); customHeight = Int(size.height) }
                    presetValue = selectedPreset.rawValue
                    photos[index].adjustment = adjustment; generated = [:]; persist()
                } }
            }
            .sheet(isPresented: $applying) {
                if let photo, let entries = generated[photo.id] { NavigationStack { ApplyWallpaperView(entries: entries) } }
            }
    }
    private var cardColor: Color { Color(uiColor: .secondarySystemGroupedBackground) }
    private func step(_ number: String, _ title: String, _ subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.subheadline.bold()).foregroundStyle(CanvasTheme.accent).frame(width: 36, height: 36)
                .background(CanvasTheme.accent.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.title3.bold()); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func initialize() {
        guard !initialized else { return }; initialized = true
        photos = MakerDraft.load()
        if presetValue == "split" { presetValue = WallpaperPreset.original.rawValue }
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-MakerUITestFixture"), let data = UIImage(named: "BrandMark")?.pngData(),
           let fixture = try? MakerDraft.importPhoto(data: data) {
            photos = [fixture]; presetValue = WallpaperPreset.wide.rawValue
        }
        #endif
    }
    private func persist() {
        do { try MakerDraft.save(photos) } catch { problem = "保存照片选择失败：\(error.localizedDescription)" }
    }
    private func removeCurrent() {
        guard photos.indices.contains(current), !locked else { return }
        let old = photos.remove(at: current); current = min(current, max(0, photos.count - 1))
        generated = [:]; persist(); try? FileManager.default.removeItem(at: old.url)
    }
    private func importSelection() async {
        guard !selection.isEmpty else { return }
        loading = true; problem = nil
        var incoming: [MakerPhoto] = []
        do {
            for item in selection {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadCorruptFile) }
                try Task.checkCancellation()
                let imported = try await Task.detached(priority: .userInitiated) { try MakerDraft.importPhoto(data: data) }.value
                incoming.append(imported)
            }
            try Task.checkCancellation()
            let old = photos
            try MakerDraft.save(incoming)
            photos = incoming; current = 0; generated = [:]
            for item in old { try? FileManager.default.removeItem(at: item.url) }
        } catch {
            for item in incoming { try? FileManager.default.removeItem(at: item.url) }
            if !(error is CancellationError) { problem = "导入失败：\(error.localizedDescription)" }
        }
        loading = false
    }
    private func loadSourcePixels() async {
        guard let url = photo?.url else { sourcePixels = nil; return }
        sourcePixels = nil
        let pixels = try? await Task.detached { try WallpaperRenderer.pixelSize(url) }.value
        if !Task.isCancelled { sourcePixels = pixels }
    }
    private func refreshPreview() async {
        guard let photo else { preview = nil; return }
        previewing = true
        let selectedPreset = preset, size = outputSize
        do {
            try await Task.sleep(nanoseconds: 120_000_000)
            let result = try await Task.detached(priority: .userInitiated) {
                try autoreleasepool { try WallpaperRenderer.render(url: photo.url, preset: selectedPreset, size: size, adjustment: photo.adjustment) }
            }.value
            try Task.checkCancellation(); preview = result; previewing = false
        } catch { if !Task.isCancelled { preview = nil; previewing = false; problem = "预览失败：\(error.localizedDescription)" } }
    }
    private func generate() {
        problem = nil
        let snapshot = photos
        model.generatePhotos(snapshot, preset: preset, size: outputSize) { batches in
            generated = Dictionary(uniqueKeysWithValues: zip(snapshot, batches).map { ($0.0.id, $0.1) })
            if batches.isEmpty { problem = model.message }
        }
    }
}

private struct MakerThumbnail: View {
    let url: URL
    @State private var image: UIImage?
    var body: some View {
        Group { if let image { Image(uiImage: image).resizable().scaledToFill() } else { Color(uiColor: .tertiarySystemFill) } }
            .task(id: url) { image = await Task.detached { try? WallpaperRenderer.load(url, maximum: 160) }.value }
    }
}
