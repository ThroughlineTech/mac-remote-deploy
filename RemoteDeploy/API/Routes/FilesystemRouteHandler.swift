// Handles filesystem browsing API endpoints so companion devices
// can discover Xcode projects and workspaces on the Mac.
// Restricts browsing to /Users/ to prevent arbitrary filesystem access.
import Foundation
import RemoteDeployShared

/// Provides filesystem browsing for Xcode project discovery.
final class FilesystemRouteHandler: @unchecked Sendable {

    private let schemeDetector: any SchemeDetecting

    /// Creates a new filesystem route handler.
    ///
    /// - Parameter schemeDetector: Detects Xcode schemes at a given project path.
    init(schemeDetector: any SchemeDetecting) {
        self.schemeDetector = schemeDetector
    }

    /// GET /api/v1/filesystem/browse?path=/Users/... — Browse directories.
    func browse(_ request: APIRequest) -> APIResponse {
        let requestedPath = request.queryParameters["path"] ?? NSHomeDirectory()

        // Security: only allow browsing under /Users/
        guard requestedPath.hasPrefix("/Users/") else {
            return .error(status: .forbidden, message: "Browsing is restricted to /Users/")
        }

        // Resolve symlinks to prevent traversal attacks
        let resolvedPath = (requestedPath as NSString).resolvingSymlinksInPath
        guard resolvedPath.hasPrefix("/Users/") else {
            return .error(status: .forbidden, message: "Path resolves outside allowed directory")
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: resolvedPath, isDirectory: &isDir), isDir.boolValue else {
            return .error(status: .notFound, message: "Directory not found")
        }

        guard let contents = try? fm.contentsOfDirectory(atPath: resolvedPath) else {
            return .error(status: .internalServerError, message: "Failed to list directory")
        }

        var directories: [String] = []
        var xcodeProjects: [String] = []
        var xcodeWorkspaces: [String] = []

        for item in contents.sorted() {
            // Skip hidden files
            guard !item.hasPrefix(".") else { continue }

            let fullPath = (resolvedPath as NSString).appendingPathComponent(item)
            var itemIsDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &itemIsDir) else { continue }

            if item.hasSuffix(".xcodeproj") {
                xcodeProjects.append(item)
            } else if item.hasSuffix(".xcworkspace") {
                xcodeWorkspaces.append(item)
            } else if itemIsDir.boolValue {
                directories.append(item)
            }
        }

        // Compute parent path
        let parentPath: String? = resolvedPath == "/Users" ? nil : (resolvedPath as NSString).deletingLastPathComponent

        let response = FilesystemBrowseResponse(
            currentPath: resolvedPath,
            parentPath: parentPath,
            directories: directories,
            xcodeProjects: xcodeProjects,
            xcodeWorkspaces: xcodeWorkspaces
        )
        return .json(response)
    }

    /// GET /api/v1/filesystem/schemes?path=/Users/.../MyApp.xcodeproj — Detect schemes.
    func detectSchemes(_ request: APIRequest) -> APIResponse {
        guard let path = request.queryParameters["path"] else {
            return .error(status: .badRequest, message: "Missing 'path' query parameter")
        }

        // Resolve symlinks to prevent traversal, same as browse endpoint
        let resolvedPath = (path as NSString).resolvingSymlinksInPath
        guard resolvedPath.hasPrefix("/Users/") else {
            return .error(status: .forbidden, message: "Path must resolve to under /Users/")
        }

        let schemes = schemeDetector.detectSchemes(atPath: resolvedPath)
        return .json(SchemesResponse(schemes: schemes))
    }
}
