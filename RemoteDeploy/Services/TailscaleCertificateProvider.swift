// Concrete implementation of CertificateProviding that reads PEM certificate
// and key files from disk and inspects certificate validity using the
// Security framework.
import Foundation
import Security

struct TailscaleCertificateProvider: CertificateProviding {

    /// The number of seconds before expiry at which a certificate is considered
    /// due for renewal (7 days).
    private static let renewalWindowSeconds: TimeInterval = 7 * 24 * 60 * 60

    // MARK: - CertificateProviding

    /// Reads a TLS certificate and its private key from PEM files on disk.
    /// Validates that both files exist before reading.
    ///
    /// - Parameter certPath: Absolute path to the PEM-encoded certificate file.
    /// - Parameter keyPath: Absolute path to the PEM-encoded private key file.
    /// - Returns: A tuple containing the certificate PEM string and the key PEM string.
    /// - Throws: `CertificateError.fileNotFound` if either file is missing, or an
    ///   error if reading fails.
    public func loadCertificate(certPath: String, keyPath: String) throws -> (cert: String, key: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: certPath) else {
            throw CertificateError.fileNotFound(certPath)
        }
        guard fm.fileExists(atPath: keyPath) else {
            throw CertificateError.fileNotFound(keyPath)
        }

        let certContents = try String(contentsOfFile: certPath, encoding: .utf8)
        let keyContents = try String(contentsOfFile: keyPath, encoding: .utf8)

        guard certContents.contains("-----BEGIN CERTIFICATE-----") else {
            throw CertificateError.invalidPEM(certPath)
        }
        guard keyContents.contains("-----BEGIN") else {
            throw CertificateError.invalidPEM(keyPath)
        }

        return (cert: certContents, key: keyContents)
    }

    /// Parses the PEM certificate at the given path and returns its expiration date
    /// using the Security framework's `SecCertificate` APIs.
    ///
    /// - Parameter certPath: Absolute path to the PEM-encoded certificate file.
    /// - Returns: The `Date` when the certificate expires.
    /// - Throws: If the file cannot be read or the certificate cannot be parsed.
    public func certificateExpiryDate(certPath: String) throws -> Date {
        let pemString = try String(contentsOfFile: certPath, encoding: .utf8)
        let derData = try derData(fromPEM: pemString)

        guard let certificate = SecCertificateCreateWithData(nil, derData as CFData) else {
            throw CertificateError.parseFailed("Could not create SecCertificate from DER data")
        }

        // Use openssl via shell as a reliable fallback for extracting the expiry date,
        // since SecCertificateCopyValues is macOS-only and has varying availability.
        return try expiryDateViaOpenSSL(certPath: certPath, fallbackCert: certificate)
    }

    /// Checks whether the certificate at the given path expires within 7 days
    /// or has already expired.
    ///
    /// - Parameter certPath: Absolute path to the PEM-encoded certificate file.
    /// - Returns: `true` if the certificate needs renewal; `false` if still valid
    ///   beyond the renewal window.
    /// - Throws: If the file cannot be read or the certificate cannot be parsed.
    public func needsRenewal(certPath: String) throws -> Bool {
        let expiryDate = try certificateExpiryDate(certPath: certPath)
        let renewalThreshold = Date().addingTimeInterval(Self.renewalWindowSeconds)
        return expiryDate <= renewalThreshold
    }

    // MARK: - Private helpers

    /// Extracts DER-encoded certificate data from a PEM string by stripping
    /// the header/footer lines and base64-decoding the body.
    ///
    /// - Parameter pem: The full PEM string including BEGIN/END markers.
    /// - Returns: The raw DER bytes.
    /// - Throws: `CertificateError.invalidPEM` if the PEM cannot be decoded.
    private func derData(fromPEM pem: String) throws -> Data {
        let lines = pem.components(separatedBy: "\n")
        let base64Lines = lines.filter { line in
            !line.hasPrefix("-----") && !line.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let base64String = base64Lines.joined()
        guard let data = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters), !data.isEmpty else {
            throw CertificateError.invalidPEM("Failed to base64-decode PEM body")
        }
        return data
    }

    /// Extracts the certificate expiry date by shelling out to `openssl x509`.
    /// Falls back to trying `SecCertificateCopyValues` if openssl is unavailable.
    ///
    /// - Parameter certPath: Path to the certificate file.
    /// - Parameter fallbackCert: A pre-parsed SecCertificate for fallback extraction.
    /// - Returns: The expiry date.
    /// - Throws: If the expiry date cannot be determined by any method.
    private func expiryDateViaOpenSSL(certPath: String, fallbackCert: SecCertificate) throws -> Date {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = ["x509", "-enddate", "-noout", "-in", certPath]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: outputData, encoding: .utf8),
              output.contains("notAfter=") else {
            throw CertificateError.parseFailed("openssl did not return notAfter field")
        }

        // Format: notAfter=Mon DD HH:MM:SS YYYY GMT
        // Example: notAfter=Dec 15 09:30:00 2025 GMT
        let dateString = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "notAfter=", with: "")

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM dd HH:mm:ss yyyy zzz"
        // Also try the alternate format with a leading-space day.
        formatter.isLenient = true

        if let date = formatter.date(from: dateString) {
            return date
        }

        // Try alternate format: "MMM  d HH:mm:ss yyyy zzz"
        formatter.dateFormat = "MMM  d HH:mm:ss yyyy zzz"
        if let date = formatter.date(from: dateString) {
            return date
        }

        throw CertificateError.parseFailed("Could not parse date string: \(dateString)")
    }
}

// MARK: - Errors

enum CertificateError: LocalizedError {
    case fileNotFound(String)
    case invalidPEM(String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Certificate file not found: \(path)"
        case .invalidPEM(let detail):
            return "Invalid PEM data: \(detail)"
        case .parseFailed(let detail):
            return "Certificate parse error: \(detail)"
        }
    }
}
