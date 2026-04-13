// Protocol for local macOS app deployment after a successful build.
// Enables testing with mock implementations. TKT-053.
import Foundation

protocol LocalDeployManagerProtocol: AnyObject, Sendable {
    /// Deploys a macOS .app bundle from an xcarchive to a target directory.
    ///
    /// - Parameters:
    ///   - appName: Display name of the app (e.g. "MyApp").
    ///   - archivePath: Absolute path to the `.xcarchive` bundle containing the built app.
    ///   - targetDir: Target directory to copy the .app to (e.g. "/Applications").
    ///   - port: Optional port number to wait for release before copying.
    func deploy(
        appName: String,
        fromArchive archivePath: String,
        toDirectory targetDir: String,
        port: Int?
    ) async throws
}
