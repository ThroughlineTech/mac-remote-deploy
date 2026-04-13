// Protocol for generating the HTML page that iOS users visit to install the app.
// The page displays app metadata and contains the itms-services:// link that
// triggers iOS's OTA installation flow.
import Foundation

protocol InstallPageGenerating: Sendable {

    /// Generates a self-contained HTML page for OTA app installation.
    ///
    /// The page shows the app name, version, build number, and build time, along with
    /// a prominent "Install" button that opens the `itms-services://` URL pointing
    /// to the manifest plist.
    ///
    /// - Parameter appName: The display name of the app (shown as the page heading).
    /// - Parameter version: The short version string, e.g. "1.2.0" (shown to the user).
    /// - Parameter build: The build number, e.g. "42" (shown to the user).
    /// - Parameter buildTime: A human-readable timestamp of when the IPA was built
    ///   (e.g. "2026-03-30 14:22 PST").
    /// - Parameter manifestURL: The full HTTPS URL to the OTA manifest.plist endpoint
    ///   (e.g. "https://macbook.tail1234.ts.net:8443/manifest.plist").
    /// - Returns: A complete HTML string ready to be served with content type `text/html`.
    func generatePage(appName: String, version: String, build: String, buildTime: String, manifestURL: String) -> String

    /// Generates a self-contained HTML page for macOS app download.
    ///
    /// The page shows the app name, version, build number, and build time, along with
    /// a prominent "Download" button that links directly to the zip file URL.
    /// Unlike the iOS install page, this does not use `itms-services://`.
    ///
    /// - Parameter appName: The display name of the app (shown as the page heading).
    /// - Parameter version: The short version string, e.g. "1.2.0".
    /// - Parameter build: The build number, e.g. "42".
    /// - Parameter buildTime: A human-readable timestamp of when the app was built.
    /// - Parameter downloadURL: The full URL to the downloadable zip file.
    /// - Returns: A complete HTML string ready to be served with content type `text/html`.
    func generateDownloadPage(appName: String, version: String, build: String, buildTime: String, downloadURL: String) -> String
}
