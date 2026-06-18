import XCTest
@testable import RemoteDeployServer

final class BuildResultTests: XCTestCase {

    // MARK: - Duration Computed Property

    func testDurationReturnsElapsedTime() {
        let start = Date(timeIntervalSince1970: 1000)
        let end = Date(timeIntervalSince1970: 1120)

        let result = BuildResult(
            id: UUID(),
            projectID: UUID(),
            success: true,
            ipaPath: "/path/to/app.ipa",
            errorSummary: nil,
            buildLog: "Build succeeded",
            startTime: start,
            endTime: end,
            version: "1.0.0",
            buildNumber: "42"
        )

        XCTAssertEqual(result.duration, 120, accuracy: 0.001, "Duration should be 120 seconds")
    }

    func testDurationIsZeroWhenStartEqualsEnd() {
        let time = Date(timeIntervalSince1970: 5000)

        let result = BuildResult(
            id: UUID(),
            projectID: UUID(),
            success: true,
            ipaPath: nil,
            errorSummary: nil,
            buildLog: "",
            startTime: time,
            endTime: time,
            version: nil,
            buildNumber: nil
        )

        XCTAssertEqual(result.duration, 0, accuracy: 0.001, "Duration should be zero when start equals end")
    }

    func testDurationWithFractionalSeconds() {
        let start = Date(timeIntervalSince1970: 1000.0)
        let end = Date(timeIntervalSince1970: 1000.5)

        let result = BuildResult(
            id: UUID(),
            projectID: UUID(),
            success: true,
            ipaPath: nil,
            errorSummary: nil,
            buildLog: "",
            startTime: start,
            endTime: end,
            version: nil,
            buildNumber: nil
        )

        XCTAssertEqual(result.duration, 0.5, accuracy: 0.001, "Duration should handle fractional seconds")
    }

    func testDurationWithLongBuild() {
        let start = Date(timeIntervalSince1970: 0)
        let end = Date(timeIntervalSince1970: 3600) // 1 hour

        let result = BuildResult(
            id: UUID(),
            projectID: UUID(),
            success: false,
            ipaPath: nil,
            errorSummary: "Timeout",
            buildLog: "...",
            startTime: start,
            endTime: end,
            version: nil,
            buildNumber: nil
        )

        XCTAssertEqual(result.duration, 3600, accuracy: 0.001, "Duration should handle long build times")
    }

    // MARK: - Codable Round-Trip

    func testCodableRoundTripForSuccessfulBuild() throws {
        let projectID = UUID()
        let start = Date(timeIntervalSince1970: 1000)
        let end = Date(timeIntervalSince1970: 1120)

        let original = BuildResult(
            id: UUID(),
            projectID: projectID,
            success: true,
            ipaPath: "/builds/app.ipa",
            errorSummary: nil,
            buildLog: "Build succeeded\nArchive succeeded",
            startTime: start,
            endTime: end,
            version: "2.1.0",
            buildNumber: "55"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BuildResult.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.projectID, original.projectID)
        XCTAssertEqual(decoded.success, true)
        XCTAssertEqual(decoded.ipaPath, "/builds/app.ipa")
        XCTAssertNil(decoded.errorSummary)
        XCTAssertEqual(decoded.buildLog, "Build succeeded\nArchive succeeded")
        XCTAssertEqual(decoded.version, "2.1.0")
        XCTAssertEqual(decoded.buildNumber, "55")
        XCTAssertEqual(decoded.duration, original.duration, accuracy: 1.0)
    }

    func testCodableRoundTripForFailedBuild() throws {
        let start = Date(timeIntervalSince1970: 2000)
        let end = Date(timeIntervalSince1970: 2030)

        let original = BuildResult(
            id: UUID(),
            projectID: UUID(),
            success: false,
            ipaPath: nil,
            errorSummary: "Signing failed: no valid profiles",
            buildLog: "error: ...",
            startTime: start,
            endTime: end,
            version: nil,
            buildNumber: nil
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BuildResult.self, from: data)

        XCTAssertEqual(decoded.success, false)
        XCTAssertNil(decoded.ipaPath)
        XCTAssertEqual(decoded.errorSummary, "Signing failed: no valid profiles")
        XCTAssertNil(decoded.version)
        XCTAssertNil(decoded.buildNumber)
    }

    func testCodableRoundTripPreservesDuration() throws {
        let start = Date(timeIntervalSince1970: 1000)
        let end = Date(timeIntervalSince1970: 1045)

        let original = BuildResult(
            id: UUID(),
            projectID: UUID(),
            success: true,
            ipaPath: nil,
            errorSummary: nil,
            buildLog: "",
            startTime: start,
            endTime: end,
            version: nil,
            buildNumber: nil
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BuildResult.self, from: data)

        // Duration is computed from start/end, so if dates round-trip correctly,
        // duration should be preserved.
        XCTAssertEqual(decoded.duration, 45, accuracy: 1.0)
    }
}
