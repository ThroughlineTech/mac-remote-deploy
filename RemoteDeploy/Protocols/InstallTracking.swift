// Protocol for recording and querying IPA download events.
// Each time a device downloads an IPA from the server, an install record
// is created so the user can see who installed what and when.
import Foundation

protocol InstallTracking: Sendable {

    /// Records that a device downloaded an IPA from the deploy server.
    ///
    /// - Parameter projectName: The display name of the project that was installed
    ///   (e.g. "My App").
    /// - Parameter sourceIP: The IP address of the device that made the request
    ///   (e.g. "100.64.1.12").
    /// - Parameter userAgent: The raw User-Agent header from the HTTP request,
    ///   useful for identifying device type and OS version.
    func recordInstall(projectName: String, sourceIP: String, userAgent: String) async

    /// Returns the most recent install records, ordered newest-first.
    ///
    /// - Parameter limit: The maximum number of records to return. Pass `Int.max`
    ///   or a large number to get all records.
    /// - Returns: An array of `InstallRecord` values, with the most recent first.
    func recentInstalls(limit: Int) async -> [InstallRecord]

    /// Deletes a single install record by its unique identifier.
    ///
    /// - Parameter id: The UUID of the record to delete.
    /// - Returns: `true` if the record was found and deleted, `false` if no
    ///   record with that ID exists.
    func deleteInstall(id: UUID) async -> Bool

    /// Deletes all install records.
    func deleteAllInstalls() async
}
