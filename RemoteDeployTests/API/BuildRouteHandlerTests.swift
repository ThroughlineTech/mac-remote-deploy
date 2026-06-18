// Tests for BuildRouteHandler — trigger, status, cancel, history endpoints.
@testable import RemoteDeployServer
import XCTest
import Foundation
import RemoteDeployShared

final class BuildRouteHandlerTests: XCTestCase {

    private struct Bag {
        let trigger = MockBuildTrigger()
        let status = MockBuildStatusProvider()
        let canceler = MockBuildCanceler()
        let history = MockBuildHistoryProvider()

        func handler() -> BuildRouteHandler {
            BuildRouteHandler(
                buildTrigger: trigger,
                buildStatus: status,
                buildCanceler: canceler,
                buildHistory: history
            )
        }
    }

    // MARK: - triggerBuild

    func test_triggerBuild_returns202WithCurrentStatus() {
        let bag = Bag()
        bag.status.stubbedStatus = BuildStatusInfo(state: "building", message: "Started")
        let handler = bag.handler()

        let body = try! APITestSupport.encoder().encode(BuildRequest(configuration: "Release"))
        let projectID = UUID()
        let req = APITestSupport.makeRequest(method: .POST, uri: "/api/v1/projects/\(projectID)/build", body: body)
        let response = handler.triggerBuild(req, projectID: projectID)

        XCTAssertEqual(response.status, .accepted)
        XCTAssertEqual(bag.trigger.triggerBuildCallCount, 1)
        XCTAssertEqual(bag.trigger.lastProjectID, projectID)
        XCTAssertEqual(bag.trigger.lastConfiguration, "Release")

        let decoded = try? APITestSupport.decoder().decode(BuildStatusInfo.self, from: response.body)
        XCTAssertEqual(decoded?.state, "building")
        XCTAssertEqual(decoded?.message, "Started")
    }

    func test_triggerBuild_returns409WhenTriggerReportsError() {
        let bag = Bag()
        bag.trigger.stubbedError = "Project not found"
        let handler = bag.handler()
        let projectID = UUID()
        let body = try! APITestSupport.encoder().encode(BuildRequest(configuration: nil))
        let req = APITestSupport.makeRequest(method: .POST, uri: "/api/v1/projects/\(projectID)/build", body: body)
        let response = handler.triggerBuild(req, projectID: projectID)
        XCTAssertEqual(response.status, .conflict)
    }

    func test_triggerBuild_acceptsEmptyBody() {
        // body decoding uses try? — empty body becomes nil BuildRequest, which is acceptable.
        // The handler still calls triggerBuild with configuration: nil.
        let bag = Bag()
        let handler = bag.handler()
        let projectID = UUID()
        let req = APITestSupport.makeRequest(method: .POST, uri: "/api/v1/projects/\(projectID)/build")
        let response = handler.triggerBuild(req, projectID: projectID)
        XCTAssertEqual(response.status, .accepted)
        XCTAssertEqual(bag.trigger.triggerBuildCallCount, 1)
        XCTAssertNil(bag.trigger.lastConfiguration)
    }

    func test_triggerBuild_acceptsMalformedBodyAsNilConfig() {
        let bag = Bag()
        let handler = bag.handler()
        let projectID = UUID()
        let req = APITestSupport.makeRequest(method: .POST, uri: "/api/v1/projects/\(projectID)/build", body: Data("garbage".utf8))
        let response = handler.triggerBuild(req, projectID: projectID)
        XCTAssertEqual(response.status, .accepted, "Body decode is best-effort; nil falls through to nil configuration")
        XCTAssertNil(bag.trigger.lastConfiguration)
    }

    // MARK: - getBuildStatus

    func test_getBuildStatus_returnsProviderStatus() {
        let bag = Bag()
        bag.status.stubbedStatus = BuildStatusInfo(state: "success", message: "/path/to.ipa")
        let handler = bag.handler()
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/projects/\(UUID())/build")
        let response = handler.getBuildStatus(req, projectID: UUID())
        XCTAssertEqual(response.status, .ok)
        let decoded = try? APITestSupport.decoder().decode(BuildStatusInfo.self, from: response.body)
        XCTAssertEqual(decoded?.state, "success")
        XCTAssertEqual(decoded?.message, "/path/to.ipa")
    }

    // MARK: - cancelBuild

    func test_cancelBuild_returns200WhenCancelSucceeds() {
        let bag = Bag()
        bag.canceler.stubbedResult = true
        let handler = bag.handler()
        let req = APITestSupport.makeRequest(method: .DELETE, uri: "/api/v1/projects/\(UUID())/build")
        let response = handler.cancelBuild(req, projectID: UUID())
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(bag.canceler.cancelCurrentBuildCallCount, 1)
    }

    func test_cancelBuild_returns409WhenNothingToCancel() {
        let bag = Bag()
        bag.canceler.stubbedResult = false
        let handler = bag.handler()
        let req = APITestSupport.makeRequest(method: .DELETE, uri: "/api/v1/projects/\(UUID())/build")
        let response = handler.cancelBuild(req, projectID: UUID())
        XCTAssertEqual(response.status, .conflict)
    }

    // MARK: - getBuildHistory

    func test_getBuildHistory_returnsEmptyArrayByDefault() {
        let bag = Bag()
        let handler = bag.handler()
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/builds")
        let response = handler.getBuildHistory(req)
        XCTAssertEqual(response.status, .ok)
        let decoded = try? APITestSupport.decoder().decode([BuildResult].self, from: response.body)
        XCTAssertEqual(decoded?.count, 0)
    }

    func test_getBuildHistory_returnsProvidedBuilds() {
        let bag = Bag()
        let now = Date()
        bag.history.stubbedBuilds = [
            BuildResult(projectID: UUID(), success: true, ipaPath: "/tmp/a.ipa", buildLog: "ok", startTime: now, endTime: now),
            BuildResult(projectID: UUID(), success: false, errorSummary: "build failed", buildLog: "fail", startTime: now, endTime: now)
        ]
        let handler = bag.handler()
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/builds")
        let response = handler.getBuildHistory(req)
        XCTAssertEqual(response.status, .ok)
        let decoded = try? APITestSupport.decoder().decode([BuildResult].self, from: response.body)
        XCTAssertEqual(decoded?.count, 2)
        XCTAssertTrue(decoded?[0].success ?? false)
        XCTAssertFalse(decoded?[1].success ?? true)
    }
}
