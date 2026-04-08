// Tests for SettingsRouteHandler — get with secret redaction, update with validation.
@testable import RemoteDeploy
import XCTest
import Foundation
import RemoteDeployShared

final class SettingsRouteHandlerTests: XCTestCase {

    private func makeHandler() -> (handler: SettingsRouteHandler, provider: MockSettingsProvider, updater: MockSettingsUpdater) {
        let provider = MockSettingsProvider()
        let updater = MockSettingsUpdater()
        let handler = SettingsRouteHandler(settingsProvider: provider, settingsUpdater: updater)
        return (handler, provider, updater)
    }

    // MARK: - get redaction

    func test_get_redactsCertAndKeyPathsWhenSet() {
        let (handler, provider, _) = makeHandler()
        provider.stubbedSettings = SettingsData(
            serverPort: 8443,
            hostname: "host.tailnet.ts.net",
            certPath: "/etc/cert.pem",
            keyPath: "/etc/key.pem",
            pushNotificationConfig: PushNotificationConfig()
        )
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/settings")
        let response = handler.get(req)
        let decoded = try? APITestSupport.decoder().decode(SettingsData.self, from: response.body)
        XCTAssertEqual(decoded?.certPath, "[configured]")
        XCTAssertEqual(decoded?.keyPath, "[configured]")
        XCTAssertEqual(decoded?.hostname, "host.tailnet.ts.net", "Hostname is not a secret and should pass through")
        XCTAssertEqual(decoded?.serverPort, 8443)
    }

    func test_get_leavesCertAndKeyPathsEmptyWhenUnset() {
        let (handler, provider, _) = makeHandler()
        provider.stubbedSettings = SettingsData() // all empty
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/settings")
        let response = handler.get(req)
        let decoded = try? APITestSupport.decoder().decode(SettingsData.self, from: response.body)
        XCTAssertEqual(decoded?.certPath, "")
        XCTAssertEqual(decoded?.keyPath, "")
    }

    func test_get_redactsAllPushNotificationSecretsWhenSet() {
        let (handler, provider, _) = makeHandler()
        var push = PushNotificationConfig()
        push.prowlAPIKey = "real-prowl-key"
        push.pushoverAppToken = "real-pushover-token"
        push.pushoverUserKey = "real-pushover-user"
        push.ntfyTopic = "real-ntfy-topic"
        provider.stubbedSettings = SettingsData(pushNotificationConfig: push)

        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/settings")
        let response = handler.get(req)
        let decoded = try? APITestSupport.decoder().decode(SettingsData.self, from: response.body)

        XCTAssertEqual(decoded?.pushNotificationConfig.prowlAPIKey, "[redacted]")
        XCTAssertEqual(decoded?.pushNotificationConfig.pushoverAppToken, "[redacted]")
        XCTAssertEqual(decoded?.pushNotificationConfig.pushoverUserKey, "[redacted]")
        XCTAssertEqual(decoded?.pushNotificationConfig.ntfyTopic, "[redacted]")
    }

    func test_get_leavesPushSecretsEmptyWhenUnset() {
        let (handler, provider, _) = makeHandler()
        // Default PushNotificationConfig has all-empty secrets.
        provider.stubbedSettings = SettingsData(pushNotificationConfig: PushNotificationConfig())
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/settings")
        let response = handler.get(req)
        let decoded = try? APITestSupport.decoder().decode(SettingsData.self, from: response.body)
        XCTAssertEqual(decoded?.pushNotificationConfig.prowlAPIKey, "")
        XCTAssertEqual(decoded?.pushNotificationConfig.pushoverAppToken, "")
        XCTAssertEqual(decoded?.pushNotificationConfig.ntfyTopic, "")
    }

    func test_get_callsProviderEachInvocation() {
        let (handler, provider, _) = makeHandler()
        let req = APITestSupport.makeRequest(method: .GET, uri: "/api/v1/settings")
        _ = handler.get(req)
        _ = handler.get(req)
        XCTAssertEqual(provider.currentSettingsCallCount, 2)
    }

    // MARK: - update

    func test_update_callsUpdaterAndReturns200() {
        let (handler, _, updater) = makeHandler()
        let newSettings = SettingsData(serverPort: 9999, hostname: "newhost", certPath: "/new/cert", keyPath: "/new/key")
        let body = try! APITestSupport.encoder().encode(newSettings)
        let req = APITestSupport.makeRequest(method: .PUT, uri: "/api/v1/settings", body: body)
        let response = handler.update(req)
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(updater.updateSettingsCallCount, 1)
        XCTAssertEqual(updater.lastUpdatedSettings?.serverPort, 9999)
        XCTAssertEqual(updater.lastUpdatedSettings?.hostname, "newhost")
    }

    func test_update_returns400ForMalformedBody() {
        let (handler, _, updater) = makeHandler()
        let req = APITestSupport.makeRequest(method: .PUT, uri: "/api/v1/settings", body: Data("not-json".utf8))
        let response = handler.update(req)
        XCTAssertEqual(response.status, .badRequest)
        XCTAssertEqual(updater.updateSettingsCallCount, 0)
    }

    func test_update_returns500WhenUpdaterReturnsError() {
        let (handler, _, updater) = makeHandler()
        updater.stubbedError = "Validation failed: port out of range"
        let body = try! APITestSupport.encoder().encode(SettingsData())
        let req = APITestSupport.makeRequest(method: .PUT, uri: "/api/v1/settings", body: body)
        let response = handler.update(req)
        XCTAssertEqual(response.status, .internalServerError)
    }
}
