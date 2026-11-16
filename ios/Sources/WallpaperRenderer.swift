// SPDX-License-Identifier: GPL-3.0-or-later
import UIKit
import ImageIO
import CoreImage

enum WallpaperRenderer {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let leftEdgeKernel = CIKernel(source: """
        kernel vec4 blendLeft(sampler image, float width, float range, float brightness,
                              float saturation, float curve) {
            vec4 source = sample(image, samplerCoord(image));
            float x = max(0.0, (destCoord().x - 0.5) / max(width - 1.0, 1.0));
            if (x >= range) { return source; }
            float weight = pow(1.0 - smoothstep(0.0, range, x), curve);
            vec4 pixel = unpremultiply(source);
            vec3 rgb = pixel.rgb * (1.0 + brightness * weight);
            float gray = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
            rgb = vec3(gray) + (rgb - vec3(gray)) * (1.0 + saturation * weight);
            return premultiply(vec4(rgb, pixel.a));
        }
        """)
    private static let maskKernel = CIKernel(source: """
        kernel vec4 compensate(sampler image, float width, float opacity, float strength,
                               float gradient, float protect) {
            vec4 pixel = unpremultiply(sample(image, samplerCoord(image)));
            float x = clamp((destCoord().x - 0.5) / max(width - 1.0, 1.0), 0.0, 1.0);
            float offset = x < 0.5 ? mix(0.04, 0.0, x * 2.0) : mix(0.0, -0.05, (x - 0.5) * 2.0);
            float alpha = clamp(opacity + gradient * offset * min(1.0, opacity * 5.0), 0.0, 0.5);
            float gain = mix(1.0, 1.0 / (1.0 - alpha), strength);
            vec3 rgb = pixel.rgb * gain;
            if (protect > 0.5) {
                float peak = max(max(pixel.r, pixel.g), pixel.b);
                float knee = 0.72;
                float start = knee / gain;
                if (peak > start) {
                    float t = clamp((peak - start) / (1.0 - start), 0.0, 1.0);
                    float slope = gain * (1.0 - start) / (1.0 - knee);
                    float safePeak = knee + (1.0 - knee) * t * slope / (1.0 + t * (slope - 1.0));
                    rgb = pixel.rgb * (safePeak / max(peak, 0.0001));
                }
            }
            return premultiply(vec4(rgb, pixel.a));
        }
        """)
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
        var output = input
        if let mask = adjustment.mask, mask.opacity > 0, (mask.strength ?? 1) > 0 {
            guard let corrected = maskKernel?.apply(extent: input.extent, roiCallback: { _, rect in rect }, arguments: [
                input, input.extent.width, min(0.50, mask.opacity), min(1.50, mask.strength ?? 1),
                mask.horizontalGradient == true ? 1.0 : 0.0, mask.protectHighlights == false ? 0.0 : 1.0
            ]) else { throw CocoaError(.fileWriteUnknown) }
            output = corrected
        }
        if let exposure = adjustment.exposure, exposure != 0 {
            output = output.applyingFilter("CIExposureAdjust", parameters: ["inputEV": exposure])
        }
        if (adjustment.highlights ?? 0) != 0 || (adjustment.shadows ?? 0) != 0 {
            output = output.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1 + (adjustment.highlights ?? 0),
                "inputShadowAmount": adjustment.shadows ?? 0
            ])
        }
        if let temperature = adjustment.temperature, temperature != 0 {
            output = output.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: CGFloat(6500 + temperature), y: 0)
            ])
        }
        if let gamma = adjustment.gamma, gamma != 1 {
            output = output.applyingFilter("CIGammaAdjust", parameters: ["inputPower": gamma])
        }
        if adjustment.brightness != 0 || adjustment.contrast != 1 || adjustment.saturation != 1 {
            output = output.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: adjustment.brightness,
                kCIInputContrastKey: adjustment.contrast,
                kCIInputSaturationKey: adjustment.saturation
            ])
        }
        if let edge = adjustment.leftEdge, edge.width > 0, edge.brightness != 0 || edge.saturation != 0 {
            guard let blended = leftEdgeKernel?.apply(
                extent: input.extent, roiCallback: { _, rect in rect }, arguments: [
                    output, input.extent.width, min(0.5, edge.width),
                    max(-0.5, min(1, edge.brightness)), max(-0.5, min(1, edge.saturation)),
                    max(0.75, min(3, edge.curve))
                ]
            ) else { throw CocoaError(.fileWriteUnknown) }
            output = blended
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
