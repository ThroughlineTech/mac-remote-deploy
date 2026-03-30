@testable import RemoteDeploy
import Foundation

final class MockPushNotifier: PushNotifying, @unchecked Sendable {

    // MARK: - send(title:message:priority:url:)

    var sendCallCount = 0
    var lastSendTitle: String?
    var lastSendMessage: String?
    var lastSendPriority: PushPriority?
    var lastSendURL: String?
    var sendShouldThrow: Error?

    /// All calls recorded as tuples for multi-call assertions.
    var sendCalls: [(title: String, message: String, priority: PushPriority, url: String?)] = []

    func send(title: String, message: String, priority: PushPriority, url: String?) async throws {
        sendCallCount += 1
        lastSendTitle = title
        lastSendMessage = message
        lastSendPriority = priority
        lastSendURL = url
        sendCalls.append((title: title, message: message, priority: priority, url: url))
        if let error = sendShouldThrow { throw error }
    }

    // MARK: - sendTest()

    var sendTestCallCount = 0
    var sendTestShouldThrow: Error?

    func sendTest() async throws {
        sendTestCallCount += 1
        if let error = sendTestShouldThrow { throw error }
    }
}
