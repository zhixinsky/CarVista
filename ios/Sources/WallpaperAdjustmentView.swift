// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct WallpaperAdjustmentView: View {
    @Environment(\.dismiss) private var dismiss
    let photo: MakerPhoto
    let detectedSize: CGSize?
    let sourceSize: CGSize?
    let save: (WallpaperAdjustment, WallpaperPreset, CGSize) -> Void
    @State private var preset: WallpaperPreset
    @State private var widthText: String
    @State private var heightText: String
    private var outputSize: CGSize {
        if preset == .custom {
            guard let w = Int(widthText), let h = Int(heightText),
                  (1...8192).contains(w), (1...8192).contains(h), w * h <= 33_554_432 else { return .zero }
            return CGSize(width: w, height: h)
        }
        let pixels = sourceSize ?? source?.size
        let rotated = pixels.map { adjustment.turns % 2 == 0 ? $0 : CGSize(width: $0.height, height: $0.width) }
        return preset.size(detected: detectedSize, source: rotated)
    }
    @State private var adjustment: WallpaperAdjustment
    @State private var preview: UIImage?
    @State private var source: UIImage?
    @State private var error: String?
    @State private var dragOrigin: CGPoint?
    @State private var pinchOrigin: Double?
    init(photo: MakerPhoto, preset: WallpaperPreset, outputSize: CGSize, detectedSize: CGSize?, sourceSize: CGSize?, save: @escaping (WallpaperAdjustment, WallpaperPreset, CGSize) -> Void) {
        self.photo = photo; self.detectedSize = detectedSize; self.sourceSize = sourceSize; self.save = save
        _preset = State(initialValue: preset)
        _widthText = State(initialValue: String(Int(outputSize.width > 0 ? outputSize.width : 1920)))
        _heightText = State(initialValue: String(Int(outputSize.height > 0 ? outputSize.height : 810)))
        _adjustment = State(initialValue: photo.adjustment)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Picker("快速尺寸", selection: $preset) {
                        ForEach(WallpaperPreset.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }.pickerStyle(.menu).accessibilityIdentifier("maker.presets")
                    if preset == .custom {
                        HStack {
                            TextField("宽度（像素）", text: $widthText).accessibilityLabel("宽度（像素）")
                            Text("×")
                            TextField("高度（像素）", text: $heightText).accessibilityLabel("高度（像素）")
                        }.keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                        if outputSize == .zero {
                            Text("宽高须为 1–8192 像素，总像素数不超过 33554432。").font(.caption).foregroundStyle(.red)
                        }
                    }
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
                        Button("确定") { save(adjustment, preset, outputSize); dismiss() }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                            .disabled(preset == .custom && outputSize == .zero)
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                }.padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity)
            }.navigationTitle("调整壁纸").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("取消") { dismiss() } }
                .task {
                    source = await Task.detached { try? WallpaperRenderer.load(photo.url, maximum: 1200) }.value
                    if source == nil { error = "无法读取原图预览。" }
                }
                .task(id: "\(source != nil)-\(preset.rawValue)-\(outputSize)-\(adjustment)") {
                    guard let source, outputSize.width > 0, outputSize.height > 0 else { preview = nil; return }
                    let snapshot = adjustment
                    let selected = preset
                    let ratio = min(1, 900 / max(outputSize.width, outputSize.height))
                    let size = CGSize(width: max(1, outputSize.width * ratio), height: max(1, outputSize.height * ratio))
                    do {
                        try await Task.sleep(nanoseconds: 120_000_000)
                        let rendered = try await Task.detached(priority: .userInitiated) {
                            try autoreleasepool { try WallpaperRenderer.render(image: source, preset: selected, size: size, adjustment: snapshot) }
                        }.value
                        try Task.checkCancellation(); preview = rendered; error = nil
                    } catch { if !Task.isCancelled { self.error = "预览失败：\(error.localizedDescription)" } }
                }
        }.tint(CanvasTheme.accent)
    }
}
