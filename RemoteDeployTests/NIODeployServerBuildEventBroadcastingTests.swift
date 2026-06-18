// Unit tests for NIODeployServer's BuildEventBroadcasting conformance.
// Drives the extension methods against an unstarted NIODeployServer
// whose WebSocketManager is wired to an EmbeddedChannel subscriber.
// TKT-027.
@testable import RemoteDeployServer
import XCTest
import Foundation
import NIO
import NIOWebSocket
import RemoteDeployShared

final class NIODeployServerBuildEventBroadcastingTests: XCTestCase {

    private var server: NIODeployServer!
    private var subscriberChannel: EmbeddedChannel!

    override func setUp() {
        super.setUp()
        server = NIODeployServer(
            manifestGenerator: ManifestGenerator(),
            installPageGenerator: InstallPageGenerator(),
            serveRoot: FileManager.default.temporaryDirectory.path
        )
        subscriberChannel = EmbeddedChannel()
    }

    override func tearDown() {
        _ = try? subscriberChannel.finish()
        subscriberChannel = nil
        server = nil
        super.tearDown()
    }

    /// Reads the next outbound frame and returns it as a UTF-8 string, or
    /// nil if nothing was written.
    private func nextFrameText() throws -> String? {
        guard var frame = try subscriberChannel.readOutbound(as: WebSocketFrame.self) else {
            return nil
        }
        var buf = frame.data
        return buf.readString(length: buf.readableBytes)
    }

    // MARK: - broadcastBuildLog

    func test_broadcastBuildLog_sendsBuildlogChannelFrame() throws {
        server.webSocketManager.addClient(subscriberChannel)
        server.webSocketManager.subscribe(subscriberChannel, to: "buildlog")

        server.broadcastBuildLog("compiling Foo.swift")

        let text = try nextFrameText() ?? ""
        let envelope = try JSONDecoder().decode(WSMessage.self, from: Data(text.utf8))
        XCTAssertEqual(envelope.type, "buildlog")
        XCTAssertEqual(envelope.payload, "compiling Foo.swift")
    }

    func test_broadcastBuildLog_notDeliveredToUnsubscribedClients() throws {
        server.webSocketManager.addClient(subscriberChannel)
        // Do NOT subscribe to "buildlog"

        server.broadcastBuildLog("should not arrive")

        XCTAssertNil(try nextFrameText(), "Client not subscribed to buildlog must not receive the frame")
    }

    // MARK: - broadcastBuildStatus

    /// Parses the outer WSMessage envelope and returns the inner payload
    /// string (which, for buildstatus frames, is itself JSON-encoded
    /// BuildStatusInfo). Bails the test if the frame isn't present or
    /// isn't shaped as expected.
    private func nextBuildStatusPayload() throws -> String {
        let text = try nextFrameText() ?? ""
        // The WSMessage envelope has the shape:
        //   {"type":"buildstatus","payload":"<inner JSON>"}
        // where <inner JSON> is `{\"state\":\"idle\"...}` after escaping.
        // Decoding the outer envelope gives us the real inner string.
        guard let data = text.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(WSMessage.self, from: data) else {
            XCTFail("Expected a WSMessage envelope, got: \(text)")
            return ""
        }
        XCTAssertEqual(envelope.type, "buildstatus")
        return envelope.payload
    }

    func test_broadcastBuildStatus_idle_sendsStateIdle() throws {
        server.webSocketManager.addClient(subscriberChannel)
        server.webSocketManager.subscribe(subscriberChannel, to: "buildstatus")

        server.broadcastBuildStatus(.idle)

        let payload = try nextBuildStatusPayload()
        let info = try XCTUnwrap(try JSONDecoder().decode(BuildStatusInfo.self, from: Data(payload.utf8)))
        XCTAssertEqual(info.state, "idle")
        XCTAssertNil(info.message)
    }

    func test_broadcastBuildStatus_building_carriesProgressMessage() throws {
        server.webSocketManager.addClient(subscriberChannel)
        server.webSocketManager.subscribe(subscriberChannel, to: "buildstatus")

        server.broadcastBuildStatus(.building(progress: "Archiving..."))

        let payload = try nextBuildStatusPayload()
        let info = try JSONDecoder().decode(BuildStatusInfo.self, from: Data(payload.utf8))
        XCTAssertEqual(info.state, "building")
        XCTAssertEqual(info.message, "Archiving...")
    }

    func test_broadcastBuildStatus_success_carriesIpaPath() throws {
        server.webSocketManager.addClient(subscriberChannel)
        server.webSocketManager.subscribe(subscriberChannel, to: "buildstatus")

        server.broadcastBuildStatus(.success(ipaPath: "/tmp/app.ipa"))

        let payload = try nextBuildStatusPayload()
        let info = try JSONDecoder().decode(BuildStatusInfo.self, from: Data(payload.utf8))
        XCTAssertEqual(info.state, "success")
        XCTAssertEqual(info.message, "/tmp/app.ipa")
    }

    func test_broadcastBuildStatus_failure_carriesErrorMessage() throws {
        server.webSocketManager.addClient(subscriberChannel)
        server.webSocketManager.subscribe(subscriberChannel, to: "buildstatus")

        server.broadcastBuildStatus(.failure(error: "code sign error"))

        let payload = try nextBuildStatusPayload()
        let info = try JSONDecoder().decode(BuildStatusInfo.self, from: Data(payload.utf8))
        XCTAssertEqual(info.state, "failure")
        XCTAssertEqual(info.message, "code sign error")
    }

    // MARK: - broadcastInstall

    func test_broadcastInstall_sendsInstallChannelFrameWithSlugAndIP() throws {
        server.webSocketManager.addClient(subscriberChannel)
        server.webSocketManager.subscribe(subscriberChannel, to: "install")

        server.broadcastInstall(slug: "myapp", sourceIP: "100.64.0.5")

        let text = try nextFrameText() ?? ""
        let envelope = try JSONDecoder().decode(WSMessage.self, from: Data(text.utf8))
        XCTAssertEqual(envelope.type, "install")
        // Payload is a small JSON dict with slug + sourceIP.
        let payload = try JSONSerialization.jsonObject(with: Data(envelope.payload.utf8)) as? [String: String]
        XCTAssertEqual(payload?["slug"], "myapp")
        XCTAssertEqual(payload?["sourceIP"], "100.64.0.5")
    }

    // MARK: - buildStatusInfo helper

    func test_buildStatusInfo_mapsAllFourCases() {
        XCTAssertEqual(NIODeployServer.buildStatusInfo(from: .idle).state, "idle")
        XCTAssertEqual(NIODeployServer.buildStatusInfo(from: .building(progress: "x")).state, "building")
        XCTAssertEqual(NIODeployServer.buildStatusInfo(from: .building(progress: "x")).message, "x")
        XCTAssertEqual(NIODeployServer.buildStatusInfo(from: .success(ipaPath: "/tmp/a")).state, "success")
        XCTAssertEqual(NIODeployServer.buildStatusInfo(from: .success(ipaPath: "/tmp/a")).message, "/tmp/a")
        XCTAssertEqual(NIODeployServer.buildStatusInfo(from: .failure(error: "err")).state, "failure")
        XCTAssertEqual(NIODeployServer.buildStatusInfo(from: .failure(error: "err")).message, "err")
    }
}
