// Generates QR code images for device pairing.
// Uses CoreImage's built-in CIQRCodeGenerator filter to create QR codes
// containing the server URL and authentication token as a JSON payload.
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Generates QR codes for pairing companion devices with this Mac.
final class QRCodeGenerator: Sendable {

    /// The JSON payload embedded in the QR code for device pairing.
    struct PairingPayload: Codable, Sendable {
        /// The base URL of the API server (e.g., "https://macbook.tail1234.ts.net:8443").
        var url: String
        /// The raw bearer token for API authentication.
        var token: String
        /// The display name of this Mac (e.g., "MacBook Pro").
        var serverName: String
        /// The local network URL (e.g., "http://192.168.1.42:8080") for when Tailscale is unavailable.
        var localURL: String?
    }

    /// Returns the Mac's local WiFi IP address, if available.
    static func localIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let addr = ptr.pointee
            guard addr.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: addr.ifa_name)
            guard name == "en0" || name == "en1" else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr.ifa_addr, socklen_t(addr.ifa_addr.pointee.sa_len),
                        &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: hostname)
            if !ip.isEmpty { return ip }
        }
        return nil
    }

    /// Generates a QR code image containing the pairing payload.
    ///
    /// - Parameter payload: The pairing information to encode.
    /// - Parameter size: The desired image size in points. Defaults to 256.
    /// - Returns: An `NSImage` containing the QR code, or `nil` if generation fails.
    func generateQRCode(for payload: PairingPayload, size: CGFloat = 256) -> NSImage? {
        guard let jsonData = try? JSONEncoder().encode(payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return nil
        }
        return generateQRCode(from: jsonString, size: size)
    }

    /// Generates a QR code image from an arbitrary string.
    ///
    /// - Parameter string: The string to encode in the QR code.
    /// - Parameter size: The desired image size in points. Defaults to 256.
    /// - Returns: An `NSImage` containing the QR code, or `nil` if generation fails.
    func generateQRCode(from string: String, size: CGFloat = 256) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let ciImage = filter.outputImage else { return nil }

        // Scale the QR code to the desired size.
        let scaleX = size / ciImage.extent.size.width
        let scaleY = size / ciImage.extent.size.height
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
