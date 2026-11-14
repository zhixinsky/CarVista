// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum WallpaperStorage {
    static var library: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Wallpapers")
    }
}

struct SavedWallpaper: Identifiable, Codable {
    let id: UUID
    let created: Date
    let width: Int
    let height: Int
    let mode: String
    // Optional fields preserve compatibility with 0.2 history records.
    var batchID: UUID? = nil
    var customName: String? = nil
    var bitmap: URL { WallpaperStorage.library.appendingPathComponent("\(id).cpbitmap") }
    var preview: URL { WallpaperStorage.library.appendingPathComponent("\(id).jpg") }
    var originalImage: URL { WallpaperStorage.library.appendingPathComponent("\(id).png") }
}
