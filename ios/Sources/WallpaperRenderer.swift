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
    static func pixelSize(_ url: URL) throws -> CGSize {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber).map({ CGFloat(truncating: $0) }),
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber).map({ CGFloat(truncating: $0) }),
              width > 0, height > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        return (5...8).contains(orientation) ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
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
        if let crop = adjustment.pixelCrop {
            let pixels = try pixelSize(url)
            guard crop.fits(pixels) else { throw CocoaError(.fileReadCorruptFile) }
            let original = try load(url, maximum: Int(max(pixels.width, pixels.height)))
            guard original.size == pixels, let result = original.cgImage?.cropping(to: crop.rect) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return try colorCorrect(UIImage(cgImage: result), adjustment: adjustment.color)
        }
        let pixels = preset.preservesSourceSize ? try pixelSize(url) : size
        let maximum = Int(ceil(max(pixels.width, pixels.height) * (preset.crops ? max(1, min(4, adjustment.zoom)) : 1)))
        let image = try load(url, maximum: maximum)
        let rendered = try render(image: image, preset: preset, size: preset.preservesSourceSize ? image.size : size, adjustment: adjustment)
        return try colorCorrect(rendered, adjustment: adjustment.color)
    }

    static func colorCorrect(_ image: UIImage, adjustment: WallpaperColorAdjustment?) throws -> UIImage {
        guard let adjustment, adjustment != .init() else { return image }
        guard let cg = image.cgImage else { throw CocoaError(.fileWriteUnknown) }
        let input = CIImage(cgImage: cg)
        var output = input.applyingFilter("CIColorControls", parameters: [
            kCIInputBrightnessKey: adjustment.brightness,
            kCIInputContrastKey: adjustment.contrast,
            kCIInputSaturationKey: adjustment.saturation
        ])
        if let mask = adjustment.mask, mask.opacity > 0 {
            let opacity = min(0.30, mask.opacity)
            let gray = min(1, max(0, mask.gray))
            let linearGray = gray <= 0.04045 ? gray / 12.92 : pow((gray + 0.055) / 1.055, 2.4)
            let gain = CGFloat(1 / (1 - opacity))
            let bias = CGFloat(-opacity * linearGray / (1 - opacity))
            // Invert the estimated uniform overlay in Core Image's linear working space.
            output = output.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)
            ])
        }
        guard let result = context.createCGImage(output, from: input.extent) else { throw CocoaError(.fileWriteUnknown) }
        return UIImage(cgImage: result, scale: image.scale, orientation: image.imageOrientation)
    }
    static func render(image: UIImage, preset: WallpaperPreset, size: CGSize, adjustment: WallpaperAdjustment = .init()) throws -> UIImage {
        let source = transformed(image, adjustment: adjustment)
        let canvas = preset.preservesSourceSize ? source.size : size
        guard canvas.width.isFinite, canvas.height.isFinite, canvas.width > 0, canvas.height > 0 else { throw CocoaError(.fileWriteUnknown) }
        if preset.preservesSourceSize {
            return UIGraphicsImageRenderer(size: canvas, format: format()).image { _ in
                source.draw(in: CGRect(origin: .zero, size: canvas))
            }
        }
        let bounds = CGRect(origin: .zero, size: canvas)
        if preset.crops {
            return UIGraphicsImageRenderer(size: canvas, format: format()).image { c in
                UIColor.white.setFill(); c.fill(bounds)
                source.draw(in: CropGeometry.rect(source: source.size, target: canvas, zoom: adjustment.zoom, x: adjustment.x, y: adjustment.y))
            }
        }
        let background = UIGraphicsImageRenderer(size: canvas, format: format()).image { c in
            UIColor.white.setFill(); c.fill(bounds)
            source.draw(in: CropGeometry.rect(source: source.size, target: canvas, zoom: 1, x: 0.5, y: 0.5))
        }
        guard let cg = background.cgImage else { throw CocoaError(.fileWriteUnknown) }
        // Clamp before blurring, then crop: Gaussian blur cannot introduce transparent/black edges.
        let blurred = CIImage(cgImage: cg).clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(canvas.width, canvas.height) * 0.025])
            .cropped(to: bounds)
        guard let blurredCG = context.createCGImage(blurred, from: bounds) else { throw CocoaError(.fileWriteUnknown) }
        return UIGraphicsImageRenderer(size: canvas, format: format()).image { _ in
            UIImage(cgImage: blurredCG).draw(in: bounds)
            source.draw(in: CropGeometry.fit(source: source.size, target: canvas))
        }
    }
}
