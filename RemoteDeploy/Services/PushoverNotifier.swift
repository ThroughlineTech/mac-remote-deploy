import Foundation

/// Sends push notifications via the Pushover service.
/// Conforms to `PushNotifying` so it can be used interchangeably
/// with other notification providers.
final class PushoverNotifier: PushNotifying {

    /// The Pushover application token used to authenticate requests.
    let appToken: String

    /// The Pushover user key identifying the notification recipient.
    let userKey: String

    /// Creates a notifier with the given credentials.
    /// - Parameters:
    ///   - appToken: A valid Pushover application token. Defaults to empty.
    ///   - userKey: The recipient's Pushover user key. Defaults to empty.
    init(appToken: String = "", userKey: String = "") {
        self.appToken = appToken
        self.userKey = userKey
    }

    /// Sends a push notification through Pushover.
    /// - Parameters:
    ///   - title: The notification title shown on the device.
    ///   - message: The notification body text.
    ///   - priority: The delivery urgency, mapped to Pushover's -2..2 scale.
    ///   - url: An optional URL the user can tap to open.
    /// - Throws: `PushoverError` if credentials are missing, the server returns
    ///   a non-200 status, or the request fails.
    func send(title: String, message: String, priority: PushPriority, url: String?) async throws {
        guard !appToken.isEmpty else {
            throw PushoverError.missingAppToken
        }
        guard !userKey.isEmpty else {
            throw PushoverError.missingUserKey
        }

        let endpoint = URL(string: "https://api.pushover.net/1/messages.json")!

        var bodyComponents = URLComponents()
        var queryItems = [
            URLQueryItem(name: "token", value: appToken),
            URLQueryItem(name: "user", value: userKey),
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "message", value: message),
            URLQueryItem(name: "priority", value: String(mapPriority(priority)))
        ]
        if let url, !url.isEmpty {
            queryItems.append(URLQueryItem(name: "url", value: url))
        }
        bodyComponents.queryItems = queryItems

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyComponents.percentEncodedQuery?.data(using: .utf8)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PushoverError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw PushoverError.httpError(statusCode: httpResponse.statusCode)
        }
    }

    /// Sends a test notification to verify Pushover is configured correctly.
    /// - Throws: `PushoverError` if delivery fails.
    func sendTest() async throws {
        try await send(
            title: "RemoteDeploy",
            message: "Test notification successful!",
            priority: .normal,
            url: nil
        )
    }

    // MARK: - Private

    /// Maps a `PushPriority` value to Pushover's integer scale.
    private func mapPriority(_ priority: PushPriority) -> Int {
        switch priority {
        case .low:    return -1
        case .normal: return 0
        case .high:   return 1
        }
    }
}

/// Errors specific to the Pushover notification service.
enum PushoverError: LocalizedError {
    case missingAppToken
    case missingUserKey
    case invalidResponse
    case httpError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .missingAppToken:
            return "Pushover application token is not set."
        case .missingUserKey:
            return "Pushover user key is not set."
        case .invalidResponse:
            return "Pushover returned an invalid response."
        case .httpError(let statusCode):
            return "Pushover request failed with HTTP status \(statusCode)."
        }
    }
}
