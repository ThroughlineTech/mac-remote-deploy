@testable import RemoteDeploy
import Foundation

final class MockSchemeDetector: SchemeDetecting, @unchecked Sendable {
    var stubbedSchemes: [String] = []

    var detectSchemesCallCount = 0
    var lastPath: String?

    func detectSchemes(atPath path: String) -> [String] {
        detectSchemesCallCount += 1
        lastPath = path
        return stubbedSchemes
    }
}
