// Unit tests for AuthMiddleware's WebSocket authentication path. Browsers can't
// set the Authorization header on a WS handshake, so authenticateWebSocket also
// accepts the bearer token carried in the Sec-WebSocket-Protocol subprotocol
// ("bearer, <token>"). The REST-path authenticate(headers:) must keep ignoring
// it. TKT-058.
import XCTest
import RemoteDeployShared
@testable import RemoteDeployServer

final class AuthMiddlewareWebSocketTests: XCTestCase {

    private var tempDir: URL!
    private var store: JSONPairedDeviceStore!
    private var auth: AuthMiddleware!
    private var token: String!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuthMiddlewareWSTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = JSONPairedDeviceStore(directory: tempDir)
        auth = AuthMiddleware(deviceStore: store)
        token = JSONPairedDeviceStore.generateToken()
        let device = PairedDevice(name: "Browser", tokenHash: JSONPairedDeviceStore.hashToken(token))
        try store.save(device: device)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    func testAuthorizationHeaderStillAuthenticates() {
        XCTAssertNotNil(auth.authenticateWebSocket(headers: [("Authorization", "Bearer \(token!)")]))
    }

    func testSubprotocolAuthenticates() {
        let device = auth.authenticateWebSocket(headers: [("Sec-WebSocket-Protocol", "bearer, \(token!)")])
        XCTAssertEqual(device?.name, "Browser")
    }

    func testSubprotocolHeaderNameIsCaseInsensitive() {
        XCTAssertNotNil(auth.authenticateWebSocket(headers: [("sec-websocket-protocol", "bearer, \(token!)")]))
    }

    func testSubprotocolWithUnknownTokenRejected() {
        XCTAssertNil(auth.authenticateWebSocket(headers: [("Sec-WebSocket-Protocol", "bearer, deadbeef")]))
    }

    func testSubprotocolMarkerWithoutTokenRejected() {
        XCTAssertNil(auth.authenticateWebSocket(headers: [("Sec-WebSocket-Protocol", "bearer")]))
    }

    func testNoCredentialsRejected() {
        XCTAssertNil(auth.authenticateWebSocket(headers: []))
    }

    /// The REST authenticator must not honor the subprotocol fallback.
    func testRestAuthenticateIgnoresSubprotocol() {
        XCTAssertNil(auth.authenticate(headers: [("Sec-WebSocket-Protocol", "bearer, \(token!)")]))
    }
}
