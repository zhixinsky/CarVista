// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct WallpaperColorView: View {
    @Environment(\.dismiss) private var dismiss
    let photo: MakerPhoto
    let save: (WallpaperColorAdjustment) -> Void
    @State private var adjustment: WallpaperColorAdjustment
    @State private var original: UIImage?
    @State private var corrected: UIImage?
    @State private var showOriginal = false
    @State private var problem: String?

    init(photo: MakerPhoto, save: @escaping (WallpaperColorAdjustment) -> Void) {
        self.photo = photo
        self.save = save
        _adjustment = State(initialValue: photo.adjustment.color ?? .init())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let image = showOriginal ? original : (corrected ?? original) {
                        Image(uiImage: image).resizable().scaledToFit()
                            .frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 12))
                    } else if problem == nil {
                        ProgressView("正在准备预览…")
                    }
                    Toggle("查看原色", isOn: $showOriginal).disabled(original == nil)
                    Toggle("CarPlay 蒙版补偿", isOn: Binding(
                        get: { adjustment.mask != nil },
                        set: { adjustment.mask = $0 ? WallpaperMaskCompensation() : nil; showOriginal = false }
                    )).disabled(original == nil)
                    if let mask = adjustment.mask {
                        slider("补偿强度", value: Binding(
                            get: { adjustment.mask?.opacity ?? mask.opacity },
                            set: { adjustment.mask?.opacity = $0 }
                        ), range: 0...0.30, neutral: 0)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text("假设蒙版颜色"); Spacer(); Text("黑 → 白").font(.caption) }
                            Slider(value: Binding(
                                get: { adjustment.mask?.gray ?? mask.gray },
                                set: { adjustment.mask?.gray = $0 }
                            ), in: 0...1, step: 0.05).accessibilityLabel("假设蒙版颜色，从黑到白")
                        }
                        Text("默认从 8% 中灰试起。预览显示补偿后的输出图，实际以车机接缝为准。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    slider("亮度", value: $adjustment.brightness, range: -0.15...0.15, neutral: 0)
                    slider("对比度", value: $adjustment.contrast, range: 0.75...1.35, neutral: 1)
                    slider("饱和度", value: $adjustment.saturation, range: 0.5...1.5, neutral: 1)
                    Button("恢复原色") { adjustment = .init(); showOriginal = false }
                    if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
                }.padding(20).frame(maxWidth: 600).frame(maxWidth: .infinity)
            }
            .navigationTitle("整体校色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确定") { save(adjustment); dismiss() }.disabled(original == nil)
                }
            }
            .task { await loadOriginal() }
            .task(id: PreviewKey(ready: original != nil, color: adjustment)) { await updatePreview() }
        }.tint(CanvasTheme.accent)
    }

    private struct PreviewKey: Equatable {
        let ready: Bool
        let color: WallpaperColorAdjustment
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, neutral: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%+.0f", (value.wrappedValue - neutral) * 100)).monospacedDigit()
            }
            Slider(value: value, in: range, step: 0.01).accessibilityLabel(title)
        }.disabled(original == nil)
    }

    private func loadOriginal() async {
        let photo = photo
        do {
            let image = try await Task.detached {
                try autoreleasepool {
                    var adjustment = photo.adjustment
                    adjustment.color = nil
                    let full = try WallpaperRenderer.render(url: photo.url, preset: .original, size: .zero, adjustment: adjustment)
                    let scale = min(1, 1100 / max(full.size.width, full.size.height))
                    let size = CGSize(width: max(1, full.size.width * scale), height: max(1, full.size.height * scale))
                    return UIGraphicsImageRenderer(size: size, format: WallpaperRenderer.format()).image { _ in
                        full.draw(in: CGRect(origin: .zero, size: size))
                    }
                }
            }.value
            if !Task.isCancelled { original = image }
        } catch {
            if !Task.isCancelled { problem = "无法读取校色预览。" }
        }
    }

    private func updatePreview() async {
        guard let original else { return }
        let color = adjustment
        do {
            try await Task.sleep(for: .milliseconds(60))
            let image = try await Task.detached { try WallpaperRenderer.colorCorrect(original, adjustment: color) }.value
            try Task.checkCancellation()
            corrected = image
            problem = nil
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled { problem = "无法生成校色预览。" }
        }
    }
}
