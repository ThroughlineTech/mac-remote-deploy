import Foundation

/// Sends push notifications via an ntfy server.
/// Conforms to `PushNotifying` so it can be used interchangeably
/// with other notification providers.
final class NtfyNotifier: PushNotifying {

    /// The base URL of the ntfy server (e.g., "https://ntfy.sh").
    /// Must be set before calling `send` or `sendTest`.
    var serverURL: String

    /// The topic name to publish notifications to.
    /// Must be set before calling `send` or `sendTest`.
    var topic: String

    /// Creates a notifier with the given server configuration.
    /// - Parameters:
    ///   - serverURL: The base URL of the ntfy server. Defaults to empty.
    ///   - topic: The topic to publish to. Defaults to empty.
    init(serverURL: String = "", topic: String = "") {
        self.serverURL = serverURL
        self.topic = topic
    }

    /// Sends a push notification through the ntfy server.
    /// - Parameters:
    ///   - title: The notification title shown on the device.
    ///   - message: The notification body text, sent as the request body.
    ///   - priority: The delivery urgency, mapped to ntfy's 1-5 scale.
    ///   - url: An optional URL attached via the Click header.
    /// - Throws: `NtfyError` if configuration is missing, the server returns
    ///   a non-200 status, or the request fails.
    func send(title: String, message: String, priority: PushPriority, url: String?) async throws {
        guard !serverURL.isEmpty else {
            throw NtfyError.missingServerURL
        }
        guard !topic.isEmpty else {
            throw NtfyError.missingTopic
        }

        let baseURL = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        guard let endpoint = URL(string: "\(baseURL)/\(topic)") else {
            throw NtfyError.invalidURL(serverURL: serverURL, topic: topic)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = message.data(using: .utf8)
        request.setValue(title, forHTTPHeaderField: "Title")
        request.setValue(String(mapPriority(priority)), forHTTPHeaderField: "Priority")

        if let url, !url.isEmpty {
            request.setValue(url, forHTTPHeaderField: "Click")
        }

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NtfyError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw NtfyError.httpError(statusCode: httpResponse.statusCode)
        }
    }

    /// Sends a test notification to verify the ntfy server is reachable.
    /// - Throws: `NtfyError` if delivery fails.
    func sendTest() async throws {
        try await send(
            title: "RemoteDeploy",
            message: "Test notification successful!",
            priority: .normal,
            url: nil
        )
    }

    // MARK: - Private

    /// Maps a `PushPriority` value to ntfy's 1-5 integer scale.
    private func mapPriority(_ priority: PushPriority) -> Int {
        switch priority {
        case .low:    return 2
        case .normal: return 3
        case .high:   return 4
        }
    }
}

/// Errors specific to the ntfy notification service.
enum NtfyError: LocalizedError {
    case missingServerURL
    case missingTopic
    case invalidURL(serverURL: String, topic: String)
    case invalidResponse
    case httpError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .missingServerURL:
            return "ntfy server URL is not set."
        case .missingTopic:
            return "ntfy topic is not set."
        case .invalidURL(let serverURL, let topic):
            return "Could not construct a valid URL from server '\(serverURL)' and topic '\(topic)'."
        case .invalidResponse:
            return "ntfy returned an invalid response."
        case .httpError(let statusCode):
            return "ntfy request failed with HTTP status \(statusCode)."
        }
    }
}
