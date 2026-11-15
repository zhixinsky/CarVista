// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct BuiltinWallpaper: Identifiable {
    let id: String
    let title: String
    static let all = ["浅海人鱼", "晴日海滩", "夜色海滩", "金马山川", "深海人鱼"].enumerated().map {
        BuiltinWallpaper(id: "Builtin\($0.offset)", title: $0.element)
    }
    static func cropRight(_ image: UIImage, start: Int) throws -> UIImage {
        guard let cg = image.cgImage, start >= 0, start < cg.width,
              let cropped = cg.cropping(to: CGRect(x: start, y: 0, width: cg.width - start, height: cg.height)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return UIImage(cgImage: cropped, scale: 1, orientation: .up)
    }
}

struct BuiltinWallpaperView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("LMBuiltinSplitPixel") private var savedStart = 3004
    let wallpaper: BuiltinWallpaper
    let use: (MakerPhoto) -> Void
    @State private var start = 3004.0
    @State private var image: UIImage?
    @State private var busy = false
    @State private var error: String?
    private var width: Int { image?.cgImage?.width ?? 6008 }
    private var height: Int { image?.cgImage?.height ?? 934 }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("拖动分界线，保留右侧画面").font(.headline)
                    Text("左侧阴影不会导出。初始位置为中点，请按实际 CarPlay 边界调整；确定后记住位置供其他内置壁纸使用。").font(.subheadline).foregroundStyle(.secondary)
                    if let image {
                        GeometryReader { geometry in
                            let x = geometry.size.width * start / Double(width)
                            ZStack(alignment: .leading) {
                                Image(uiImage: image).resizable().scaledToFit()
                                Rectangle().fill(.black.opacity(0.55)).frame(width: x)
                                Rectangle().fill(.white).frame(width: 3).offset(x: x - 1.5)
                            }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { value in
                                start = min(Double(width - 1), max(0, (value.location.x / geometry.size.width * Double(width)).rounded()))
                            })
                        }.aspectRatio(CGFloat(width) / CGFloat(height), contentMode: .fit)
                        Slider(value: $start, in: 0...Double(width - 1), step: 1).accessibilityLabel("右侧壁纸起点")
                        Stepper("起点：\(Int(start)) 像素", value: $start, in: 0...Double(width - 1), step: 1)
                        Text("输出：\(width - Int(start)) × \(height) · 原始像素").font(.subheadline.bold())
                        Button("使用右侧壁纸") { importCrop() }
                            .buttonStyle(.borderedProminent).disabled(busy).accessibilityIdentifier("builtin.use")
                    } else { ProgressView() }
                    if busy { ProgressView("正在保存…") }
                    if let error { Text(error).foregroundStyle(.red) }
                }.padding(20)
            }.navigationTitle(wallpaper.title).navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("取消") { dismiss() }.disabled(busy) }
                .interactiveDismissDisabled(busy)
                .task {
                    image = UIImage(named: wallpaper.id)
                    if image == nil { error = "内置壁纸读取失败" }
                    start = Double(min(width - 1, max(0, savedStart)))
                }
        }.tint(CanvasTheme.accent)
    }
    private func importCrop() {
        guard let image, !busy else { return }
        busy = true; error = nil
        let pixel = Int(start)
        Task {
            do {
                let photo = try await Task.detached(priority: .userInitiated) {
                    let crop = try BuiltinWallpaper.cropRight(image, start: pixel)
                    guard let data = crop.pngData() else { throw CocoaError(.fileWriteUnknown) }
                    return try MakerDraft.importPhoto(data: data)
                }.value
                savedStart = pixel; use(photo); dismiss()
            } catch { self.error = "保存失败：\(error.localizedDescription)" }
            busy = false
        }
    }
}
