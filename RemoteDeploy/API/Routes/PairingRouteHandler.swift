// Handles device pairing and unpairing API endpoints.
// POST /api/v1/pair completes QR code pairing by validating the token
// and registering the device. DELETE /api/v1/pair revokes the calling device.
import Foundation
import os
import RemoteDeployShared

/// Handles pairing and unpairing of companion devices.
final class PairingRouteHandler: @unchecked Sendable {

    private let deviceStore: PairedDeviceStoring
    private let serverName: String

    /// Pending tokens that have been generated but not yet claimed by a device.
    /// Maps token hash -> raw token (only stored in memory until claimed).
    private let pendingTokens: OSAllocatedUnfairLock<[String: Date]>

    /// TKT-018: rate limiting for POST /api/v1/pair. Applied globally (not per-IP)
    /// since the current request plumbing doesn't expose the source IP to the handler.
    /// Global rate limiting is a simpler, stronger defense anyway — any single
    /// attacker can only try `maxAttemptsInWindow` tokens per lockout window, so
    /// the 32-bit token space is effectively untouchable via brute force.
    private struct RateLimitState {
        /// Timestamp of the most recent attempt (successful or not).
        var lastAttemptAt: Date?
        /// Number of failed attempts within the current window.
        var failedAttemptsInWindow: Int = 0
        /// Timestamp of the first failure in the current window (for window reset).
        var windowStart: Date?
        /// Timestamp until which the endpoint is locked out. If set and in the future,
        /// all attempts are rejected with 429.
        var lockedOutUntil: Date?
    }
    private let lockedRateLimit = OSAllocatedUnfairLock<RateLimitState>(initialState: RateLimitState())

    /// Minimum time between consecutive pair attempts. Default: 1 request per second.
    /// Tests can set this to 0 via init to disable per-request throttling.
    private let minInterval: TimeInterval

    /// Rolling window size for counting failed attempts. 10 minutes.
    private static let windowDuration: TimeInterval = 600

    /// Maximum failed attempts allowed within a window before lockout kicks in.
    private static let maxAttemptsInWindow = 10

    /// Lockout duration once the window limit is hit. 1 hour.
    private static let lockoutDuration: TimeInterval = 3600

    /// Creates a new pairing route handler.
    ///
    /// - Parameter deviceStore: The store for persisting paired devices.
    /// - Parameter serverName: The display name of this Mac shown to companion devices.
    /// - Parameter minInterval: Minimum seconds between consecutive pair attempts.
    ///   Defaults to 1.0 in production. Tests pass 0 to disable throttling.
    init(deviceStore: PairedDeviceStoring, serverName: String, minInterval: TimeInterval = 1.0) {
        self.deviceStore = deviceStore
        self.serverName = serverName
        self.minInterval = minInterval
        self.pendingTokens = OSAllocatedUnfairLock(initialState: [:])
    }

    /// Registers a token as available for pairing. Called when the Mac displays a QR code.
    ///
    /// - Parameter tokenHash: The SHA-256 hash of the token being offered for pairing.
    func registerPendingToken(_ tokenHash: String) {
        pendingTokens.withLock { $0[tokenHash] = Date() }
    }

    /// Removes expired pending tokens (older than 10 minutes).
    func cleanupExpiredTokens() {
        let cutoff = Date().addingTimeInterval(-600)
        pendingTokens.withLock { tokens in
            tokens = tokens.filter { $0.value > cutoff }
        }
    }

    // MARK: - Rate Limit Helpers

