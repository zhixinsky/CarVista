// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import PhotosUI

struct ComposeWallpaperView: View {
    @EnvironmentObject var model: WorkshopModel
    @Binding var galleryImport: GalleryImport?
    private let openTool: ((WallpaperRoute) -> Void)?
    @State private var tool: WallpaperRoute?
    @State private var photos: [MakerPhoto] = []
    @State private var selection: PhotosPickerItem?
    @State private var current = 0
    @State private var loading = false
    @State private var adjusting = false
    @State private var cropOrientation = CropOrientationSession()
    @State private var applying = false
    @State private var problem: String?
    @State private var generated: [UUID: [SavedWallpaper]] = [:]
    @State private var preview: UIImage?
    @State private var previewing = false
    @State private var initialized = false
    @State private var sourcePixels: CGSize?
    private var photo: MakerPhoto? { photos.indices.contains(current) ? photos[current] : nil }
    private var outputSize: CGSize {
        if let crop = photo?.adjustment.pixelCrop { return crop.rect.size }
        guard let sourcePixels, sourcePixels.width > 0, sourcePixels.height > 0 else { return .zero }
        let turns = (((photo?.adjustment.turns ?? 0) % 4) + 4) % 4
        return turns % 2 == 0 ? sourcePixels : CGSize(width: sourcePixels.height, height: sourcePixels.width)
    }
    init(galleryImport: Binding<GalleryImport?> = .constant(nil), openTool: ((WallpaperRoute) -> Void)? = nil) {
        _galleryImport = galleryImport
        self.openTool = openTool
    }
    private var outputLabel: String {
        guard outputSize.width > 0, outputSize.height > 0 else { return "读取原图尺寸…" }
        return "\(Int(outputSize.width)) × \(Int(outputSize.height))"
    }
    private var locked: Bool { loading || model.busy }
    private var renderKey: String { "\(photo?.id.uuidString ?? "empty")-\(String(describing: photo?.adjustment))-\(outputLabel)" }

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
                        Text("已选 \(photos.count) 张").font(.subheadline.bold())
                        Spacer()
                        Text("输出 \(outputLabel)").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("maker.output")
                    }
                    HStack(spacing: 10) {
                        PhotosPicker(selection: $selection, matching: .images) {
                            Label(photos.isEmpty ? "选择照片" : "更换照片", systemImage: "photo.badge.plus").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).disabled(locked).accessibilityIdentifier("maker.select")
                        Button("调整") { adjusting = true }.buttonStyle(.bordered).disabled(photo == nil || locked)
                            .accessibilityIdentifier("maker.adjust")
                        Button(role: .destructive) { removeCurrent() } label: { Image(systemName: "trash") }
                            .buttonStyle(.bordered).disabled(photo == nil || locked).accessibilityLabel("移除当前照片")
                    }
                    if loading { ProgressView("正在导入照片…") }
                    Button { prepareCurrentWallpaper() } label: {
                        Label("应用当前照片", systemImage: "car.side.fill").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).disabled(photo == nil || locked)
                    if let problem { Text(problem).font(.subheadline).foregroundStyle(.red) }
                }.padding(16).frame(maxWidth: .infinity)
                    .background(cardColor, in: RoundedRectangle(cornerRadius: 24))

                VStack(alignment: .leading, spacing: 12) {
                    Text("内置壁纸（别克大连屏专用）").font(.headline)
                    Text("点选后可直接应用当前照片。").font(.caption).foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(BuiltinWallpaper.all) { item in
                                Button { selectBuiltin(item) } label: {
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
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(cardColor, in: RoundedRectangle(cornerRadius: 24))
                VStack(alignment: .leading, spacing: 16) {
                    Text("CarPlay").font(.headline)
                    Label(model.group.isEmpty ? "本地制作可用，车机访问需有效签名" : "签名组已提供", systemImage: "checkmark.shield")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button("检测车机壁纸") { model.scan(deep: false) }.disabled(locked || model.group.isEmpty)
                    if !model.targets.isEmpty { Text("已找到 \(model.targets.count) 个缓存文件").font(.caption).foregroundStyle(.secondary) }
                    if model.busy { ProgressView("正在处理…") }
                    WallpaperRefreshButton()
                    Text(model.message).font(.caption).foregroundStyle(.secondary)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(cardColor, in: RoundedRectangle(cornerRadius: 24))
            }.padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }.background(Color(uiColor: .systemGroupedBackground)).tint(CanvasTheme.accent)
            .navigationTitle("壁纸").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { showTool(.history) } label: { Label("历史记录", systemImage: "clock") }
                        Button { showTool(.cache) } label: { Label("壁纸缓存", systemImage: "folder") }
                        Button { generate() } label: { Label("仅生成壁纸文件", systemImage: "square.and.arrow.down") }
                            .disabled(photos.isEmpty || locked)
                    } label: {
                        Label("壁纸工具", systemImage: "ellipsis.circle")
                    }.accessibilityIdentifier("wallpaper.tools")
                }
            }
            .navigationDestination(item: $tool) { destination in
                switch destination {
                case .history: CanvasHistoryView()
                case .cache: CacheBrowserView()
                }
            }
            .onAppear { initialize() }
            .task(id: galleryImport?.id) { await importGallerySelection() }
            .task(id: selection) { await importSelection() }
            .task(id: photo?.id) { await loadSourcePixels() }
            .task(id: renderKey) { await refreshPreview() }
            .fullScreenCover(isPresented: $adjusting, onDismiss: { cropOrientation.restore() }) {
                if let photo { WallpaperAdjustmentView(photo: photo) { crop in
                    guard let index = photos.firstIndex(where: { $0.id == photo.id }) else { return }
                    photos[index].adjustment = WallpaperAdjustment(pixelCrop: crop); generated = [:]; persist()
                }.modifier(CropLandscapeLayout(session: cropOrientation)) }
            }
            .sheet(isPresented: $applying) {
                if let photo, let entries = generated[photo.id] { NavigationStack { ApplyWallpaperView(entries: entries) } }
            }
    }
    private func showTool(_ destination: WallpaperRoute) {
        if let openTool { openTool(destination) } else { tool = destination }
    }

    private func importGallerySelection() async {
        guard let request = galleryImport else { return }
        while locked {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
        loading = true
        problem = nil
        defer {
            loading = false
            if !Task.isCancelled, galleryImport?.id == request.id { galleryImport = nil }
        }
        do {
            let incoming = try await Task.detached { try MakerDraft.importPhoto(data: request.data) }.value
            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: incoming.url)
                return
            }
            try replaceCurrent(with: incoming)
        } catch {
            problem = "导入图库照片失败：\(error.localizedDescription)"
        }
    }
    private func selectBuiltin(_ wallpaper: BuiltinWallpaper) {
        guard !locked else { return }
        loading = true
        problem = nil
        Task {
            defer { loading = false }
            do {
                let incoming = try await Task.detached {
                    try MakerDraft.importPhoto(data: Data(contentsOf: wallpaper.originalURL()))
                }.value
                try replaceCurrent(with: incoming)
            } catch {
                problem = "导入内置壁纸失败：\(error.localizedDescription)"
            }
        }
    }

    private func replaceCurrent(with incoming: MakerPhoto) throws {
        var updated = photos
        let old = photo
        if old == nil { updated.append(incoming) } else { updated[current] = incoming }
        do {
            try MakerDraft.save(updated)
        } catch {
            try? FileManager.default.removeItem(at: incoming.url)
            throw error
        }
        photos = updated
        if let old {
            generated[old.id] = nil
            try? FileManager.default.removeItem(at: old.url)
        }
    }

    private func prepareCurrentWallpaper() {
        guard let photo, !locked else { return }
        if generated[photo.id] != nil {
            applying = true
            return
        }
        problem = nil
        model.generatePhotos([photo], preset: .original, size: outputSize) { batches in
            guard let entries = batches.first, !entries.isEmpty else {
                problem = model.message
                return
            }
            generated[photo.id] = entries
            applying = true
        }
    }
    private var cardColor: Color { Color(uiColor: .secondarySystemGroupedBackground) }
    private func initialize() {
        guard !initialized else { return }; initialized = true
        photos = MakerDraft.load()
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-MakerUITestFixture"), let data = UIImage(named: "BrandMark")?.pngData(),
           let fixture = try? MakerDraft.importPhoto(data: data) {
            photos = [fixture]
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
        guard let item = selection, !locked else { return }
        loading = true
        problem = nil
        defer { loading = false; selection = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadCorruptFile) }
            try Task.checkCancellation()
            let incoming = try await Task.detached(priority: .userInitiated) { try MakerDraft.importPhoto(data: data) }.value
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: incoming.url)
                return
            }
            try replaceCurrent(with: incoming)
        } catch {
            if !(error is CancellationError) { problem = "导入失败：\(error.localizedDescription)" }
        }
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
        let size = outputSize
        do {
            try await Task.sleep(nanoseconds: 120_000_000)
            let result = try await Task.detached(priority: .userInitiated) {
                try autoreleasepool { try WallpaperRenderer.render(url: photo.url, preset: .original, size: size, adjustment: photo.adjustment) }
            }.value
            try Task.checkCancellation(); preview = result; previewing = false
        } catch { if !Task.isCancelled { preview = nil; previewing = false; problem = "预览失败：\(error.localizedDescription)" } }
    }
    private func generate() {
        problem = nil
        let snapshot = photos
        model.generatePhotos(snapshot, preset: .original, size: outputSize) { batches in
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
