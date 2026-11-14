// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CoreGraphics

enum CropGeometry {
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