    /// Rate-limit check. Returns nil if the request may proceed, or a failure reason string.
    /// Updates the lastAttemptAt timestamp on success. The failure counter is bumped
    /// separately by `recordFailedAttempt()` when a pair attempt rejects a token.
    private func checkRateLimit(now: Date = Date()) -> String? {
        return lockedRateLimit.withLock { state -> String? in
            // Lockout active?
            if let until = state.lockedOutUntil, until > now {
                let secs = Int(until.timeIntervalSince(now))
                return "Too many failed pairing attempts. Try again in \(secs) seconds."
            }
            // Lockout expired — clear it.
            if let until = state.lockedOutUntil, until <= now {
                state.lockedOutUntil = nil
                state.failedAttemptsInWindow = 0
                state.windowStart = nil
            }
            // Per-request minimum interval.
            if minInterval > 0, let last = state.lastAttemptAt, now.timeIntervalSince(last) < minInterval {
                return "Rate limit: slow down (1 request per second)."
            }
            state.lastAttemptAt = now
            return nil
        }
    }

    /// Called after a pair attempt is rejected. Increments the failure counter and
    /// triggers lockout if the window limit is hit.
    private func recordFailedAttempt(now: Date = Date()) {
        lockedRateLimit.withLock { state in
            // Reset the window if it expired.
            if let start = state.windowStart, now.timeIntervalSince(start) > Self.windowDuration {
                state.failedAttemptsInWindow = 0
                state.windowStart = nil
            }
            if state.windowStart == nil {
                state.windowStart = now
            }
            state.failedAttemptsInWindow += 1
            if state.failedAttemptsInWindow >= Self.maxAttemptsInWindow {
                let until = now.addingTimeInterval(Self.lockoutDuration)
                state.lockedOutUntil = until
                let attempts = state.failedAttemptsInWindow
                Logger.pairing.warning("Pairing locked out until \(until, privacy: .public) after \(attempts, privacy: .public) failed attempts")
            }
        }
    }

    /// Called after a successful pair. Clears the failure window so a legitimate
    /// user doesn't accumulate state from earlier failures.
    private func resetRateLimitOnSuccess() {
        lockedRateLimit.withLock { state in
            state.failedAttemptsInWindow = 0
            state.windowStart = nil
            state.lockedOutUntil = nil
        }
    }

    // MARK: - POST /api/v1/pair

    /// POST /api/v1/pair — Complete pairing with a token from the QR code.
    func pair(_ request: APIRequest) -> APIResponse {
        if let reason = checkRateLimit() {
            Logger.pairing.warning("Rate-limited pair attempt: \(reason, privacy: .public)")
            return .error(status: .tooManyRequests, message: reason)
        }

        guard let pairRequest = try? request.decodeBody(PairRequest.self) else {
            recordFailedAttempt()
            return .error(status: .badRequest, message: "Invalid request body")
        }

        let tokenHash = JSONPairedDeviceStore.hashToken(pairRequest.token)

        // Verify the token is a pending pairing token
        let isPending = pendingTokens.withLock { tokens -> Bool in
            guard tokens[tokenHash] != nil else { return false }
            tokens.removeValue(forKey: tokenHash)
            return true
        }

        guard isPending else {
            recordFailedAttempt()
            return .error(status: .forbidden, message: "Invalid or expired pairing token")
        }

        // Create and save the paired device
        let device = PairedDevice(
            name: pairRequest.deviceName,
            tokenHash: tokenHash,
            pushEndpoint: pairRequest.pushEndpoint
        )

        do {
            try deviceStore.save(device: device)
        } catch {
            Logger.pairing.error("Failed to save paired device: \(error.localizedDescription, privacy: .public)")
            return .error(status: .internalServerError, message: "Failed to save paired device")
        }

        resetRateLimitOnSuccess()
        let response = PairResponse(serverName: serverName, paired: true)
        return .json(response, status: .created)
    }

    /// DELETE /api/v1/pair — Unpair the calling device.
    func unpair(_ request: APIRequest) -> APIResponse {
        guard let device = request.device else {
            return .error(status: .unauthorized, message: "Not authenticated")
        }

        do {
            try deviceStore.delete(deviceID: device.id)
        } catch {
            return .error(status: .internalServerError, message: "Failed to unpair")
        }

        return .json(["unpaired": true])
    }
}
