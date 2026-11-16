// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct BuiltinWallpaper: Identifiable {
    let id: String
    let title: String
    var previewName: String { "\(id)Preview" }
    var previewImage: UIImage? { UIImage(named: previewName) ?? UIImage(named: id) }
    static let all = ["浅海人鱼", "晴日海滩", "夜色海滩", "金马山川", "深海人鱼"].enumerated().map {
        BuiltinWallpaper(id: "Builtin\($0.offset)", title: $0.element)
    }
    static func cropRight(_ image: UIImage, start: Int, bottomInset: Int = 0) throws -> UIImage {
        guard let cg = image.cgImage, start >= 0, start < cg.width,
              bottomInset >= 0, bottomInset < cg.height,
              let cropped = cg.cropping(to: CGRect(x: start, y: 0, width: cg.width - start, height: cg.height - bottomInset)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return UIImage(cgImage: cropped, scale: 1, orientation: .up)
    }
}

struct BuiltinWallpaperPreview: View {
    let wallpaper: BuiltinWallpaper

    var body: some View {
        if let image = wallpaper.previewImage {
            Image(uiImage: image).resizable().scaledToFit()
        } else {
            Label("预览不可用", systemImage: "photo")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct BuiltinWallpaperView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("LMBuiltinSplitPixel") private var savedStart = 3004
    @AppStorage("LMBuiltinBottomInset") private var savedBottomInset = 0
    let wallpaper: BuiltinWallpaper
    let use: (MakerPhoto) -> Void
    @State private var start = 3004.0
    @State private var bottomInset = 0.0
    @State private var busy = false
    @State private var error: String?
    private let width = 6008
    private let height = 934
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("对齐 CarPlay 的左边和底边").font(.headline)
                    Text("阴影区域不会导出。拖动图片可调整左边界，下方滑杆可排除车机底栏。确认后会记住两处设置。").font(.subheadline).foregroundStyle(.secondary)
                    Group {
                        GeometryReader { geometry in
                            let x = geometry.size.width * start / Double(width)
                            let y = geometry.size.height * (1 - bottomInset / Double(height))
                            ZStack(alignment: .topLeading) {
                                BuiltinWallpaperPreview(wallpaper: wallpaper)
                                    .frame(width: geometry.size.width, height: geometry.size.height)
                                Rectangle().fill(.black.opacity(0.55)).frame(width: x, height: y)
                                Rectangle().fill(.black.opacity(0.55)).frame(height: geometry.size.height - y).offset(y: y)
                                Rectangle().fill(.white).frame(width: 2, height: y).offset(x: x - 1)
                                if bottomInset > 0 {
                                    Rectangle().fill(.white).frame(height: 2).offset(y: y - 1)
                                }
                            }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { value in
                                start = min(Double(width - 1), max(0, (value.location.x / geometry.size.width * Double(width)).rounded()))
                            })
                        }.aspectRatio(CGFloat(width) / CGFloat(height), contentMode: .fit)
                        Slider(value: $start, in: 0...Double(width - 1), step: 1).accessibilityLabel("右侧壁纸起点")
                        Stepper("起点：\(Int(start)) 像素", value: $start, in: 0...Double(width - 1), step: 1)
                        Slider(value: $bottomInset, in: 0...Double(height - 1), step: 1).accessibilityLabel("车机底栏高度")
                        Stepper("排除底部：\(Int(bottomInset)) 像素", value: $bottomInset, in: 0...Double(height - 1), step: 1)
                        Text("输出：\(width - Int(start)) × \(height - Int(bottomInset)) · 原始像素").font(.subheadline.bold())
                        Button("使用裁剪后的壁纸") { importCrop() }
                            .buttonStyle(.borderedProminent).disabled(busy).accessibilityIdentifier("builtin.use")
                    }.disabled(busy)
                    if busy { ProgressView("正在保存…") }
                    if let error { Text(error).foregroundStyle(.red) }
                }.padding(20)
            }.navigationTitle(wallpaper.title).navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("取消") { dismiss() }.disabled(busy) }
                .interactiveDismissDisabled(busy)
                .task {
                    start = Double(min(width - 1, max(0, savedStart)))
                    bottomInset = Double(min(height - 1, max(0, savedBottomInset)))
                }
        }.tint(CanvasTheme.accent)
    }
    private func importCrop() {
        guard !busy else { return }
        busy = true; error = nil
        let pixel = Int(start)
        let bottom = Int(bottomInset)
        let assetName = wallpaper.id
        Task {
            do {
                let photo = try await Task.detached(priority: .userInitiated) {
                    guard let image = UIImage(named: assetName) else { throw CocoaError(.fileReadNoSuchFile) }
                    let crop = try BuiltinWallpaper.cropRight(image, start: pixel, bottomInset: bottom)
                    guard let data = crop.pngData() else { throw CocoaError(.fileWriteUnknown) }
                    return try MakerDraft.importPhoto(data: data)
                }.value
                savedStart = pixel
                savedBottomInset = bottom
                use(photo); dismiss()
            } catch { self.error = "保存失败：\(error.localizedDescription)" }
            busy = false
        }
    }
}
