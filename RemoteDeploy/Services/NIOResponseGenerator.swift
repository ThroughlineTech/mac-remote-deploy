// Response generators for the OTA deployment routes — install page, manifest,
// IPA download, index page, and PWA static files. Implemented as an extension
// on HTTPHandler so they have full access to the channel context and the
// owning server's project store, while keeping the routing dispatcher in
// HTTPHandler.swift focused on URL → method dispatch.
import Foundation
import NIO
import NIOHTTP1

extension HTTPHandler {

    /// Serves the HTML install page for a project at GET /<slug>/.
    /// For iOS projects, shows an itms-services install page.
    /// For macOS projects, shows a direct download page linking to app.zip.
    func serveInstallPage(context: ChannelHandlerContext, project: ProjectConfig, slug: String) {
        let baseURL = server.currentBaseURL()

        // Determine artifact path for build-time metadata
        let isMacOS = project.platform.lowercased() == "macos"
        let artifactPath = isMacOS
            ? "\(server.serveRoot)/\(slug)/app.zip"
            : "\(server.serveRoot)/\(slug)/app.ipa"

        let version = "1.0.0"
        let build = "1"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm z"
        let buildTime: String
        if let attrs = try? FileManager.default.attributesOfItem(atPath: artifactPath),
           let modDate = attrs[.modificationDate] as? Date {
            buildTime = formatter.string(from: modDate)
        } else {
            buildTime = formatter.string(from: Date())
        }

        let html: String
        if isMacOS {
            let downloadURL = "\(baseURL)/\(slug)/app.zip"
            html = server.installPageGenerator.generateDownloadPage(
                appName: project.name,
                version: version,
                build: build,
                buildTime: buildTime,
                downloadURL: downloadURL
            )
        } else {
            let manifestURL = "\(baseURL)/\(slug)/manifest.plist"
            html = server.installPageGenerator.generatePage(
                appName: project.name,
                version: version,
                build: build,
                buildTime: buildTime,
                manifestURL: manifestURL
            )
        }
        sendResponse(context: context, status: .ok, contentType: "text/html", body: html)
    }

    /// Serves the OTA manifest.plist XML for a project at GET /<slug>/manifest.plist.
    /// Returns 404 for macOS projects since OTA manifests are iOS-only.
    func serveManifest(context: ChannelHandlerContext, project: ProjectConfig, slug: String) {
        if project.platform.lowercased() == "macos" {
            sendNotFound(context: context)
            return
        }
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

    /// Serves the macOS app zip download at GET /<slug>/app.zip.
    /// Records the download via both the onIPADownload callback and the delegate.
    func serveAppZip(context: ChannelHandlerContext, project: ProjectConfig, slug: String, head: HTTPRequestHead) {
        let zipPath = "\(server.serveRoot)/\(slug)/app.zip"
        guard FileManager.default.fileExists(atPath: zipPath) else {
            sendNotFound(context: context)
            return
        }

        // Notify delegate/callback about the download (reusing IPA tracking)
        let sourceIP = head.headers["X-Forwarded-For"].first
            ?? context.remoteAddress?.description
            ?? "unknown"
        let userAgent = head.headers["User-Agent"].first ?? "unknown"

        server.onIPADownload?(slug, sourceIP, userAgent)

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

        sendFileResponse(
            context: context,
            filePath: zipPath,
            contentType: "application/zip",
            filename: "\(project.name).zip"
        )
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
    /// Maps a site-root filename to a bundled pwa/ file ("" or "/" -> index.html).
    /// Files are loaded from the main bundle's resource path.
    ///
    /// - Parameter context: The channel handler context to write the response to.
    /// - Parameter filename: The site-root file name (e.g. "index.html", "style.css").
    func servePWAFile(context: ChannelHandlerContext, filename rawFilename: String) {
        var filename = rawFilename
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

        responseStatusForLogging = .ok
        var buffer = context.channel.allocator.buffer(capacity: fileData.count)
        buffer.writeBytes(fileData)

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: "\(fileData.count)")
        headers.add(name: "Connection", value: "close")
        // No long-lived caching: the PWA assets are unversioned and change on
        // every deploy. `max-age=3600` (plus the service worker) used to pin the
        // old app shell in browsers so server updates never reached users. Force
        // revalidation so a redeploy is picked up on the next load.
        headers.add(name: "Cache-Control", value: "no-cache")
        headers.add(name: "X-Content-Type-Options", value: "nosniff")
        headers.add(name: "X-Frame-Options", value: "DENY")
        if contentType.contains("text/html") {
            headers.add(name: "Content-Security-Policy", value: pwaContentSecurityPolicy)
        }

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}
