// SwiftNIO channel handler that routes HTTP/1.1 requests to the appropriate
// response generator. API requests under /api/ are delegated to APIRouter.
// All other requests are handled as OTA deployment routes (GET-only).
//
// This file contains the routing dispatcher and the low-level response writers
// (sendDataResponse, sendResponse, sendFileResponse, sendNotFound, htmlEscape).
// The response generators that build install pages, manifests, and IPA downloads
// live in NIOResponseGenerator.swift as an extension on this class.
import Foundation
import NIO
import NIOHTTP1
import NIOFoundationCompat
import os

/// Channel handler that processes incoming HTTP/1.1 requests and routes them to the
/// appropriate response: API endpoints, index page, project install page, OTA manifest,
/// or IPA download.
///
/// This handler accumulates the full request (head + body + end) before responding.
/// API requests under /api/ are delegated to the APIRouter. All other requests
/// are handled as OTA deployment routes.
final class HTTPHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    /// Reference to the owning server, used to access project configs, generators, and callbacks.
    let server: NIODeployServer

    /// Accumulated request head for the current request being processed.
    private var requestHead: HTTPRequestHead?

    /// Accumulated request body bytes for the current request.
    private var requestBody: Data = Data()

    /// Maximum request body size (1 MB) to prevent abuse.
    private static let maxBodySize = 1_048_576

    /// Optional API router for handling /api/ endpoints.
    var apiRouter: APIRouter?

    /// When true, rejects pairing requests over this handler (used for the plain-HTTP listener
    /// to prevent bearer tokens from being transmitted in cleartext).
    var rejectPairingOverHTTP = false

    /// Resolved HTTP response status for the in-flight request, set by each `send*` writer
    /// (and by `servePWAFile` in the extension file) just before flushing. Read by
    /// `handleRequest`'s `defer` block to log the request line. Internal so the response
    /// generators in `NIOResponseGenerator.swift` can update it.
    var responseStatusForLogging: HTTPResponseStatus?

    init(server: NIODeployServer) {
        self.server = server
    }

    /// Called by SwiftNIO when an HTTP request part arrives on the channel.
    ///
    /// HTTP/1.1 requests arrive in three parts: `.head` (method, URI, headers),
    /// `.body` (optional payload), and `.end` (trailing headers). We buffer the head
    /// and body, then process the full request once `.end` is received.
    ///
    /// - Parameter context: The channel handler context for writing responses.
    /// - Parameter data: The inbound HTTP request part (head, body, or end).
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
            requestHead = head
            requestBody = Data()

        case .body(let buffer):
            // Accumulate request body bytes for API endpoints.
            if requestBody.count + buffer.readableBytes <= Self.maxBodySize {
                var buf = buffer
                if let bytes = buf.readBytes(length: buf.readableBytes) {
                    requestBody.append(contentsOf: bytes)
                }
            }

        case .end:
            guard let head = requestHead else { return }
            requestHead = nil
            let body = requestBody
            requestBody = Data()
            handleRequest(context: context, head: head, body: body)
        }
    }

    /// Routes the fully-received HTTP request to the appropriate handler.
    ///
    /// Requests to /api/ are dispatched to the APIRouter. All other requests
    /// are handled as OTA deployment routes (GET-only).
    ///
    /// - Parameter context: The channel handler context for writing the response.
    /// - Parameter head: The HTTP request head containing method, URI, and headers.
    /// - Parameter body: The accumulated request body.
    private func handleRequest(context: ChannelHandlerContext, head: HTTPRequestHead, body: Data) {
        let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri

        // Log request method/path/status/duration on the way out, regardless of which response
        // writer fired. Status is captured by the writers via responseStatusForLogging.
        let start = ContinuousClock.now
        responseStatusForLogging = nil
        defer {
            let elapsedMs = (ContinuousClock.now - start).components.attoseconds / 1_000_000_000_000_000
            let statusCode = responseStatusForLogging?.code ?? 0
            Logger.api.info("\(head.method.rawValue, privacy: .public) \(path, privacy: .private) -> \(statusCode, privacy: .public) (\(elapsedMs, privacy: .public)ms)")
        }

        // TKT-011 / TKT-024 Commit 6: if a request to /api/v1/ws reaches here,
        // the WebSocket upgrader in NIODeployServer rejected it (missing or
        // invalid bearer token, or missing Upgrade header). Return 401 so
        // clients see the intended error instead of a generic 404 from the
        // fall-through below.
        if path == "/api/v1/ws" {
            sendResponse(context: context, status: .unauthorized, contentType: "text/plain", body: "Unauthorized")
            return
        }

        // Delegate API requests to the router
        if let router = apiRouter, router.shouldHandle(path: path) {
            // Block pairing over plain HTTP to prevent token interception
            if rejectPairingOverHTTP && path == "/api/v1/pair" {
                let err = APIResponse.error(status: .forbidden, message: "Pairing requires HTTPS. Connect via Tailscale or use the HTTPS port.")
                sendDataResponse(context: context, status: err.status, contentType: err.contentType, data: err.body)
                return
            }
            // Handle CORS preflight requests
            if head.method == .OPTIONS {
                sendDataResponse(context: context, status: .noContent, contentType: "text/plain", data: Data())
                return
            }
            let apiRequest = APIRequest(head: head, body: body)
            let apiResponse = router.handle(apiRequest)
            sendDataResponse(context: context, status: apiResponse.status, contentType: apiResponse.contentType, data: apiResponse.body)
            return
        }

        // Back-compat: the PWA used to live under /app/ (TKT-061). It is now the
        // canonical client at the site root (TKT-064); redirect old /app/ URLs
        // (installed PWAs, bookmarks) to the matching root path.
        if path == "/app" || path == "/app/" {
            sendRedirect(context: context, location: "/")
            return
        }
        if path.hasPrefix("/app/") {
            sendRedirect(context: context, location: "/" + path.dropFirst("/app/".count))
            return
        }

        // OTA + PWA routes are GET-only.
        guard head.method == .GET else {
            sendResponse(context: context, status: .methodNotAllowed, contentType: "text/plain", body: "Method Not Allowed")
            return
        }

        // The PWA is served from the site root. The root document and any
        // single-segment static asset (style.css, app.js, manifest.json, sw.js,
        // icon.svg, ...) map to the bundled pwa/ files. Project slugs never
        // contain a ".", so a dotted single-segment path is always a PWA asset
        // and slug routing still wins for real slugs (which have no dot).
        if path == "/" {
            servePWAFile(context: context, filename: "index.html")
            return
        }
        if !path.dropFirst().contains("/") && path.contains(".") {
            servePWAFile(context: context, filename: String(path.dropFirst()))
            return
        }

        let projects = server.registeredProjects()

        // Parse /<slug>/... pattern
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let slugSubstring = components.first else {
            sendNotFound(context: context)
            return
        }
        let slug = String(slugSubstring)

        guard let project = projects[slug] else {
            sendNotFound(context: context)
            return
        }

        let subpath = components.count > 1 ? String(components[1]) : ""

        switch subpath {
        case _ where subpath.isEmpty,
             _ where path.hasSuffix("/") && components.count == 1:
            serveInstallPage(context: context, project: project, slug: slug)

        case "manifest.plist":
            serveManifest(context: context, project: project, slug: slug)

        case "app.ipa":
            serveIPA(context: context, project: project, slug: slug, head: head)

        case "app.zip":
            serveAppZip(context: context, project: project, slug: slug, head: head)

        default:
            sendNotFound(context: context)
        }
    }

    // MARK: - Response Writers

    /// Sends an HTTP response with raw Data body.
    ///
    /// Used by the API router to send JSON responses.
    ///
    /// - Parameter context: The channel handler context to write the response to.
    /// - Parameter status: The HTTP status code.
    /// - Parameter contentType: The Content-Type header value.
    /// - Parameter data: The response body as raw bytes.
    func sendDataResponse(
        context: ChannelHandlerContext,
        status: HTTPResponseStatus,
        contentType: String,
        data: Data
    ) {
        responseStatusForLogging = status
        var buffer = context.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: "\(data.count)")
        headers.add(name: "Connection", value: "close")
        headers.add(name: "X-Content-Type-Options", value: "nosniff")
        // No CORS wildcard — the PWA is served from the same origin so it doesn't need CORS.
        // Cross-origin requests (e.g. from a dev tool) will be blocked by the browser.

        let responseHead = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    /// Sends an HTTP response with a string body.
    ///
    /// Writes the full HTTP response (head + body + end) to the channel and flushes.
    /// The connection is closed after the response via the `close` header.
    ///
    /// - Parameter context: The channel handler context to write the response to.
    /// - Parameter status: The HTTP status code (e.g. .ok, .notFound).
    /// - Parameter contentType: The Content-Type header value (e.g. "text/html").
    /// - Parameter body: The response body as a UTF-8 string.
    func sendResponse(
        context: ChannelHandlerContext,
        status: HTTPResponseStatus,
        contentType: String,
        body: String
    ) {
        responseStatusForLogging = status
        let bodyData = Data(body.utf8)
        var buffer = context.channel.allocator.buffer(capacity: bodyData.count)
        buffer.writeBytes(bodyData)

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: "\(bodyData.count)")
        headers.add(name: "Connection", value: "close")
        headers.add(name: "X-Content-Type-Options", value: "nosniff")
        headers.add(name: "X-Frame-Options", value: "DENY")
        if contentType.contains("text/html") {
            headers.add(name: "Content-Security-Policy", value: pwaContentSecurityPolicy)
        }

        let responseHead = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    /// Content-Security-Policy for HTML responses (PWA shell + OTA install pages).
    /// Same-origin only, with two carve-outs the UI genuinely needs:
    ///   - `style-src 'self'` so the bundled /style.css <link> actually loads
    ///     ('unsafe-inline' alone blocks same-origin stylesheets - TKT-064),
    ///     plus 'unsafe-inline' for the install pages' inline <style>.
    ///   - `img-src 'self' data:` so the stylesheet's inline data: SVG icons and
    ///     masks render (default-src 'self' would block data: images).
    var pwaContentSecurityPolicy: String {
        "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; connect-src 'self' wss: ws:"
    }

    /// Sends a 302 redirect to `location`. Points legacy /app/ URLs at the PWA's
    /// canonical site-root home (TKT-064). 302 (not 301) keeps the mapping
    /// uncached and reversible.
    func sendRedirect(context: ChannelHandlerContext, location: String) {
        responseStatusForLogging = .found
        var headers = HTTPHeaders()
        headers.add(name: "Location", value: location)
        headers.add(name: "Content-Length", value: "0")
        headers.add(name: "Connection", value: "close")
        headers.add(name: "X-Content-Type-Options", value: "nosniff")
        let responseHead = HTTPResponseHead(version: .http1_1, status: .found, headers: headers)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    /// Sends a binary file as an HTTP response.
    ///
    /// Reads the entire file into memory and writes it as a single response. For typical
    /// IPA/zip files (10-100 MB), this is acceptable for a local-network deployment tool.
    ///
    /// - Parameter context: The channel handler context to write the response to.
    /// - Parameter filePath: Absolute path to the file to serve.
    /// - Parameter contentType: The Content-Type header value. Defaults to `application/octet-stream`.
    /// - Parameter filename: The filename used in the Content-Disposition header. Defaults to `app.ipa`.
    func sendFileResponse(
        context: ChannelHandlerContext,
        filePath: String,
        contentType: String = "application/octet-stream",
        filename: String = "app.ipa"
    ) {
        guard let fileData = FileManager.default.contents(atPath: filePath) else {
            sendNotFound(context: context)
            return
        }

        responseStatusForLogging = .ok
        var buffer = context.channel.allocator.buffer(capacity: fileData.count)
        buffer.writeBytes(fileData)

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: "\(fileData.count)")
        headers.add(name: "Content-Disposition", value: "attachment; filename=\"\(filename)\"")
        headers.add(name: "Connection", value: "close")
        headers.add(name: "X-Content-Type-Options", value: "nosniff")
        headers.add(name: "X-Frame-Options", value: "DENY")

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    /// Sends a 404 Not Found response with a plain-text body.
    ///
    /// - Parameter context: The channel handler context to write the response to.
    func sendNotFound(context: ChannelHandlerContext) {
        sendResponse(context: context, status: .notFound, contentType: "text/plain", body: "404 Not Found")
    }

    /// Escapes HTML special characters to prevent XSS.
    func htmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
