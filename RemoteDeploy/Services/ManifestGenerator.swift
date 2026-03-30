// Concrete implementation of ManifestGenerating.
// Produces the XML plist that iOS requires for over-the-air IPA installation
// via itms-services:// links.
import Foundation

final class ManifestGenerator: ManifestGenerating {

    /// Builds the XML plist string that iOS uses for over-the-air app installation.
    ///
    /// The output follows Apple's OTA manifest format: a plist containing an
    /// `items` array with a single asset entry (the IPA URL) and metadata
    /// (bundle ID, version, title). iOS fetches this manifest when the user
    /// taps an `itms-services://` link on the install page.
    ///
    /// - Parameter bundleID: The app's CFBundleIdentifier (e.g. "com.example.MyApp").
    /// - Parameter version: The app's CFBundleShortVersionString (e.g. "1.2.0").
    /// - Parameter appName: The display name shown during installation.
    /// - Parameter ipaURL: The full HTTPS URL where the IPA file can be downloaded.
    /// - Returns: A complete XML plist string ready to be served as `text/xml`.
    func generateManifest(bundleID: String, version: String, appName: String, ipaURL: String) -> String {
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>items</key>
            <array>
                <dict>
                    <key>assets</key>
                    <array>
                        <dict>
                            <key>kind</key>
                            <string>software-package</string>
                            <key>url</key>
                            <string>\(xmlEscape(ipaURL))</string>
                        </dict>
                    </array>
                    <key>metadata</key>
                    <dict>
                        <key>bundle-identifier</key>
                        <string>\(xmlEscape(bundleID))</string>
                        <key>bundle-version</key>
                        <string>\(xmlEscape(version))</string>
                        <key>kind</key>
                        <string>software</string>
                        <key>title</key>
                        <string>\(xmlEscape(appName))</string>
                    </dict>
                </dict>
            </array>
        </dict>
        </plist>
        """
    }

    // MARK: - Private

    /// Escapes special XML characters in a string to prevent malformed plist output.
    private func xmlEscape(_ string: String) -> String {
        var result = string
        result = result.replacingOccurrences(of: "&", with: "&amp;")
        result = result.replacingOccurrences(of: "<", with: "&lt;")
        result = result.replacingOccurrences(of: ">", with: "&gt;")
        result = result.replacingOccurrences(of: "\"", with: "&quot;")
        result = result.replacingOccurrences(of: "'", with: "&apos;")
        return result
    }
}
