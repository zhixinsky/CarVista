// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct WallpaperAdjustmentView: View {
    private enum Ratio: String, CaseIterable {
        case free = "自由", wide = "16:9", portrait = "3:4", buick = "3.65:1（别克）"

        var units: (width: Int, height: Int)? {
            switch self {
            case .free: return nil
            case .wide: return (16, 9)
            case .portrait: return (3, 4)
            case .buick: return (73, 20)
            }
        }
    }

    private enum Edge: String, CaseIterable {
        case left = "左边", right = "右边", top = "上边", bottom = "下边"
        var vertical: Bool { self == .left || self == .right }
        var coordinate: WritableKeyPath<WallpaperPixelCrop, Int> {
            switch self {
            case .left: return \.left
            case .right: return \.right
            case .top: return \.top
            case .bottom: return \.bottom
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    let photo: MakerPhoto
    let save: (WallpaperPixelCrop) -> Void
    @State private var preview: UIImage?
    @State private var pixels = CGSize.zero
    @State private var crop: WallpaperPixelCrop?
    @State private var selected: Edge = .left
    @State private var dragStart: Int?
    @State private var failed = false
    @State private var zoom = 1.0
    @State private var center = CGPoint(x: 0.5, y: 0.5)
    @State private var panStart: CGPoint?
    @State private var cropLocked = false
    @State private var ratio: Ratio = .free
    @State private var showsRatios = false
    @State private var frameDragStart: WallpaperPixelCrop?
    @State private var showsFineControls = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                GeometryReader { geometry in
                    if let preview, let crop {
                        viewport(preview, crop: crop, viewportSize: geometry.size)
                    } else if failed {
                        Text("无法读取原图").frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                if let crop {
                    HStack {
                        Button {
                            cropLocked.toggle()
                            panStart = nil
                            dragStart = nil
                            frameDragStart = nil
                        } label: {
                            Label(cropLocked ? "已锁定 · 解锁" : "锁定裁剪",
                                  systemImage: cropLocked ? "lock.fill" : "lock.open")
                        }
                        .buttonStyle(.bordered)
                        .tint(cropLocked ? .orange : CanvasTheme.accent)
                        .fixedSize()
                        Slider(value: $zoom, in: 1...6).accessibilityLabel("预览缩放")
                        Button("全图") { zoom = 1 }.disabled(zoom == 1)
                    }.font(.subheadline)
                    if showsFineControls {
                    HStack(spacing: 6) {
                        Picker("微调边线", selection: Binding(get: { selected }, set: { edge in
                            selected = edge
                            if zoom > 1 { focusSelectedEdge() }
                        })) {
                            ForEach(Edge.allCases, id: \.self) { edge in Text(edge.rawValue).tag(edge) }
                        }.pickerStyle(.segmented)
                        triangle(-1)
                        triangle(1)
                        if zoom > 1 {
                            Button { withAnimation(.easeInOut(duration: 0.2)) { focusSelectedEdge() } } label: {
                                Label("定位边线", systemImage: "scope").labelStyle(.iconOnly)
                                    .frame(width: 44, height: 44)
                            }.buttonStyle(.borderless).accessibilityLabel("定位选中边线")
                        }
                    }
                    }
                    HStack {
                        Text("\(Int(crop.rect.width)) × \(Int(crop.rect.height)) 像素 · \(gestureHint)")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        Spacer()
                        Button { showsFineControls.toggle() } label: {
                            Label(showsFineControls ? "收起微调" : "逐像素微调", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                                .font(.subheadline.weight(.semibold))
                                .frame(minHeight: 34)
                        }
                        .buttonStyle(.borderedProminent)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            .padding(12)
            .overlay(alignment: .topTrailing) {
                if showsRatios { ratioOverlay }
            }
            .navigationTitle("自由裁剪")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button { showsRatios.toggle() } label: {
                        Label(ratio == .free ? "比例" : ratio.rawValue, systemImage: "aspectratio")
                    }.disabled(crop == nil || cropLocked).accessibilityIdentifier("crop.ratio")
                    Button("还原") { showsRatios = false; ratio = .free; crop = .full(pixels); zoom = 1 }.disabled(crop == nil || cropLocked)
                    Button("确定") {
                        guard let crop else { return }
                        save(crop)
                        dismiss()
                    }.disabled(crop == nil)
                }
            }
            .onChange(of: zoom) { previous, current in
                if current == 1 {
                    center = CGPoint(x: 0.5, y: 0.5)
                } else if previous == 1 {
                    focusSelectedEdge()
                }
            }
            .task {
                do {
                    let url = photo.url
                    let (image, size) = try await Task.detached {
                        (try WallpaperRenderer.load(url, maximum: 4096), try WallpaperRenderer.pixelSize(url))
                    }.value
                    try Task.checkCancellation()
                    pixels = size
                    crop = photo.adjustment.pixelCrop.flatMap { $0.fits(size) ? $0 : nil } ?? .full(size)
                    preview = image
                } catch is CancellationError {
                    return
                } catch {
                    failed = true
                }
            }
        }.tint(CanvasTheme.accent)
    }

    private var gestureHint: String {
        if cropLocked { return zoom > 1 ? "单指拖动查看大图" : "裁剪已锁定，可用滑杆放大" }
        return "拖动裁剪框，滑杆缩放"
    }

    private var ratioOverlay: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.12)
                .contentShape(Rectangle())
                .onTapGesture { showsRatios = false }
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                ForEach(Ratio.allCases, id: \.self) { option in
                    Button {
                        selectRatio(option)
                        showsRatios = false
                    } label: {
                        HStack {
                            Text(option.rawValue)
                            Spacer()
                            if ratio == option { Image(systemName: "checkmark").accessibilityHidden(true) }
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(ratio == option ? .isSelected : [])
                    .disabled(option.units.map { Int(pixels.width) < $0.width || Int(pixels.height) < $0.height } ?? false)
                    if option != Ratio.allCases.last { Divider() }
                }
            }
            .frame(width: 200)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(radius: 8)
            .padding(8)
            .accessibilityAction(.escape) { showsRatios = false }
        }
    }

    private func selectRatio(_ option: Ratio) {
        guard !cropLocked, let current = crop else { return }
        guard let units = option.units else { ratio = .free; return }
        let scale = min(Int(pixels.width) / units.width, Int(pixels.height) / units.height)
        guard scale > 0 else { return }
        let width = units.width * scale
        let height = units.height * scale
        let left = min(Int(pixels.width) - width, max(0, Int((current.rect.midX - CGFloat(width) / 2).rounded())))
        let top = min(Int(pixels.height) - height, max(0, Int((current.rect.midY - CGFloat(height) / 2).rounded())))
        crop = WallpaperPixelCrop(left: left, top: top, right: left + width, bottom: top + height)
        ratio = option
        zoom = 1
    }

    private func translate(_ original: WallpaperPixelCrop, x: Int, y: Int) {
        guard !cropLocked else { return }
        let dx = min(Int(pixels.width) - original.right, max(-original.left, x))
        let dy = min(Int(pixels.height) - original.bottom, max(-original.top, y))
        crop = WallpaperPixelCrop(left: original.left + dx, top: original.top + dy,
                                  right: original.right + dx, bottom: original.bottom + dy)
    }

    private func viewport(_ image: UIImage, crop: WallpaperPixelCrop, viewportSize: CGSize) -> some View {
        let fit = CropGeometry.fit(source: pixels, target: viewportSize).size
        let size = CGSize(width: fit.width * zoom, height: fit.height * zoom)
        let focus = zoom > 1 ? clampedCenter(center) : CGPoint(x: 0.5, y: 0.5)
        return Color(uiColor: .secondarySystemGroupedBackground)
            .frame(width: viewportSize.width, height: viewportSize.height)
            .overlay(alignment: .topLeading) {
                if size.width > 0, size.height > 0 {
                    editor(image, crop: crop, size: size)
                        .frame(width: size.width, height: size.height)
                        .offset(x: viewportSize.width / 2 - focus.x * size.width,
                                y: viewportSize.height / 2 - focus.y * size.height)
                        .allowsHitTesting(!cropLocked)
                }
            }
            .overlay {
                if cropLocked && zoom > 1 {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(DragGesture().onChanged { value in
                            guard size.width > 0, size.height > 0 else { return }
                            if panStart == nil { panStart = focus }
                            guard let start = panStart else { return }
                            center = clampedCenter(CGPoint(x: start.x - value.translation.width / size.width,
                                                           y: start.y - value.translation.height / size.height))
                        }.onEnded { _ in panStart = nil })
                }
            }
            .clipped()
            .contentShape(Rectangle())
    }
    private func clampedCenter(_ point: CGPoint) -> CGPoint {
        // Let even the outermost image edges reach the center of the viewport.
        CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
    }

    private func focusSelectedEdge() {
        guard let crop else { return }
        let axis = CGFloat(crop[keyPath: selected.coordinate])
        center = selected.vertical
            ? CGPoint(x: axis / pixels.width, y: crop.rect.midY / pixels.height)
            : CGPoint(x: crop.rect.midX / pixels.width, y: axis / pixels.height)
    }

    private func editor(_ image: UIImage, crop: WallpaperPixelCrop, size: CGSize) -> some View {
        let xScale = size.width / pixels.width
        let yScale = size.height / pixels.height
        let rect = CGRect(x: CGFloat(crop.left) * xScale, y: CGFloat(crop.top) * yScale,
                          width: crop.rect.width * xScale, height: crop.rect.height * yScale)
        return ZStack(alignment: .topLeading) {
            Image(uiImage: image).resizable().frame(width: size.width, height: size.height)
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.addRect(rect)
            }.fill(.black.opacity(0.30), style: FillStyle(eoFill: true)).allowsHitTesting(false)
            if rect.width > 0, rect.height > 0 {
                Rectangle()
                    .strokeBorder(.yellow, style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                    .shadow(color: .black.opacity(0.6), radius: 1)
                    .background(Color.clear)
                    .frame(width: rect.width, height: rect.height)
                    .contentShape(Rectangle())
                    .position(x: rect.midX, y: rect.midY)
                    .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("crop")).onChanged { value in
                        guard !cropLocked else { return }
                        if frameDragStart == nil { frameDragStart = self.crop }
                        guard let start = frameDragStart else { return }
                        translate(start, x: Int((value.translation.width / xScale).rounded()),
                                  y: Int((value.translation.height / yScale).rounded()))
                    }.onEnded { _ in frameDragStart = nil })
            }
            if ratio == .free {
                ForEach(Edge.allCases, id: \.self) { edge in
                    let scale = edge.vertical ? xScale : yScale
                    let limit = edge.vertical ? size.width : size.height
                    let position = CGFloat(crop[keyPath: edge.coordinate]) * scale
                    let hitInset = min(12, limit / 2)
                    let hitCenter = min(max(position, hitInset), limit - hitInset)
                    Path { path in
                        if edge.vertical {
                            path.move(to: CGPoint(x: position, y: 0))
                            path.addLine(to: CGPoint(x: position, y: size.height))
                        } else {
                            path.move(to: CGPoint(x: 0, y: position))
                            path.addLine(to: CGPoint(x: size.width, y: position))
                        }
                    }
                        .stroke(edge == selected ? Color.yellow : .white, style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                        .shadow(color: .black.opacity(0.6), radius: 1)
                        .allowsHitTesting(false)
                    Color.clear
                        .frame(width: edge.vertical ? 24 : size.width, height: edge.vertical ? size.height : 24)
                        .contentShape(Rectangle())
                        .position(x: edge.vertical ? hitCenter : size.width / 2, y: edge.vertical ? size.height / 2 : hitCenter)
                        .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("crop")).onChanged { value in
                            guard scale > 0, !cropLocked else { return }
                            if dragStart == nil {
                                selected = edge
                                dragStart = self.crop?[keyPath: edge.coordinate]
                            }
                            guard selected == edge, let dragStart else { return }
                            let delta = edge.vertical ? value.translation.width : value.translation.height
                            move(edge, to: dragStart + Int((delta / scale).rounded()))
                        }.onEnded { _ in dragStart = nil })
                        .onTapGesture { selected = edge }
                        .accessibilityHidden(true)
                }
            }
        }
        .coordinateSpace(name: "crop")
    }

    private func triangle(_ delta: Int) -> some View {
        let direction = selected.vertical ? (delta < 0 ? "左" : "右") : (delta < 0 ? "上" : "下")
        return Button {
            guard let crop else { return }
            if ratio == .free { move(selected, to: crop[keyPath: selected.coordinate] + delta) }
            else { translate(crop, x: selected.vertical ? delta : 0, y: selected.vertical ? 0 : delta) }
        } label: {
            Image(systemName: "triangle.fill")
                .rotationEffect(.degrees(selected.vertical ? Double(delta) * 90 : (delta < 0 ? 0 : 180)))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(cropLocked)
        .accessibilityLabel("\(ratio == .free ? selected.rawValue : "裁剪框")向\(direction)移动 1 像素")
    }

    private func move(_ edge: Edge, to value: Int) {
        guard !cropLocked, var crop else { return }
        let bounds: ClosedRange<Int>
        switch edge {
        case .left: bounds = 0...(crop.right - 1)
        case .right: bounds = (crop.left + 1)...Int(pixels.width)
        case .top: bounds = 0...(crop.bottom - 1)
        case .bottom: bounds = (crop.top + 1)...Int(pixels.height)
        }
        crop[keyPath: edge.coordinate] = min(bounds.upperBound, max(bounds.lowerBound, value))
        self.crop = crop
    }
}
