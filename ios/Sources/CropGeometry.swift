// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CoreGraphics

enum WallpaperPreset: String, CaseIterable, Codable, Identifiable {
    case automatic, standard, wide, panoramic
    var id: String { rawValue }
    var title: String {
        switch self { case .automatic: return "自动"; case .standard: return "标准"; case .wide: return "宽屏"; case .panoramic: return "大连屏" }
    }
    var crops: Bool { self == .standard }
    func size(detected: CGSize? = nil) -> CGSize {
        switch self {
        case .automatic:
            if let detected, detected.width.isFinite, detected.height.isFinite, detected.width > 0, detected.height > 0 { return detected }
            return CGSize(width: 1920, height: 810)
        case .standard: return CGSize(width: 1440, height: 810)
        case .wide: return CGSize(width: 1920, height: 810)
        case .panoramic: return CGSize(width: 2560, height: 810)
        }
    }
    var detail: String { crops ? "照片铺满画面，多出的部分裁掉。可点“调整”移动位置。" : "整张照片居中保留，空余区域用照片自身的模糊画面填满，不留黑边、不拉变形。" }
}

struct WallpaperAdjustment: Codable, Equatable {
    var turns = 0
    var flipX = false
    var flipY = false
    var zoom = 1.0
    var x = 0.5
    var y = 0.5
}

enum CropGeometry {
    static func fit(source: CGSize, target: CGSize) -> CGRect {
        guard source.width > 0, source.height > 0, target.width > 0, target.height > 0 else { return .zero }
        let scale = min(target.width / source.width, target.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(x: (target.width - size.width) / 2, y: (target.height - size.height) / 2, width: size.width, height: size.height)
    }
    // Position 0 is the left/top edge, 1 the right/bottom edge. Rendering and
    // preview share this calculation, so the saved crop matches the preview.
    static func rect(source: CGSize, target: CGSize, zoom: Double, x: Double, y: Double) -> CGRect {
        guard source.width.isFinite, source.height.isFinite, target.width.isFinite, target.height.isFinite,
              zoom.isFinite, x.isFinite, y.isFinite,
              source.width > 0, source.height > 0, target.width > 0, target.height > 0 else { return .zero }
        let scale = max(target.width / source.width, target.height / source.height) * CGFloat(max(1, min(4, zoom)))
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(x: (target.width - size.width) * CGFloat(min(1, max(0, x))),
                      y: (target.height - size.height) * CGFloat(min(1, max(0, y))),
                      width: size.width, height: size.height)
    }
}
