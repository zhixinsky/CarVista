// SPDX-License-Identifier: GPL-3.0-or-later
import UIKit
import ImageIO
import CoreImage

enum WallpaperRenderer {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    static func format() -> UIGraphicsImageRendererFormat {
        let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = true; f.preferredRange = .standard
        return f
    }
    static func load(_ url: URL, maximum: Int) throws -> UIImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, maximum),
                kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        return UIImage(cgImage: cg)
    }
    static func transformed(_ image: UIImage, adjustment: WallpaperAdjustment) -> UIImage {
        let turns = ((adjustment.turns % 4) + 4) % 4
        guard turns != 0 || adjustment.flipX || adjustment.flipY else { return image }
        let size = turns % 2 == 0 ? image.size : CGSize(width: image.size.height, height: image.size.width)
        return UIGraphicsImageRenderer(size: size, format: format()).image { renderer in
            UIColor.white.setFill(); renderer.fill(CGRect(origin: .zero, size: size))
            let c = renderer.cgContext
            c.translateBy(x: size.width / 2, y: size.height / 2)
            c.scaleBy(x: adjustment.flipX ? -1 : 1, y: adjustment.flipY ? -1 : 1)
            c.rotate(by: CGFloat(turns) * .pi / 2)
            image.draw(in: CGRect(x: -image.size.width / 2, y: -image.size.height / 2, width: image.size.width, height: image.size.height))
        }
    }
    static func render(url: URL, preset: WallpaperPreset, size: CGSize, adjustment: WallpaperAdjustment) throws -> UIImage {
        let maximum = Int(ceil(max(size.width, size.height) * (preset.crops ? max(1, min(4, adjustment.zoom)) : 1)))
        let image = try load(url, maximum: maximum)
        return try render(image: image, preset: preset, size: size, adjustment: adjustment)
    }
    static func render(image: UIImage, preset: WallpaperPreset, size: CGSize, adjustment: WallpaperAdjustment = .init()) throws -> UIImage {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { throw CocoaError(.fileWriteUnknown) }
        let source = transformed(image, adjustment: adjustment)
        let bounds = CGRect(origin: .zero, size: size)
        if preset.crops {
            return UIGraphicsImageRenderer(size: size, format: format()).image { c in
                UIColor.white.setFill(); c.fill(bounds)
                source.draw(in: CropGeometry.rect(source: source.size, target: size, zoom: adjustment.zoom, x: adjustment.x, y: adjustment.y))
            }
        }
        let background = UIGraphicsImageRenderer(size: size, format: format()).image { c in
            UIColor.white.setFill(); c.fill(bounds)
            source.draw(in: CropGeometry.rect(source: source.size, target: size, zoom: 1, x: 0.5, y: 0.5))
        }
        guard let cg = background.cgImage else { throw CocoaError(.fileWriteUnknown) }
        // Clamp before blurring, then crop: Gaussian blur cannot introduce transparent/black edges.
        let blurred = CIImage(cgImage: cg).clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(size.width, size.height) * 0.025])
            .cropped(to: bounds)
        guard let blurredCG = context.createCGImage(blurred, from: bounds) else { throw CocoaError(.fileWriteUnknown) }
        return UIGraphicsImageRenderer(size: size, format: format()).image { _ in
            UIImage(cgImage: blurredCG).draw(in: bounds)
            source.draw(in: CropGeometry.fit(source: source.size, target: size))
        }
    }
}
