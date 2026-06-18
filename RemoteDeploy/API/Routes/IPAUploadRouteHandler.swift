// Handles prebuilt .ipa uploads. TKT-060 (Phase 6): POST /api/v1/projects/:id/ipa
// accepts the raw IPA bytes as the request body (?filename=<name>), writes them
// to a temp file, and hands off to IPAImporter to validate + copy into the
// project's serve directory. This replaces the menu bar's in-process IPA import
// so the menu bar can upload over the API after the process split.
import Foundation
import os
import RemoteDeployShared

/// Routes IPA upload requests for a project.
final class IPAUploadRouteHandler: @unchecked Sendable {

    private let projectStore: any ProjectStoring
    private let ipaImporter: IPAImporter
    private let serveDirectory: String

    init(projectStore: any ProjectStoring, ipaImporter: IPAImporter, serveDirectory: String) {
        self.projectStore = projectStore
        self.ipaImporter = ipaImporter
        self.serveDirectory = serveDirectory
    }

    /// POST /api/v1/projects/:id/ipa — upload a prebuilt .ipa for the project.
    func upload(_ request: APIRequest, projectID: UUID) -> APIResponse {
        guard let project = (try? projectStore.loadProjects())?.first(where: { $0.id == projectID }) else {
            return .error(status: .notFound, message: "Project not found")
        }
        guard !request.body.isEmpty else {
            return .error(status: .badRequest, message: "Empty upload body")
        }

        // Use only the last path component of the supplied filename to avoid
        // path traversal; IPAImporter copies under <serveDir>/<slug>/.
        let rawName = request.queryParameters["filename"] ?? "upload.ipa"
        let safeName = (rawName as NSString).lastPathComponent
        let fileName = safeName.isEmpty ? "upload.ipa" : safeName

        // Stage the upload in a unique subdirectory under the clean filename so
        // IPAImporter (which serves under the file's lastPathComponent) keeps the
        // user-facing name rather than a UUID-prefixed one.
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rd-upload-\(UUID().uuidString)")
        let tempURL = stagingDir.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            try request.body.write(to: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: stagingDir)
            return .error(status: .internalServerError, message: "Failed to stage upload: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        do {
            let info = try ipaImporter.importIPA(from: tempURL, to: project.urlSlug, serveDirectory: serveDirectory)
            Logger.build.info("Uploaded IPA: \(info.bundleID, privacy: .public) v\(info.version, privacy: .public) for /\(project.urlSlug, privacy: .public)/")
            let response = IPAUploadResponse(
                bundleID: info.bundleID,
                version: info.version,
                buildNumber: info.buildNumber,
                slug: project.urlSlug
            )
            return .json(response, status: .created)
        } catch {
            return .error(status: .badRequest, message: error.localizedDescription)
        }
    }
}
