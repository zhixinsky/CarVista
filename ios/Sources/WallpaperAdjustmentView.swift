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
    @State private var showingSizes = false
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
            GeometryReader { geometry in
                let landscape = geometry.size.width > geometry.size.height
                VStack(spacing: 8) {
                    GeometryReader { canvas in
                        let aspect = outputSize == .zero ? 16.0 / 9 : outputSize.width / outputSize.height
                        let width = min(canvas.size.width, canvas.size.height * aspect)
                        let height = width / aspect
                        cropPreview(size: CGSize(width: width, height: height))
                            .frame(width: width, height: height)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                    controls(landscape: landscape)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .navigationTitle("调整壁纸")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确定") { save(adjustment, preset, outputSize); dismiss() }
                        .disabled(outputSize == .zero || source == nil)
                }
            }
            .sheet(isPresented: $showingSizes) { sizePicker }
            .task {
                source = await Task.detached { try? WallpaperRenderer.load(photo.url, maximum: 2400) }.value
                if source == nil { error = "无法读取原图预览。" }
            }
            .task(id: "\(source != nil)-\(preset.rawValue)-\(outputSize)-\(adjustment.turns)-\(adjustment.flipX)-\(adjustment.flipY)") {
                guard !preset.crops, let source, outputSize != .zero else { return }
                let snapshot = adjustment
                let selected = preset
                let ratio = min(1, 1200 / max(outputSize.width, outputSize.height))
                let size = CGSize(width: max(1, outputSize.width * ratio), height: max(1, outputSize.height * ratio))
                let rendered = await Task.detached {
                    try? WallpaperRenderer.render(image: source, preset: selected, size: size, adjustment: snapshot)
                }.value
                if !Task.isCancelled { preview = rendered }
            }
        }.tint(CanvasTheme.accent)
    }

    private func cropPreview(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Color(uiColor: .secondarySystemGroupedBackground)
            if preset.crops, let source, size.width > 0, size.height > 0 {
                let rect = cropRect(source: source, size: size)
                Image(uiImage: source).resizable()
                    .frame(width: adjustment.turns % 2 == 0 ? rect.width : rect.height,
                           height: adjustment.turns % 2 == 0 ? rect.height : rect.width)
                    .rotationEffect(.degrees(Double(adjustment.turns) * 90))
                    .scaleEffect(x: adjustment.flipX ? -1 : 1, y: adjustment.flipY ? -1 : 1)
                    .position(x: rect.midX, y: rect.midY)
                Path { path in
                    for third in 1...2 {
                        let x = size.width * CGFloat(third) / 3
                        let y = size.height * CGFloat(third) / 3
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                    }
                }.stroke(.white.opacity(0.55), lineWidth: 1).allowsHitTesting(false)
            } else if let preview {
                Image(uiImage: preview).resizable().scaledToFit()
                    .frame(width: size.width, height: size.height)
            } else if error == nil {
                ProgressView().frame(width: size.width, height: size.height)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .contentShape(Rectangle())
        .gesture(DragGesture().onChanged { value in
            guard preset.crops, let source else { return }
            if dragOrigin == nil { dragOrigin = CGPoint(x: adjustment.x, y: adjustment.y) }
            guard let origin = dragOrigin else { return }
            let rect = cropRect(source: source, size: size)
            if rect.width > size.width + 0.01 {
                adjustment.x = min(1, max(0, origin.x - value.translation.width / (rect.width - size.width)))
            }
            if rect.height > size.height + 0.01 {
                adjustment.y = min(1, max(0, origin.y - value.translation.height / (rect.height - size.height)))
            }
        }.onEnded { _ in dragOrigin = nil })
        .simultaneousGesture(MagnificationGesture().onChanged { scale in
            guard preset.crops else { return }
            if pinchOrigin == nil { pinchOrigin = adjustment.zoom }
            adjustment.zoom = min(4, max(1, (pinchOrigin ?? 1) * Double(scale)))
        }.onEnded { _ in pinchOrigin = nil })
        .accessibilityIdentifier("maker.adjust.preview")
    }

    private func cropRect(source: UIImage, size: CGSize) -> CGRect {
        let rotated = adjustment.turns % 2 == 0 ? source.size : CGSize(width: source.size.height, height: source.size.width)
        return CropGeometry.rect(source: rotated, target: size, zoom: adjustment.zoom, x: adjustment.x, y: adjustment.y)
    }

    private func controls(landscape: Bool) -> some View {
        VStack(spacing: 6) {
            HStack {
                Button { showingSizes = true } label: {
                    Label(preset.title, systemImage: "rectangle.expand.vertical")
                }.accessibilityIdentifier("maker.presets")
                if outputSize != .zero {
                    Text("\(Int(outputSize.width)) × \(Int(outputSize.height))").monospacedDigit()
                }
                Spacer()
                if !preset.crops {
                    Button("自由裁剪") {
                        if outputSize.width <= 8192, outputSize.height <= 8192,
                           outputSize.width * outputSize.height <= 33_554_432, outputSize != .zero {
                            widthText = String(Int(outputSize.width))
                            heightText = String(Int(outputSize.height))
                        }
                        preset = .custom
                        if outputSize == .zero { showingSizes = true }
                    }
                }
            }.font(.subheadline)
            HStack {
                Text("缩放")
                Slider(value: $adjustment.zoom, in: 1...4).accessibilityLabel("缩放")
                Text(String(format: "%.2f×", adjustment.zoom)).monospacedDigit()
            }.font(.subheadline).disabled(!preset.crops || source == nil)
            HStack {
                Button("旋转") { adjustment.turns = (adjustment.turns + 1) % 4 }
                Button("左右翻转") { adjustment.flipX.toggle() }
                Button("上下翻转") { adjustment.flipY.toggle() }
                Spacer()
                Button("还原") { adjustment = .init() }
            }.font(.subheadline)
            if !landscape { Text("横放手机查看大图 · 拖动取景，双指缩放").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var sizePicker: some View {
        NavigationStack {
            Form {
                Picker("快速尺寸", selection: $preset) {
                    ForEach(WallpaperPreset.allCases) { option in Text(option.title).tag(option) }
                }
                if preset == .custom {
                    TextField("宽度（像素）", text: $widthText).keyboardType(.numberPad)
                    TextField("高度（像素）", text: $heightText).keyboardType(.numberPad)
                    if outputSize == .zero {
                        Text("宽高须为 1–8192 像素，总像素数不超过 33554432。").foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("输出尺寸")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { showingSizes = false }.disabled(outputSize == .zero) }
        }
    }
}
