@testable import RemoteDeployServer
import Foundation

final class MockSchemeDetector: SchemeDetecting, @unchecked Sendable {
    var stubbedSchemes: [String] = []
    /// When set, `detectSchemes` throws this instead of returning `stubbedSchemes`.
    var stubbedError: Error?

    var detectSchemesCallCount = 0
    var lastPath: String?

    func detectSchemes(atPath path: String) throws -> [String] {
        detectSchemesCallCount += 1
        lastPath = path
        if let stubbedError { throw stubbedError }
        return stubbedSchemes
    }
}
