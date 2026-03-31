import Foundation

/// Sends push notifications via the Prowl service.
/// Conforms to `PushNotifying` so it can be used interchangeably
/// with other notification providers.
final class ProwlNotifier: PushNotifying {

    /// The Prowl API key used to authenticate requests.
    let apiKey: String

    /// Creates a notifier with the given API key.
    /// - Parameter apiKey: A valid Prowl API key. Defaults to empty.
    init(apiKey: String = "") {
        self.apiKey = apiKey
    }

    /// Sends a push notification through Prowl.
    /// - Parameters:
    ///   - title: The notification title shown on the device.
    ///   - message: The notification body text.
    ///   - priority: The delivery urgency, mapped to Prowl's -2..2 scale.
    ///   - url: An optional URL the user can tap to open.
    /// - Throws: `ProwlError` if the API key is empty, the server returns
    ///   a non-200 status, or the request fails.
    func send(title: String, message: String, priority: PushPriority, url: String?) async throws {
        guard !apiKey.isEmpty else {
            throw ProwlError.missingAPIKey
        }

        let endpoint = URL(string: "https://api.prowlapp.com/publicapi/add")!

        var bodyComponents = URLComponents()
        var queryItems = [
            URLQueryItem(name: "apikey", value: apiKey),
            URLQueryItem(name: "application", value: "RemoteDeploy"),
            URLQueryItem(name: "event", value: title),
            URLQueryItem(name: "description", value: message),
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
            throw ProwlError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw ProwlError.httpError(statusCode: httpResponse.statusCode)
        }
    }

    /// Sends a test notification to verify Prowl is configured correctly.
    /// - Throws: `ProwlError` if delivery fails.
    func sendTest() async throws {
        try await send(
            title: "RemoteDeploy",
            message: "Test notification successful!",
            priority: .normal,
            url: nil
        )
    }

    // MARK: - Private

    /// Maps a `PushPriority` value to Prowl's integer scale.
    private func mapPriority(_ priority: PushPriority) -> Int {
        switch priority {
        case .low:    return -1
        case .normal: return 0
        case .high:   return 1
        }
    }
}

/// Errors specific to the Prowl notification service.
enum ProwlError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case httpError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Prowl API key is not set."
        case .invalidResponse:
            return "Prowl returned an invalid response."
        case .httpError(let statusCode):
            return "Prowl request failed with HTTP status \(statusCode)."
        }
    }
}
