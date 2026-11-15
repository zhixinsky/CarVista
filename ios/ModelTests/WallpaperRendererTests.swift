import XCTest
import UIKit
@testable import CarCanvasWorkshop

final class WallpaperRendererTests: XCTestCase {
    private func fixture() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 100, height: 200), format: WallpaperRenderer.format()).image { c in
            UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            UIColor.green.setFill(); c.fill(CGRect(x: 0, y: 100, width: 100, height: 100))
        }
    }
    private func sample(_ image: UIImage, x: Int, y: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            // Sample a cropped CGImage; coordinates remain in image pixel space.
            let pixel = image.cgImage!.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))!
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }
    func testBlurPreservesWholeForegroundAndFillsEdges() throws {
        for preset in [WallpaperPreset.automatic, .wide, .panoramic] {
            let size = preset.size()
            let output = try WallpaperRenderer.render(image: fixture(), preset: preset, size: size)
            XCTAssertEqual(output.cgImage?.width, Int(size.width))
            XCTAssertEqual(output.cgImage?.height, Int(size.height))
            let top = sample(output, x: Int(size.width / 2), y: 10)
            let bottom = sample(output, x: Int(size.width / 2), y: Int(size.height) - 11)
            XCTAssertGreaterThan(top[0], 230); XCTAssertLessThan(top[1], 20)
            XCTAssertGreaterThan(bottom[1], 230); XCTAssertLessThan(bottom[0], 20)
            for x in [0, Int(size.width) - 1] {
                for y in [0, Int(size.height / 2), Int(size.height) - 1] {
                    let edge = sample(output, x: x, y: y)
                    XCTAssertEqual(edge[3], 255, "blur edge must be opaque")
                    XCTAssertGreaterThan(Int(edge[0]) + Int(edge[1]) + Int(edge[2]), 100, "artificial black border")
                }
            }
        }
    }
    func testStandardCropPositionAndRotation() throws {
        var adjustment = WallpaperAdjustment(); adjustment.y = 0
        let top = try WallpaperRenderer.render(image: fixture(), preset: .standard, size: WallpaperPreset.standard.size(), adjustment: adjustment)
        adjustment.y = 1
        let bottom = try WallpaperRenderer.render(image: fixture(), preset: .standard, size: WallpaperPreset.standard.size(), adjustment: adjustment)
        XCTAssertGreaterThan(sample(top, x: 700, y: 400)[0], 230)
        XCTAssertGreaterThan(sample(bottom, x: 700, y: 400)[1], 230)
        adjustment.turns = 1
        let rotated = WallpaperRenderer.transformed(fixture(), adjustment: adjustment)
        XCTAssertEqual(rotated.size, CGSize(width: 200, height: 100))
        adjustment = .init(); adjustment.flipY = true
        let flipped = WallpaperRenderer.transformed(fixture(), adjustment: adjustment)
        XCTAssertGreaterThan(sample(flipped, x: 50, y: 10)[1], 230)
    }
    @MainActor
    func testDetectedSizeAndDraftPersistence() throws {
        let model = WorkshopModel()
        model.targets = [WallpaperTarget(raw: ["width": 2420, "height": 1668]), WallpaperTarget(raw: ["width": 2420, "height": 1668]), WallpaperTarget(raw: ["width": 800, "height": 480])]
        XCTAssertEqual(model.detectedWallpaperSize, CGSize(width: 2420, height: 1668))
        let photo = try MakerDraft.importPhoto(data: fixture().pngData()!)
        defer { try? FileManager.default.removeItem(at: photo.url) }
        var changed = photo; changed.adjustment.turns = 3; changed.adjustment.zoom = 2
        let restored = try JSONDecoder().decode(MakerPhoto.self, from: JSONEncoder().encode(changed))
        XCTAssertEqual(restored, changed)
        XCTAssertEqual(try WallpaperRenderer.load(photo.url, maximum: 200).size, fixture().size)
    }
}
