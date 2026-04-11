import XCTest

final class ProjectDetailReactiveStatusUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_ProjectDetailShowsBuildingStateImmediatelyAfterTrigger() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--auto-pair",
            "--pair-url", "http://localhost:8080",
            "--pair-token", "e2etest1",
            "--pair-name", "fubar's Mac mini"
        ]
        app.launch()

        XCTAssertTrue(waitForConnectedUI(in: app), "App did not reach a connected state")

        tapTab("Projects", in: app)

        let firstProject = app.cells.firstMatch
        XCTAssertTrue(firstProject.waitForExistence(timeout: 10), "No project row found in Projects tab")
        firstProject.tap()

        let buildButton = app.buttons["Build & Deploy"].firstMatch
        XCTAssertTrue(buildButton.waitForExistence(timeout: 10), "Build & Deploy button not found on project detail")
        buildButton.tap()

        // Regression assertion for TKT-044: detail view should react in-place
        // right after tapping Build & Deploy.
        let cancelButton = app.buttons["Cancel Build"].firstMatch
        let buildingButton = app.buttons["Building..."].firstMatch
        let buildingText = app.staticTexts["Building..."].firstMatch

        let detailReacted = cancelButton.waitForExistence(timeout: 5)
            || buildingButton.waitForExistence(timeout: 5)
            || buildingText.waitForExistence(timeout: 5)

        XCTAssertTrue(
            detailReacted,
            "Project detail did not show an in-place building state after triggering build"
        )
    }

    private func waitForConnectedUI(in app: XCUIApplication) -> Bool {
        let tabBar = app.tabBars.firstMatch
        if tabBar.waitForExistence(timeout: 8) {
            return true
        }

        // iPad can render tabs in the top bar; Projects title is a good
        // fallback signal that the main connected UI is visible.
        return app.staticTexts["Projects"].waitForExistence(timeout: 10)
    }

    private func tapTab(_ name: String, in app: XCUIApplication) {
        let bottomTab = app.tabBars.buttons[name]
        if bottomTab.exists {
            bottomTab.tap()
            return
        }

        let buttons = app.buttons.matching(identifier: name)
        if buttons.count > 0 {
            buttons.firstMatch.tap()
        }
    }
}
