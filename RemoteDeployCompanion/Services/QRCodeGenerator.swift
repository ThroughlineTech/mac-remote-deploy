// Generates QR code images for delegated device pairing on iOS (TKT-065).
//
// Mirrors the macOS host's generator (RemoteDeploy/Services/QRCodeGenerator.swift)
// but produces a UIImage. Used by "Pair Another Device" so an already-paired
// phone can mint a fresh one-time token and display it as a scannable QR code
// for a second device to pair with -- no Mac-side access required.
//
// PairingPayload is intentionally a companion-local definition rather than a
// shared-package type. Promoting it into RemoteDeployShared would pull Packages/
// into the diff and trigger a full notarized host release build on ship (see the
// allowlist in scripts/ship-deploy.sh), which this companion-only feature does
// not otherwise need. The companion's scanner (QRScannerView) decodes this same
// type so the two companion sites stay in lockstep; revisit promotion only if a
// third companion copy appears.
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Generates QR codes for delegated pairing from an already-paired companion.
final class QRCodeGenerator {

    /// The JSON payload embedded in the pairing QR code. Must match the shape the
    /// scanner decodes (`QRScannerView`) and the macOS host emits
    /// (`RemoteDeploy/Services/QRCodeGenerator.swift`).
    struct PairingPayload: Codable {
        /// The base URL of the API server (e.g., "https://macbook.tail1234.ts.net:8443").
        var url: String
        /// The raw one-time bearer token the new device submits to POST /api/v1/pair.
        var token: String
        /// The display name of the paired Mac (e.g., "MacBook Pro").
        var serverName: String
        /// The local network URL, when applicable. Omitted for delegated pairing
        /// because the receiving device's claim must go over HTTPS (TKT-065).
        var localURL: String?
    }

    /// Generates a QR code image containing the pairing payload.
    ///
    /// - Parameter payload: The pairing information to encode.
    /// - Parameter size: The desired image size in points. Defaults to 512.
    /// - Returns: A `UIImage` containing the QR code, or `nil` if generation fails.
    func generateQRCode(for payload: PairingPayload, size: CGFloat = 512) -> UIImage? {
        guard let jsonData = try? JSONEncoder().encode(payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return nil
        }
        return generateQRCode(from: jsonString, size: size)
    }

    /// Generates a QR code image from an arbitrary string.
    ///
    /// - Parameter string: The string to encode in the QR code.
    /// - Parameter size: The desired image size in points. Defaults to 512.
    /// - Returns: A `UIImage` containing the QR code, or `nil` if generation fails.
    func generateQRCode(from string: String, size: CGFloat = 512) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let ciImage = filter.outputImage else { return nil }

        // Scale the (tiny) generated image up to the requested size with no
        // interpolation so the modules stay crisp.
        let scaleX = size / ciImage.extent.size.width
        let scaleY = size / ciImage.extent.size.height
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
