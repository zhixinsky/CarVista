// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct WallpaperAdjustmentView: View {
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

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                GeometryReader { geometry in
                    if let preview, let crop {
                        let size = CropGeometry.fit(source: pixels, target: geometry.size).size
                        editor(preview, crop: crop, size: size)
                            .frame(width: size.width, height: size.height)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if failed {
                        Text("无法读取原图").frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                if let crop {
                    Picker("微调边线", selection: $selected) {
                        ForEach(Edge.allCases, id: \.self) { edge in
                            Text(edge.rawValue).tag(edge)
                        }
                    }.pickerStyle(.segmented)
                    Text("\(Int(crop.rect.width)) × \(Int(crop.rect.height)) 像素 · 三角每次移动 1 像素")
                        .font(.caption).monospacedDigit()
                }
            }
            .padding(12)
            .navigationTitle("自由裁剪")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button("还原") { crop = .full(pixels) }.disabled(crop == nil)
                    Button("确定") {
                        guard let crop else { return }
                        save(crop)
                        dismiss()
                    }.disabled(crop == nil)
                }
            }
            .task {
                do {
                    let url = photo.url
                    let (image, size) = try await Task.detached {
                        (try WallpaperRenderer.load(url, maximum: 2400), try WallpaperRenderer.pixelSize(url))
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
            }.fill(.black.opacity(0.65), style: FillStyle(eoFill: true)).allowsHitTesting(false)
            ForEach(Edge.allCases, id: \.self) { edge in
                let scale = edge.vertical ? xScale : yScale
                let limit = edge.vertical ? size.width : size.height
                let position = CGFloat(crop[keyPath: edge.coordinate]) * scale
                let hitCenter = min(max(position, 12), max(12, limit - 12))
                Rectangle()
                    .fill(edge == selected ? Color.yellow : .white)
                    .frame(width: edge.vertical ? 2 : size.width, height: edge.vertical ? size.height : 2)
                    .position(x: edge.vertical ? position : size.width / 2, y: edge.vertical ? size.height / 2 : position)
                    .allowsHitTesting(false)
                Color.clear
                    .frame(width: edge.vertical ? 24 : size.width, height: edge.vertical ? size.height : 24)
                    .contentShape(Rectangle())
                    .position(x: edge.vertical ? hitCenter : size.width / 2, y: edge.vertical ? size.height / 2 : hitCenter)
                    .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("crop")).onChanged { value in
                        guard scale > 0 else { return }
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
            let axis = CGFloat(crop[keyPath: selected.coordinate]) * (selected.vertical ? xScale : yScale)
            let midpoint = selected.vertical
                ? CGPoint(x: min(max(axis, 38), max(38, size.width - 38)), y: size.height / 2)
                : CGPoint(x: size.width / 2, y: min(max(axis, 23), max(23, size.height - 23)))
            HStack(spacing: 0) { triangle(-1); triangle(1) }
            .background(.black.opacity(0.8), in: Capsule())
            .position(x: midpoint.x, y: midpoint.y)
        }
        .coordinateSpace(name: "crop")
    }

    private func triangle(_ delta: Int) -> some View {
        let direction = selected.vertical ? (delta < 0 ? "左" : "右") : (delta < 0 ? "上" : "下")
        return Button {
            guard let crop else { return }
            move(selected, to: crop[keyPath: selected.coordinate] + delta)
        } label: {
            Image(systemName: "triangle.fill")
                .rotationEffect(.degrees(selected.vertical ? Double(delta) * 90 : (delta < 0 ? 0 : 180)))
                .foregroundStyle(.white)
                .frame(width: 38, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(selected.rawValue)向\(direction)移动 1 像素")
    }

    private func move(_ edge: Edge, to value: Int) {
        guard var crop else { return }
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
