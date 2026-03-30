@testable import RemoteDeploy
import Foundation

final class MockInstallTracker: InstallTracking, @unchecked Sendable {

    // MARK: - Internal storage

    var records: [InstallRecord] = []

    // MARK: - recordInstall(projectName:sourceIP:userAgent:)

    var recordInstallCallCount = 0
    var lastRecordedProjectName: String?
    var lastRecordedSourceIP: String?
    var lastRecordedUserAgent: String?

    func recordInstall(projectName: String, sourceIP: String, userAgent: String) async {
        recordInstallCallCount += 1
        lastRecordedProjectName = projectName
        lastRecordedSourceIP = sourceIP
        lastRecordedUserAgent = userAgent
        let record = InstallRecord(
            id: UUID(),
            projectName: projectName,
            sourceIP: sourceIP,
            userAgent: userAgent,
            timestamp: Date()
        )
        records.insert(record, at: 0)
    }

    // MARK: - recentInstalls(limit:)

    var recentInstallsCallCount = 0
    var lastRecentInstallsLimit: Int?

    func recentInstalls(limit: Int) async -> [InstallRecord] {
        recentInstallsCallCount += 1
        lastRecentInstallsLimit = limit
        return Array(records.prefix(limit))
    }
}
