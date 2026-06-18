// Shared helpers for the API route handler test suite (TKT-003).
// All API test files import this to build APIRequests, decode responses,
// and seed test data into mock stores.
@testable import RemoteDeployServer
import Foundation
import XCTest
import NIOHTTP1
import RemoteDeployShared

enum APITestSupport {

    /// Builds an APIRequest with the given method, URI, optional body, and optional bearer token.
    /// - Parameters:
    ///   - method: HTTP method
    ///   - uri: Full URI including query string (e.g. "/api/v1/projects?limit=5")
    ///   - body: Optional request body bytes
    ///   - bearerToken: Optional raw bearer token added as `Authorization: Bearer <token>`
    /// - Returns: A fully populated `APIRequest` ready for `router.handle(_:)` or direct handler dispatch.
    static func makeRequest(
        method: HTTPMethod,
        uri: String,
        body: Data = Data(),
        bearerToken: String? = nil,
        extraHeaders: [(String, String)] = []
    ) -> APIRequest {
        var headers = HTTPHeaders()
        if let token = bearerToken {
            headers.add(name: "Authorization", value: "Bearer \(token)")
        }
        for (name, value) in extraHeaders {
            headers.add(name: name, value: value)
        }
        let head = HTTPRequestHead(version: .init(major: 1, minor: 1), method: method, uri: uri, headers: headers)
        return APIRequest(head: head, body: body)
    }

    /// JSONDecoder configured to match the encoder used by `APIResponse.json` (ISO8601 dates).
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// JSONEncoder configured to match the decoder used by route handlers (ISO8601 dates).
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    /// Pairs a device with a unique raw token in the mock store and returns the raw token.
    /// Used by tests that need a valid bearer token to hit authenticated endpoints.
    /// - Parameters:
    ///   - store: The mock device store to seed.
    ///   - name: Display name for the paired device.
    /// - Returns: The raw bearer token (un-hashed) for use in `Authorization: Bearer ...`.
    @discardableResult
    static func pairDevice(in store: MockPairedDeviceStore, name: String = "iPhone") -> String {
        let token = "test-token-\(UUID().uuidString)"
        let hash = JSONPairedDeviceStore.hashToken(token)
        let device = PairedDevice(name: name, tokenHash: hash)
        store.devices.append(device)
        return token
    }

    /// Convenience for tests that need a real device record alongside its token.
    static func pairDeviceReturningRecord(in store: MockPairedDeviceStore, name: String = "iPhone") -> (token: String, device: PairedDevice) {
        let token = "test-token-\(UUID().uuidString)"
        let hash = JSONPairedDeviceStore.hashToken(token)
        let device = PairedDevice(name: name, tokenHash: hash)
        store.devices.append(device)
        return (token, device)
    }

    /// Builds a `ProjectConfig` with sensible defaults for a test fixture.
    static func makeProject(name: String = "TestApp", path: String = "/Users/test/TestApp.xcodeproj") -> ProjectConfig {
        ProjectConfig(name: name, projectPath: path)
    }
}
