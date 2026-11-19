import XCTest
@testable import CarVista

final class CatalogPolicyTests: XCTestCase {
    func testPublishedRemoteListReplacesBundledWallpapers() {
        let remote = [item("海岸")]
        let bundled = [item("壁纸 1")]
        XCTAssertEqual(CatalogPolicy.choose(offline: false, remote: remote, cached: [], bundled: bundled), remote)
    }

    func testEmptyRemoteKeepsCacheThenBundle() {
        let cached = [item("上次的海岸")]
        let bundled = [item("壁纸 1")]
        XCTAssertEqual(CatalogPolicy.choose(offline: false, remote: [], cached: cached, bundled: bundled), cached)
        XCTAssertEqual(CatalogPolicy.choose(offline: false, remote: [], cached: [], bundled: bundled), bundled)
    }

    func testOfflineCatalogIgnoresRemoteAndCache() {
        let bundled = [item("壁纸 1")]
        XCTAssertEqual(CatalogPolicy.choose(offline: true, remote: [item("海岸")], cached: [item("缓存")], bundled: bundled), bundled)
    }

    private func item(_ title: String) -> CatalogItem {
        CatalogItem(id: title, title: title, kind: .bundledBuiltin(0), remote: nil)
    }
}
