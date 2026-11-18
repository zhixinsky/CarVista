// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

private struct ColorParameterValue: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let neutral: Double
    let scale: Double
    let format: String
    @State private var editing = false
    @State private var input = ""

    private var enteredValue: Double? {
        guard let number = Double(input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")), number.isFinite else { return nil }
        let converted = number / scale + neutral
        return range.contains(converted) ? converted : nil
    }

    var body: some View {
        Button {
            input = String(format: "%.2f", (value - neutral) * scale)
            editing = true
        } label: {
            Text(String(format: format, (value - neutral) * scale))
                .monospacedDigit().underline()
        }
        .accessibilityLabel("输入\(title)")
        .sheet(isPresented: $editing) {
            NavigationStack {
                Form {
                    Section(title) {
                        TextField("数值", text: $input)
                            .keyboardType(.numbersAndPunctuation)
                            .accessibilityLabel(title)
                        Text("范围 \(String(format: format, (range.lowerBound - neutral) * scale)) 至 \(String(format: format, (range.upperBound - neutral) * scale))")
                            .font(.footnote).foregroundStyle(.secondary)
                        if enteredValue == nil {
                            Text("请输入范围内的数字。").foregroundStyle(.red)
                        }
                    }
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { editing = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("确定") {
                            if let enteredValue { value = enteredValue }
                            editing = false
                        }.disabled(enteredValue == nil)
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

struct WallpaperColorView: View {
    @Environment(\.dismiss) private var dismiss
    let photo: MakerPhoto
    let save: (WallpaperColorAdjustment) -> Void
    @State private var adjustment: WallpaperColorAdjustment
    @State private var original: UIImage?
    @State private var corrected: UIImage?
    @State private var showOriginal = false
    @State private var problem: String?
    @State private var savedEdge: WallpaperLeftEdgeBlend
    @State private var savedMask: WallpaperMaskCompensation
    @State private var usedWidePreset = false
    private static let widePreset = WallpaperLeftEdgeBlend(width: 0.20, brightness: 0.90, saturation: 0.08, curve: 1)

    init(photo: MakerPhoto, save: @escaping (WallpaperColorAdjustment) -> Void) {
        self.photo = photo
        self.save = save
        _adjustment = State(initialValue: photo.adjustment.color ?? .init())
        _savedEdge = State(initialValue: photo.adjustment.color?.leftEdge ?? .init())
        _savedMask = State(initialValue: photo.adjustment.color?.mask ?? .init())
        _usedWidePreset = State(initialValue: photo.adjustment.color?.leftEdge == Self.widePreset)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Group {
                    if let image = showOriginal ? original : (corrected ?? original) {
                        Image(uiImage: image).resizable().scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 210)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else if problem == nil {
                        ProgressView("正在准备预览…")
                    }
                }.padding(.horizontal, 20).padding(.vertical, 8)
                ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Toggle("查看原色", isOn: $showOriginal).disabled(original == nil)
                    Button("大联屏融合补偿") {
                        adjustment.leftEdge = Self.widePreset
                        usedWidePreset = true
                        showOriginal = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(original == nil)
                    if usedWidePreset {
                        Text(adjustment.leftEdge == nil ? "大联屏融合补偿已暂停" :
                             adjustment.leftEdge == Self.widePreset ? "大联屏预设已应用" : "大联屏预设已手动修改")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if adjustment.leftEdge != nil && adjustment.mask != nil {
                        Label("已叠加两项补偿，左侧亮度会同时受两项影响。", systemImage: "square.stack")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    leftEdgeControls
                    Toggle("CarPlay 蒙版补偿", isOn: Binding(
                        get: { adjustment.mask != nil },
                        set: { enabled in
                            if let mask = adjustment.mask { savedMask = mask }
                            adjustment.mask = enabled ? savedMask : nil
                            showOriginal = false
                        }
                    )).disabled(original == nil)
                    if let mask = adjustment.mask {
                        Text("黑色蒙版 #000000").font(.subheadline).foregroundStyle(.secondary)
                        slider("蒙版透明度", value: Binding(
                            get: { adjustment.mask?.opacity ?? mask.opacity },
                            set: { adjustment.mask?.opacity = $0 }
                        ), range: 0...0.50, neutral: 0, format: "%.0f%%")
                        slider("补偿强度", value: Binding(
                            get: { adjustment.mask?.strength ?? 1 },
                            set: { adjustment.mask?.strength = $0 }
                        ), range: 0...1.50, neutral: 0, format: "%.0f%%")
                        Toggle("水平渐变", isOn: Binding(
                            get: { adjustment.mask?.horizontalGradient ?? false },
                            set: { adjustment.mask?.horizontalGradient = $0 }
                        ))
                        if mask.horizontalGradient == true {
                            Text("默认从左到右：24% → 20% → 15%。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle("高光保护", isOn: Binding(
                            get: { adjustment.mask?.protectHighlights ?? true },
                            set: { adjustment.mask?.protectHighlights = $0 }
                        ))
                        Text("20% 蒙版在 100% 强度下对应 1.25 倍 RGB 增益，高光保护会柔和压缩亮部。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("更多调节") {
                        VStack(alignment: .leading, spacing: 18) {
                            slider("亮度", value: $adjustment.brightness, range: -0.15...0.15, neutral: 0)
                            slider("曝光", value: manual(\.exposure, defaultValue: 0), range: -1...1, neutral: 0,
                                   scale: 1, format: "%+.2f EV")
                            slider("对比度", value: $adjustment.contrast, range: 0.75...1.35, neutral: 1)
                            slider("饱和度", value: $adjustment.saturation, range: 0.5...1.5, neutral: 1)
                            slider("高光", value: manual(\.highlights, defaultValue: 0), range: -1...0, neutral: 0)
                            slider("阴影", value: manual(\.shadows, defaultValue: 0), range: -1...1, neutral: 0)
                            slider("色温", value: manual(\.temperature, defaultValue: 0), range: -2000...2000, neutral: 0,
                                   step: 50, scale: 1, format: "%+.0f K")
                            slider("Gamma", value: manual(\.gamma, defaultValue: 1), range: 0.65...1.5, neutral: 0,
                                   scale: 1, format: "%.2f")
                        }
                        .padding(.top, 8)
                    }
                    Button("重置全部调色") {
                        adjustment = .init()
                        savedEdge = .init()
                        savedMask = .init()
                        usedWidePreset = false
                        showOriginal = false
                    }
                    if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
                }.padding(20).frame(maxWidth: 600).frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("调色")
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

    private var leftEdgeControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("CarPlay 左侧边缘融合", isOn: Binding(
                get: { adjustment.leftEdge != nil },
                set: { enabled in
                    if let edge = adjustment.leftEdge { savedEdge = edge }
                    adjustment.leftEdge = enabled ? savedEdge : nil
                    showOriginal = false
                }
            ))
            if adjustment.leftEdge != nil {
                slider("渐变宽度", value: edgeValue(\.width), range: 0...0.50, neutral: 0, format: "%.0f%%")
                slider("左边缘亮度增益", value: edgeValue(\.brightness), range: -0.50...1, neutral: 0, format: "%+.0f%%")
                slider("左边缘饱和度", value: edgeValue(\.saturation), range: -0.50...1, neutral: 0, format: "%+.0f%%")
                slider("渐变曲线", value: edgeValue(\.curve), range: 0.75...3, neutral: 0,
                       step: 0.05, scale: 1, format: "%.2f")
                Text("1.00 为标准 Smoothstep。数值越大，补偿越集中在左边缘。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("恢复普通融合默认值") {
                    adjustment.leftEdge = .init()
                    usedWidePreset = false
                    showOriginal = false
                }
            }
        }.disabled(original == nil)
    }

    private func edgeValue(_ field: WritableKeyPath<WallpaperLeftEdgeBlend, Double>) -> Binding<Double> {
        Binding(get: { (adjustment.leftEdge ?? .init())[keyPath: field] }, set: {
            adjustment.leftEdge?[keyPath: field] = $0
            showOriginal = false
        })
    }

    private func manual(_ field: WritableKeyPath<WallpaperColorAdjustment, Double?>, defaultValue: Double) -> Binding<Double> {
        Binding(get: { adjustment[keyPath: field] ?? defaultValue }, set: {
            adjustment[keyPath: field] = $0 == defaultValue ? nil : $0
        })
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, neutral: Double,
                        step: Double = 0.01, scale: Double = 100, format: String = "%+.0f") -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                ColorParameterValue(title: title, value: value, range: range,
                                    neutral: neutral, scale: scale, format: format)
            }
            Slider(value: value, in: range, step: step).accessibilityLabel(title)
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
