import XCTest

final class ScreenshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    func test_CaptureAllScreenshots() throws {
        // ── 1. Discovery screen (unpaired) ──
        let freshApp = XCUIApplication()
        freshApp.launchArguments = ["--reset-pairing"]
        freshApp.launch()
        sleep(3)
        save("01-discovery")
        freshApp.terminate()
        sleep(1)

        // ── 2. Launch paired via launch arguments ──
        let app = XCUIApplication()
        app.launchArguments = [
            "--auto-pair",
            "--pair-url", "http://localhost:8080",
            "--pair-token", "e2etest1",
            "--pair-name", "fubar's Mac mini"
        ]
        app.launch()
        sleep(5)

        // Tab bar might be at the bottom (iPhone) or top (iPad)
        let bottomTabBar = app.tabBars.firstMatch
        let hasBottomTabs = bottomTabBar.waitForExistence(timeout: 5)

        // Helper to tap a tab — tries bottom tab bar first, then top tab section
        func tapTab(_ name: String) {
            if hasBottomTabs {
                app.tabBars.buttons[name].tap()
            } else {
                // iPad top tab bar — buttons are in a specific container
                // Use the first matching button that isn't a navigation title
                let buttons = app.buttons.matching(identifier: name)
                if buttons.count > 0 {
                    buttons.firstMatch.tap()
                }
            }
        }

        // Check we're connected — look for either tab bar or project content
        let connected = hasBottomTabs || app.staticTexts["Projects"].waitForExistence(timeout: 10)
        guard connected else {
            save("ERROR-no-tabs")
            XCTFail("App did not connect — no tabs or project content found")
            return
        }

        // Projects tab
        tapTab("Projects")
        sleep(2)
        save("02-projects")

        // Project detail
        let firstCell = app.cells.firstMatch
        if firstCell.waitForExistence(timeout: 5) {
            firstCell.tap()
            sleep(2)
            save("03-project-detail")
            app.navigationBars.buttons.firstMatch.tap()
            sleep(1)
        }

        // Build tab
        tapTab("Build")
        sleep(2)
        save("04-build")

        // Installs tab
        tapTab("Installs")
        sleep(2)
        save("05-installs")

        // Settings tab
        tapTab("Settings")
        sleep(2)
        save("06-settings")

        // About page
        let aboutText = app.staticTexts["About RemoteDeploy"]
        if aboutText.waitForExistence(timeout: 3) {
            aboutText.tap()
            sleep(2)
            save("07-about")
        }
    }

    private func save(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let data = screenshot.pngRepresentation
        let dir = "/tmp/rd-screenshots"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: "\(dir)/\(name).png", contents: data)
    }
}
