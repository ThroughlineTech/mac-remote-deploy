// Response generators for the OTA deployment routes — install page, manifest,
// IPA download, index page, and PWA static files. Implemented as an extension
// on HTTPHandler so they have full access to the channel context and the
// owning server's project store, while keeping the routing dispatcher in
// HTTPHandler.swift focused on URL → method dispatch.
import Foundation
import NIO
import NIOHTTP1

extension HTTPHandler {

    /// Builds a simple HTML index page listing all registered projects with links to their
    /// install pages.
    ///
    /// - Parameter projects: Dictionary of slug -> ProjectConfig for all registered projects.
    /// - Returns: A complete HTML string for the index page.
    func buildIndexPage(projects: [String: ProjectConfig]) -> String {
        var rows = ""
        for (slug, project) in projects.sorted(by: { $0.key < $1.key }) {
            let safeName = htmlEscape(project.name)
            let safeBundleID = htmlEscape(project.bundleID)
            let safeSlug = htmlEscape(slug)
            rows += "<li><a href=\"/\(safeSlug)/\">\(safeName)</a> -- \(safeBundleID)</li>\n"
        }

        if rows.isEmpty {
            rows = "<li>No projects configured.</li>"
        }

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>RemoteDeploy</title>
            <style>
                body { font-family: -apple-system, sans-serif; max-width: 600px; margin: 40px auto; padding: 0 20px; }
                h1 { color: #333; }
                ul { list-style: none; padding: 0; }
                li { padding: 12px 0; border-bottom: 1px solid #eee; }
                a { color: #007AFF; text-decoration: none; font-weight: 500; }
                a:hover { text-decoration: underline; }
            </style>
        </head>
        <body>
            <h1>RemoteDeploy</h1>
            <p>Available projects:</p>
            <ul>
                \(rows)
            </ul>
        </body>
        </html>
        """
    }

    /// Serves the HTML install page for a project at GET /<slug>/.
    /// Reads the IPA's modification date from disk to use as the build timestamp.
    func serveInstallPage(context: ChannelHandlerContext, project: ProjectConfig, slug: String) {
        let baseURL = server.currentBaseURL()
        let manifestURL = "\(baseURL)/\(slug)/manifest.plist"
        let ipaPath = "\(server.serveRoot)/\(slug)/app.ipa"

        // Read version/build from the IPA's Info.plist if available, otherwise use defaults
        let version = "1.0.0"
        let build = "1"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm z"
        let buildTime: String
        if let attrs = try? FileManager.default.attributesOfItem(atPath: ipaPath),
           let modDate = attrs[.modificationDate] as? Date {
            buildTime = formatter.string(from: modDate)
        } else {
            buildTime = formatter.string(from: Date())
        }

        let html = server.installPageGenerator.generatePage(
            appName: project.name,
            version: version,
            build: build,
            buildTime: buildTime,
            manifestURL: manifestURL
        )
        sendResponse(context: context, status: .ok, contentType: "text/html", body: html)
    }

    /// Serves the OTA manifest.plist XML for a project at GET /<slug>/manifest.plist.
    func serveManifest(context: ChannelHandlerContext, project: ProjectConfig, slug: String) {
        let baseURL = server.currentBaseURL()
        let ipaURL = "\(baseURL)/\(slug)/app.ipa"
        let xml = server.manifestGenerator.generateManifest(
            bundleID: project.bundleID,
            version: "1.0.0",
            appName: project.name,
            ipaURL: ipaURL
        )
        sendResponse(context: context, status: .ok, contentType: "application/xml", body: xml)
    }

    /// Serves the IPA file download at GET /<slug>/app.ipa.
    /// Records the download via both the onIPADownload callback and the delegate.
    func serveIPA(context: ChannelHandlerContext, project: ProjectConfig, slug: String, head: HTTPRequestHead) {
        let ipaPath = "\(server.serveRoot)/\(slug)/app.ipa"
        guard FileManager.default.fileExists(atPath: ipaPath) else {
            sendNotFound(context: context)
            return
        }

        // Notify delegate/callback about the download
        let sourceIP = head.headers["X-Forwarded-For"].first
            ?? context.remoteAddress?.description
            ?? "unknown"
        let userAgent = head.headers["User-Agent"].first ?? "unknown"

        server.onIPADownload?(slug, sourceIP, userAgent)

        // Notify delegate asynchronously
        if let delegate = server.delegate {
            let projectName = project.name
            Task {
                await delegate.serverDidServeIPA(
                    projectName: projectName,
                    sourceIP: sourceIP,
                    userAgent: userAgent
                )
            }
        }

        sendFileResponse(context: context, filePath: ipaPath)
    }

    /// Serves PWA static files from the app bundle's Resources/pwa directory.
    ///
    /// Maps /app/ to index.html, /app/style.css to style.css, etc.
    /// Files are loaded from the main bundle's resource path.
    ///
    /// - Parameter context: The channel handler context to write the response to.
    /// - Parameter path: The URL path (e.g., "/app/", "/app/style.css").
    func servePWAFile(context: ChannelHandlerContext, path: String) {
        // Map the URL path to a filename
        var filename = String(path.dropFirst("/app/".count))
        if filename.isEmpty || filename == "/" {
            filename = "index.html"
        }

        // Look for the file in the app bundle's pwa resources
        guard let resourcePath = Bundle.main.resourcePath else {
            sendNotFound(context: context)
            return
        }

        // Security: canonicalize the path and verify it stays inside the pwa directory
        let pwaDir = "\(resourcePath)/pwa"
        let filePath = (pwaDir as NSString).appendingPathComponent(filename)
        let canonicalPath = (filePath as NSString).standardizingPath
        guard canonicalPath.hasPrefix(pwaDir) else {
            sendNotFound(context: context)
            return
        }
        guard let fileData = FileManager.default.contents(atPath: filePath) else {
            sendNotFound(context: context)
            return
        }

        // Determine content type from extension
        let contentType: String
        if filename.hasSuffix(".html") { contentType = "text/html; charset=utf-8" }
        else if filename.hasSuffix(".css") { contentType = "text/css; charset=utf-8" }
        else if filename.hasSuffix(".js") { contentType = "application/javascript; charset=utf-8" }
        else if filename.hasSuffix(".json") { contentType = "application/json" }
        else if filename.hasSuffix(".svg") { contentType = "image/svg+xml" }
        else { contentType = "application/octet-stream" }

        var buffer = context.channel.allocator.buffer(capacity: fileData.count)
        buffer.writeBytes(fileData)

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: "\(fileData.count)")
        headers.add(name: "Connection", value: "close")
        headers.add(name: "Cache-Control", value: "public, max-age=3600")
        headers.add(name: "X-Content-Type-Options", value: "nosniff")
        headers.add(name: "X-Frame-Options", value: "DENY")
        if contentType.contains("text/html") {
            headers.add(name: "Content-Security-Policy", value: "default-src 'self'; style-src 'unsafe-inline'; connect-src 'self' wss: ws:")
        }

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}
