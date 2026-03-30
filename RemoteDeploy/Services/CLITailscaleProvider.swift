// Concrete implementation of TailscaleProviderProtocol that wraps
// the `tailscale` CLI binary for hostname discovery, connectivity
// checks, and TLS certificate generation.
import Foundation

struct CLITailscaleProvider: TailscaleProviderProtocol {

    /// Paths to search for the Tailscale CLI binary, in priority order.
    private static let binarySearchPaths = [
        "/usr/local/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    ]

    /// Resolves the first available Tailscale CLI binary on disk.
    ///
    /// - Returns: The absolute path to the Tailscale binary.
    /// - Throws: If no Tailscale binary can be found at any of the known paths.
    private func tailscaleBinaryPath() throws -> String {
        for path in Self.binarySearchPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        throw TailscaleError.binaryNotFound
    }

    // MARK: - TailscaleProviderProtocol

    /// Queries Tailscale for this machine's MagicDNS hostname by running
    /// `tailscale status --self --json` and extracting the `.Self.DNSName` field.
    /// The trailing dot (root domain indicator) is stripped before returning.
    ///
    /// - Returns: The fully-qualified Tailscale hostname (e.g. "macbook-pro.tail12345.ts.net").
    /// - Throws: If the Tailscale CLI is unavailable, the command fails, or the
    ///   response JSON does not contain a DNS name.
    public func detectHostname() async throws -> String {
        let binary = try tailscaleBinaryPath()
        let data = try await runCommand([binary, "status", "--self", "--json"])

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let selfInfo = json["Self"] as? [String: Any],
              let dnsName = selfInfo["DNSName"] as? String else {
            throw TailscaleError.unexpectedOutput("Could not parse DNSName from tailscale status output")
        }

        // Tailscale appends a trailing dot to FQDN — strip it.
        let hostname = dnsName.hasSuffix(".") ? String(dnsName.dropLast()) : dnsName
        guard !hostname.isEmpty else {
            throw TailscaleError.unexpectedOutput("DNSName is empty")
        }
        return hostname
    }

    /// Checks whether Tailscale is currently connected to the tailnet by running
    /// `tailscale status --self --json` and inspecting the `.Self.Online` field.
    ///
    /// - Returns: `true` if the machine is online; `false` if offline, the CLI is
    ///   missing, or the command fails for any reason.
    public func isConnected() async -> Bool {
        do {
            let binary = try tailscaleBinaryPath()
            let data = try await runCommand([binary, "status", "--self", "--json"])
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let selfInfo = json["Self"] as? [String: Any],
                  let online = selfInfo["Online"] as? Bool else {
                return false
            }
            return online
        } catch {
            return false
        }
    }

    /// Generates a TLS certificate for the given Tailscale hostname by running
    /// `tailscale cert`. The certificate and private key PEM files are written
    /// to the specified output directory.
    ///
    /// - Parameter hostname: The Tailscale MagicDNS hostname to generate a cert for.
    /// - Parameter outputDir: The directory where the cert and key files will be written.
    /// - Returns: A tuple of absolute file paths: `certPath` and `keyPath`.
    /// - Throws: If the `tailscale cert` command fails or the binary is not found.
    public func generateCertificate(hostname: String, outputDir: String) async throws -> (certPath: String, keyPath: String) {
        let binary = try tailscaleBinaryPath()

        let certPath = (outputDir as NSString).appendingPathComponent("\(hostname).crt")
        let keyPath = (outputDir as NSString).appendingPathComponent("\(hostname).key")

        _ = try await runCommand([
            binary, "cert",
            "--cert-file", certPath,
            "--key-file", keyPath,
            hostname
        ])

        return (certPath: certPath, keyPath: keyPath)
    }

    // MARK: - Helpers

    /// Runs a command-line process and returns the captured standard output data.
    ///
    /// - Parameter args: The full argument list where `args[0]` is the executable path.
    /// - Returns: The raw standard output data produced by the process.
    /// - Throws: `TailscaleError.commandFailed` if the process exits with a non-zero code.
    private func runCommand(_ args: [String]) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: outputData)
            }
        }
    }
}

// MARK: - Errors

enum TailscaleError: LocalizedError {
    case binaryNotFound
    case commandFailed(String)
    case unexpectedOutput(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "Tailscale CLI not found. Install Tailscale or ensure /usr/local/bin/tailscale exists."
        case .commandFailed(let detail):
            return "Tailscale command failed: \(detail)"
        case .unexpectedOutput(let detail):
            return "Unexpected Tailscale output: \(detail)"
        }
    }
}
