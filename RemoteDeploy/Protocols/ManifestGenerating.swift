// Protocol for generating the iOS OTA installation manifest.plist.
// iOS requires a specially-formatted XML plist served over HTTPS
// in order to install an IPA via itms-services:// links.
import Foundation

protocol ManifestGenerating: Sendable {

    /// Builds the XML plist string that iOS uses for over-the-air app installation.
    ///
    /// The generated manifest follows Apple's OTA manifest format and includes
    /// the download URL, bundle identifier, version, and display name. iOS fetches
    /// this manifest when the user taps an `itms-services://` link.
    ///
    /// - Parameter bundleID: The app's CFBundleIdentifier (e.g. "com.example.MyApp").
    /// - Parameter version: The app's CFBundleShortVersionString (e.g. "1.2.0").
    /// - Parameter appName: The display name shown during installation (e.g. "My App").
    /// - Parameter ipaURL: The full HTTPS URL where the IPA file can be downloaded
    ///   (e.g. "https://macbook.tail1234.ts.net:8443/ipa/MyApp.ipa").
    /// - Returns: A complete XML plist string ready to be served with content type
    ///   `text/xml` at the manifest endpoint.
    func generateManifest(bundleID: String, version: String, appName: String, ipaURL: String) -> String
}
