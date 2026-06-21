// Unit tests for BuildStateReconciler.isBuilding -- the precedence rule the menu
// bar uses to reconcile the live WebSocket "buildstatus" frame against the REST
// poll.
//
// Regression net for the stuck "Cancel Build" spinner: a WebSocket frame that
// missed the terminal transition (e.g. across a reconnect) used to pin the menu
// bar to "building" forever, because the old logic preferred the WS frame over
// the authoritative in-process poll. A terminal poll must always win.
import RemoteDeployShared
import XCTest

final class MenuBarBuildStateTests: XCTestCase {

    // MARK: - Terminal poll wins over a stale WebSocket "building" frame

    func test_terminalPoll_overridesStaleBuildingFrame_success() {
        // THE BUG: build succeeded, but the WS frame is stuck on "building".
        XCTAssertFalse(BuildStateReconciler.isBuilding(polled: "success", live: "building"))
    }

    func test_terminalPoll_overridesStaleBuildingFrame_failure() {
        XCTAssertFalse(BuildStateReconciler.isBuilding(polled: "failure", live: "building"))
    }

    func test_terminalPoll_withMatchingTerminalFrame_isNotBuilding() {
        XCTAssertFalse(BuildStateReconciler.isBuilding(polled: "success", live: "success"))
    }

    func test_terminalPoll_withNoFrameYet_isNotBuilding() {
        XCTAssertFalse(BuildStateReconciler.isBuilding(polled: "success", live: nil))
    }

    // MARK: - WebSocket leads on the active edges

    func test_buildingFrame_aheadOfIdlePoll_isBuilding() {
        // Build just started: the WS frame arrives before the next poll, while
        // the poll still reports the pre-build "idle" state.
        XCTAssertTrue(BuildStateReconciler.isBuilding(polled: "idle", live: "building"))
    }

    func test_buildingFrame_withNoPollYet_isBuilding() {
        XCTAssertTrue(BuildStateReconciler.isBuilding(polled: nil, live: "building"))
    }

    func test_terminalFrame_aheadOfBuildingPoll_isNotBuilding() {
        // Build just ended: the WS terminal frame leads the lagging poll.
        XCTAssertFalse(BuildStateReconciler.isBuilding(polled: "building", live: "success"))
    }

    // MARK: - Steady states and the poll fallback

    func test_bothBuilding_isBuilding() {
        XCTAssertTrue(BuildStateReconciler.isBuilding(polled: "building", live: "building"))
    }

    func test_buildingPoll_withNoFrame_isBuilding() {
        XCTAssertTrue(BuildStateReconciler.isBuilding(polled: "building", live: nil))
    }

    func test_idlePoll_withNoFrame_isNotBuilding() {
        XCTAssertFalse(BuildStateReconciler.isBuilding(polled: "idle", live: nil))
    }

    func test_noSignalsAtAll_isNotBuilding() {
        XCTAssertFalse(BuildStateReconciler.isBuilding(polled: nil, live: nil))
    }
}
