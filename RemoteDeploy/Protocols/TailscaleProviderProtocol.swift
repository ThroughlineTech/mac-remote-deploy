// Protocol for interacting with the Tailscale CLI (`tailscale`).
// Used to discover the machine's Tailscale hostname and to generate
// HTTPS certificates via `tailscale cert`.
import Foundation

protocol TailscaleProviderProtocol: Sendable {

    /// Queries Tailscale for this machine's MagicDNS hostname
    /// (e.g. "macbook-pro.tail12345.ts.net").
    ///
    /// - Returns: The fully-qualified Tailscale hostname string.
    /// - Throws: If the Tailscale CLI is not installed, Tailscale is not logged in,
    ///   or the hostname cannot be determined.
    func detectHostname() async throws -> String

    /// Checks whether Tailscale is currently connected to the tailnet.
    ///
    /// - Returns: `true` if `tailscale status` reports a connected state, `false` otherwise
    ///   (e.g. logged out, stopped, or CLI not found).
    func isConnected() async -> Bool

    /// Generates a TLS certificate for the given Tailscale hostname using `tailscale cert`.
    /// Tailscale provisions a Let's Encrypt certificate that is trusted by iOS.
    ///
    /// - Parameter hostname: The Tailscale MagicDNS hostname to generate a cert for
    ///   (e.g. "macbook-pro.tail12345.ts.net").
    /// - Parameter outputDir: The directory where the cert and key PEM files should be written.
    /// - Returns: A tuple of absolute file paths: `certPath` for the certificate PEM and
    ///   `keyPath` for the private key PEM.
    /// - Throws: If `tailscale cert` fails (not logged in, hostname mismatch, disk error, etc.).
    func generateCertificate(hostname: String, outputDir: String) async throws -> (certPath: String, keyPath: String)
}
