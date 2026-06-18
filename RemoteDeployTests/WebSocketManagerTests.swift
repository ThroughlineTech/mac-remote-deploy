// Unit tests for WebSocketManager from TKT-011. Uses NIO's EmbeddedChannel
// to exercise addClient/removeClient/subscribe/broadcast/connectionCount
// without a real network stack.
//
// NOTE: The full NIO HTTP-upgrade wiring (WebSocketUpgrader hooked into
// NIODeployServer's pipeline) + bearer-token authentication at the upgrade
// level + the iOS WebSocketClient reconnect-with-backoff work are explicitly
// deferred. The WebSocket path is dead code per the security audit (accepted
// risk #5) and wiring it up requires a coordinated change spanning
// NIODeployServer, the iOS client, and additional tests. This ticket delivers
// unit coverage for the manager's internal state machine so future wiring
// work has a regression net.
@testable import RemoteDeployServer
import XCTest
import Foundation
import NIO
import NIOWebSocket
import RemoteDeployShared

final class WebSocketManagerTests: XCTestCase {

    /// Creates an EmbeddedChannel we can use to stand in for a real WebSocket client.
    /// Each call returns a fresh channel; callers should finish() it in teardown.
    private func makeChannel() -> EmbeddedChannel {
        EmbeddedChannel()
    }

    // MARK: - addClient / removeClient / connectionCount

    func test_addClient_incrementsConnectionCount() throws {
        let manager = WebSocketManager()
        XCTAssertEqual(manager.connectionCount, 0)

        let ch = makeChannel()
        manager.addClient(ch)
        XCTAssertEqual(manager.connectionCount, 1)

        _ = try ch.finish()
    }

    func test_removeClient_decrementsConnectionCount() throws {
        let manager = WebSocketManager()
        let ch = makeChannel()
        manager.addClient(ch)
        XCTAssertEqual(manager.connectionCount, 1)

        manager.removeClient(ch)
        XCTAssertEqual(manager.connectionCount, 0)

        _ = try ch.finish()
    }

    func test_addClient_multipleClientsAreIndependent() throws {
        let manager = WebSocketManager()
        let ch1 = makeChannel()
        let ch2 = makeChannel()
        let ch3 = makeChannel()
        manager.addClient(ch1)
        manager.addClient(ch2)
        manager.addClient(ch3)
        XCTAssertEqual(manager.connectionCount, 3)

        manager.removeClient(ch2)
        XCTAssertEqual(manager.connectionCount, 2)

        _ = try ch1.finish()
        _ = try ch2.finish()
        _ = try ch3.finish()
    }

    // MARK: - subscribe

    func test_subscribe_routesBroadcastToSubscribersOnly() throws {
        let manager = WebSocketManager()
        let subscribed = makeChannel()
        let unsubscribed = makeChannel()

        manager.addClient(subscribed)
        manager.addClient(unsubscribed)
        manager.subscribe(subscribed, to: "buildlog")

        manager.broadcast(type: "buildlog", payload: "hello world")

        // The subscribed channel should have received a frame; the other should not.
        let subscribedFrame = try subscribed.readOutbound(as: WebSocketFrame.self)
        XCTAssertNotNil(subscribedFrame, "Subscribed client should have received a frame")

        let unsubscribedFrame = try unsubscribed.readOutbound(as: WebSocketFrame.self)
        XCTAssertNil(unsubscribedFrame, "Unsubscribed client should not have received a frame")

        _ = try subscribed.finish()
        _ = try unsubscribed.finish()
    }

    func test_broadcast_sendsJSONEncodedWSMessage() throws {
        let manager = WebSocketManager()
        let ch = makeChannel()
        manager.addClient(ch)
        manager.subscribe(ch, to: "buildstatus")

        manager.broadcast(type: "buildstatus", payload: "success")

        guard let frame = try ch.readOutbound(as: WebSocketFrame.self) else {
            XCTFail("Expected a frame to be written")
            return
        }
        XCTAssertEqual(frame.opcode, .text)

        var data = frame.data
        let text = data.readString(length: data.readableBytes) ?? ""
        // The broadcast encodes a WSMessage as JSON.
        XCTAssertTrue(text.contains("\"type\""))
        XCTAssertTrue(text.contains("buildstatus"))
        XCTAssertTrue(text.contains("\"payload\""))
        XCTAssertTrue(text.contains("success"))

        _ = try ch.finish()
    }

    // MARK: - broadcast with no subscribers

    func test_broadcast_withNoSubscribers_isNoOp() throws {
        let manager = WebSocketManager()
        manager.broadcast(type: "buildlog", payload: "nobody home")
        // No crash, no state change.
        XCTAssertEqual(manager.connectionCount, 0)
    }

    // MARK: - broadcast after unsubscribe (via removeClient)

    func test_removedClient_doesNotReceiveFurtherBroadcasts() throws {
        let manager = WebSocketManager()
        let ch = makeChannel()
        manager.addClient(ch)
        manager.subscribe(ch, to: "buildlog")
        manager.removeClient(ch)

        manager.broadcast(type: "buildlog", payload: "should not arrive")
        let frame = try ch.readOutbound(as: WebSocketFrame.self)
        XCTAssertNil(frame, "Removed client should not receive broadcasts")

        _ = try ch.finish()
    }
}
