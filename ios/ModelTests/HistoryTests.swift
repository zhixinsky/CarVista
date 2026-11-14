import XCTest
import UIKit
@testable import CarCanvasWorkshop

final class HistoryTests: XCTestCase {
    @MainActor
    func testOriginalPixelsRejectMismatchedBatchBeforeAnyWrite() throws {
        let model = WorkshopModel()
        let entry = SavedWallpaper(id: UUID(), created: Date(), width: 1800, height: 600,
            mode: "深色", preservePixels: true)
        let restored = try JSONDecoder().decode(SavedWallpaper.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(restored.preservePixels, true)
        let matching = WallpaperTarget(raw: ["path": "/first", "mode": "深色", "width": 1800, "height": 600])
        let different = WallpaperTarget(raw: ["path": "/second", "mode": "浅色", "width": 1920, "height": 720])
        var completed = false
        model.applyBatch(entries: [entry], targets: [matching, different]) { completed = true }
        // Synchronous completion proves the batch never entered the writer queue.
        XCTAssertTrue(completed)
        XCTAssertFalse(model.busy)
        XCTAssertTrue(model.message.contains("本次未写入"))
        XCTAssertTrue(model.message.contains("1800 × 600"))
        XCTAssertTrue(model.message.contains("1920 × 720"))
    }
    @MainActor
    func testHistoryPersistsRenameAndDeletesOwnedFiles() throws {
        let model = WorkshopModel()
        let entry = SavedWallpaper(id: UUID(), created: Date(), width: 1920, height: 720, mode: "深色")
        let metadata = WorkshopModel.library.appendingPathComponent("\(entry.id).json")
        let files = [entry.bitmap, entry.preview, entry.originalImage, metadata]
        defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }
        for url in files.dropLast() { try Data([1]).write(to: url) }
        try JSONEncoder().encode(entry).write(to: metadata)
        let loaded = WorkshopModel()
        XCTAssertTrue(loaded.history.contains { $0.id == entry.id })
        loaded.renameHistory([entry], name: "  海边  ")
        let persisted = try JSONDecoder().decode(SavedWallpaper.self, from: Data(contentsOf: metadata))
        XCTAssertEqual(persisted.customName, "海边")
        loaded.busy = true
        loaded.deleteHistory([entry])
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadata.path))
        loaded.busy = false
        loaded.deleteHistory([entry])
        XCTAssertFalse(loaded.history.contains { $0.id == entry.id })
        XCTAssertTrue(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        _ = model
    }

    @MainActor
    func testInvalidHistoryAndBatchFailBeforeMutation() throws {
        let model = WorkshopModel()
        let entry = SavedWallpaper(id: UUID(), created: Date(), width: 1920, height: 0, mode: "深色")
        let metadata = WorkshopModel.library.appendingPathComponent("\(entry.id).json")
        defer { try? FileManager.default.removeItem(at: metadata) }
        try JSONEncoder().encode(entry).write(to: metadata)
        XCTAssertFalse(WorkshopModel().history.contains { $0.id == entry.id })
        var completed = false
        model.applyBatch(entries: [entry], targets: [WallpaperTarget(raw: ["path": "/invalid", "width": Int.max, "height": Int.max])]) { completed = true }
        XCTAssertTrue(completed)
        XCTAssertFalse(model.busy)
        XCTAssertTrue(model.message.contains("不可替换"))
    }

    @MainActor
    func testRetinaImageUsesPixelDimensionsAndFailedEncodingCleansUp() async throws {
        let model = WorkshopModel()
        let before = Set(model.history.map(\.id))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 16), format: format).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
        }
        let saved = await withCheckedContinuation { continuation in
            model.saveVariants(image: image, modes: ["深色", "浅色"]) { continuation.resume(returning: $0) }
        }
        if saved.isEmpty {
            // Private CPBitmap APIs may be unavailable on the simulator.
            XCTAssertEqual(Set(model.history.map(\.id)), before)
            XCTAssertFalse(model.busy)
            XCTAssertFalse(model.message.isEmpty)
        } else {
            defer { model.deleteHistory(saved) }
            XCTAssertEqual(saved.count, 2)
            XCTAssertEqual(saved[0].width, 64)
            XCTAssertEqual(saved[0].height, 32)
            XCTAssertEqual(saved[0].batchID, saved[1].batchID)
            XCTAssertTrue(saved.allSatisfy { FileManager.default.fileExists(atPath: $0.bitmap.path) })
        }
    }
}
