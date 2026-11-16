import XCTest

final class NavigationTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    func testBuiltinSplitSelection() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-CCGuideSeen", "YES"]
        app.launch()
        app.buttons["home.wallpaper"].tap()
        let wallpaper = app.buttons["浅海人鱼"]
        for _ in 0..<3 { if wallpaper.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(wallpaper.isHittable)
        wallpaper.tap()
        XCTAssertTrue(app.buttons["builtin.use"].waitForExistence(timeout: 10))
        app.sliders["右侧壁纸起点"].adjust(toNormalizedSliderPosition: 0.4)
        capture(app, "10-Builtin-Split")
        app.buttons["取消"].tap()
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testHomeAndOfflineWorkflow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-CCGuideSeen", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["home.wallpaper"].waitForExistence(timeout: 15))
        capture(app, "01-Home")
        app.buttons["home.wallpaper"].tap()
        XCTAssertTrue(app.navigationBars["壁纸"].waitForExistence(timeout: 5))
        capture(app, "02-Wallpaper-NoCarRequired")
        app.swipeUp()
        XCTAssertTrue(app.buttons["wallpaper.generate"].exists)
        XCTAssertFalse(app.buttons["wallpaper.generate"].isEnabled)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["home.history"].tap()
        XCTAssertTrue(app.navigationBars["历史记录"].waitForExistence(timeout: 5))
        capture(app, "03-History")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["home.cache"].tap()
        XCTAssertTrue(app.navigationBars["CarPlay 壁纸缓存"].waitForExistence(timeout: 5))
        capture(app, "04-Cache")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["home.settings"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        capture(app, "05-Settings")
    }
    func testFirstLaunchGuide() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-CCGuideSeen", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["guide.done"].waitForExistence(timeout: 15))
        capture(app, "06-FirstLaunchGuide")
        app.buttons["guide.done"].tap()
        XCTAssertTrue(app.buttons["home.wallpaper"].waitForExistence(timeout: 5))
    }
    func testMakerPresetsAndAdjustment() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-CCGuideSeen", "YES", "-MakerUITestFixture"]
        app.launch()
        app.buttons["home.wallpaper"].tap()
        XCTAssertTrue(app.buttons["maker.adjust"].waitForExistence(timeout: 15))
        capture(app, "07-Maker-Photo")
        app.buttons["maker.adjust"].tap()
        XCTAssertTrue(app.navigationBars["调整壁纸"].waitForExistence(timeout: 5))
        let presets = app.buttons["maker.presets"]
        XCTAssertTrue(presets.waitForExistence(timeout: 5))
        presets.tap()
        app.buttons["自由裁剪"].tap()
        XCTAssertTrue(app.textFields["宽度（像素）"].exists)
        XCTAssertTrue(app.textFields["高度（像素）"].exists)
        app.buttons["旋转"].tap()
        capture(app, "09-Adjustment")
        app.buttons["还原"].tap()
        app.buttons["确定"].tap()
        XCTAssertTrue(app.navigationBars["壁纸"].waitForExistence(timeout: 5))
    }
}
