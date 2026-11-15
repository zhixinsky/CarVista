// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct WallpaperAdjustmentView: View {
    @Environment(\.dismiss) private var dismiss
    let photo: MakerPhoto
    let preset: WallpaperPreset
    let outputSize: CGSize
    let save: (WallpaperAdjustment) -> Void
    @State private var adjustment: WallpaperAdjustment
    @State private var preview: UIImage?
    @State private var source: UIImage?
    @State private var error: String?
    @State private var dragOrigin: CGPoint?
    @State private var pinchOrigin: Double?
    init(photo: MakerPhoto, preset: WallpaperPreset, outputSize: CGSize, save: @escaping (WallpaperAdjustment) -> Void) {
        self.photo = photo; self.preset = preset; self.outputSize = outputSize; self.save = save
        _adjustment = State(initialValue: photo.adjustment)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Text(outputSize.width > 0 ? "\(preset.title) · \(Int(outputSize.width)) × \(Int(outputSize.height))" : "\(preset.title) · 读取原图尺寸…").foregroundStyle(.secondary)
                    GeometryReader { proxy in
                        Group {
                            if let preview { Image(uiImage: preview).resizable().scaledToFit() }
                            else { ProgressView("正在准备预览…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                        }.frame(width: proxy.size.width, height: proxy.size.height).clipped().contentShape(Rectangle())
                            .gesture(DragGesture().onChanged { value in
                                guard preset.crops, let source else { return }
                                if dragOrigin == nil { dragOrigin = CGPoint(x: adjustment.x, y: adjustment.y) }
                                let rotatedSize = adjustment.turns % 2 == 0 ? source.size : CGSize(width: source.size.height, height: source.size.width)
                                let rect = CropGeometry.rect(source: rotatedSize, target: proxy.size, zoom: adjustment.zoom, x: adjustment.x, y: adjustment.y)
                                let start = dragOrigin ?? CGPoint(x: 0.5, y: 0.5)
                                if rect.width > proxy.size.width + 1 { adjustment.x = min(1, max(0, start.x - value.translation.width / (rect.width - proxy.size.width))) }
                                if rect.height > proxy.size.height + 1 { adjustment.y = min(1, max(0, start.y - value.translation.height / (rect.height - proxy.size.height))) }
                            }.onEnded { _ in dragOrigin = nil })
                            .simultaneousGesture(MagnificationGesture().onChanged { scale in
                                guard preset.crops else { return }
                                if pinchOrigin == nil { pinchOrigin = adjustment.zoom }
                                adjustment.zoom = min(4, max(1, (pinchOrigin ?? 1) * Double(scale)))
                            }.onEnded { _ in pinchOrigin = nil })
                    }.aspectRatio(outputSize.width > 0 && outputSize.height > 0 ? outputSize.width / outputSize.height : 16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 18)).accessibilityIdentifier("maker.adjust.preview")
                    if preset.crops {
                        Text("拖动移动位置，双指或滑杆调整大小。").font(.subheadline).foregroundStyle(.secondary)
                        HStack { Image(systemName: "minus.magnifyingglass"); Slider(value: $adjustment.zoom, in: 1...4); Image(systemName: "plus.magnifyingglass") }
                    } else if preset.preservesSourceSize {
                        Text("按原始像素输出，不缩放。旋转和翻转会改变宽高。").font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Text("照片始终完整居中，模糊延伸会自动填满空余区域。").font(.subheadline).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button { adjustment.turns = (adjustment.turns + 1) % 4 } label: { Label("旋转", systemImage: "rotate.right") }
                        Button { adjustment.flipX.toggle() } label: { Text("左右翻转") }
                        Button { adjustment.flipY.toggle() } label: { Text("上下翻转") }
                    }.buttonStyle(.bordered).font(.subheadline)
                    HStack {
                        Button("还原") { adjustment = .init() }.buttonStyle(.bordered).frame(maxWidth: .infinity)
                        Button("确定") { save(adjustment); dismiss() }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                }.padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity)
            }.navigationTitle("调整壁纸").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("取消") { dismiss() } }
                .task { source = await Task.detached { try? WallpaperRenderer.load(photo.url, maximum: 512) }.value }
                .task(id: String(describing: adjustment)) {
                    let snapshot = adjustment
                    do {
                        try await Task.sleep(nanoseconds: 120_000_000)
                        let rendered = try await Task.detached(priority: .userInitiated) {
                            try autoreleasepool { try WallpaperRenderer.render(url: photo.url, preset: preset, size: outputSize, adjustment: snapshot) }
                        }.value
                        try Task.checkCancellation(); preview = rendered; error = nil
                    } catch { if !Task.isCancelled { self.error = "预览失败：\(error.localizedDescription)" } }
                }
        }.tint(CanvasTheme.accent)
    }
}
