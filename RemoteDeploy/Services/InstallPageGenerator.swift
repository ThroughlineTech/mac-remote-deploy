// Concrete implementation of InstallPageGenerating.
// Produces the HTML install page that iOS users visit to trigger OTA installation,
// and an index page that lists all available projects.
import Foundation

final class InstallPageGenerator: InstallPageGenerating {

    /// Generates a self-contained, mobile-optimized HTML page for OTA app installation.
    ///
    /// The page displays the app name, version, build number, and build time alongside
    /// a prominent blue "Install" button. Tapping the button opens an `itms-services://`
    /// URL that triggers iOS's native OTA installation flow.
    ///
    /// - Parameter appName: The display name of the app (page heading).
    /// - Parameter version: The short version string, e.g. "1.2.0".
    /// - Parameter build: The build number, e.g. "42".
    /// - Parameter buildTime: Human-readable timestamp of when the IPA was built.
    /// - Parameter manifestURL: Full HTTPS URL to the OTA manifest.plist endpoint.
    /// - Returns: A complete HTML string ready to be served as `text/html`.
    func generatePage(appName: String, version: String, build: String, buildTime: String, manifestURL: String) -> String {
        return Self.installTemplate
            .replacingOccurrences(of: "{{APP_NAME}}", with: htmlEscape(appName))
            .replacingOccurrences(of: "{{VERSION}}", with: htmlEscape(version))
            .replacingOccurrences(of: "{{BUILD}}", with: htmlEscape(build))
            .replacingOccurrences(of: "{{BUILD_TIME}}", with: htmlEscape(buildTime))
            .replacingOccurrences(of: "{{MANIFEST_URL}}", with: htmlEscape(manifestURL))
    }

    /// Generates a self-contained HTML page for macOS app download.
    /// Shows a "Download" button that links directly to the zip file URL
    /// instead of using `itms-services://`.
    func generateDownloadPage(appName: String, version: String, build: String, buildTime: String, downloadURL: String) -> String {
        return Self.downloadTemplate
            .replacingOccurrences(of: "{{APP_NAME}}", with: htmlEscape(appName))
            .replacingOccurrences(of: "{{VERSION}}", with: htmlEscape(version))
            .replacingOccurrences(of: "{{BUILD}}", with: htmlEscape(build))
            .replacingOccurrences(of: "{{BUILD_TIME}}", with: htmlEscape(buildTime))
            .replacingOccurrences(of: "{{DOWNLOAD_URL}}", with: htmlEscape(downloadURL))
    }

    /// Generates an HTML index page that lists all available projects with install links.
    ///
    /// Each project is rendered as a card showing its name and version, linking to
    /// the project's install page.
    ///
    /// - Parameter projects: An array of tuples containing each project's display name,
    ///   URL slug (used to build the link), and optional version string.
    /// - Returns: A complete HTML string ready to be served as `text/html`.
    func generateIndexPage(projects: [(name: String, slug: String, version: String?)]) -> String {
        let projectRows = projects.map { project in
            let versionLabel = project.version.map { " v\(htmlEscape($0))" } ?? ""
            return """
                        <a href="/\(htmlEscape(project.slug))/" class="project-card">
                            <span class="project-name">\(htmlEscape(project.name))\(versionLabel)</span>
                            <span class="arrow">&rsaquo;</span>
                        </a>
            """
        }.joined(separator: "\n")

        return Self.indexTemplate
            .replacingOccurrences(of: "{{PROJECT_LIST}}", with: projectRows)
    }

    // MARK: - Private

    /// Escapes characters that are meaningful in HTML to prevent injection.
    private func htmlEscape(_ string: String) -> String {
        var result = string
        result = result.replacingOccurrences(of: "&", with: "&amp;")
        result = result.replacingOccurrences(of: "<", with: "&lt;")
        result = result.replacingOccurrences(of: ">", with: "&gt;")
        result = result.replacingOccurrences(of: "\"", with: "&quot;")
        result = result.replacingOccurrences(of: "'", with: "&#39;")
        return result
    }

    // MARK: - Templates

    private static let installTemplate = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
        <title>Install {{APP_NAME}}</title>
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
                background: #f2f2f7;
                color: #1c1c1e;
                display: flex;
                justify-content: center;
                align-items: center;
                min-height: 100vh;
                padding: 20px;
            }
            .card {
                background: #fff;
                border-radius: 16px;
                padding: 40px 32px;
                max-width: 380px;
                width: 100%;
                text-align: center;
                box-shadow: 0 2px 12px rgba(0,0,0,0.08);
            }
            h1 {
                font-size: 24px;
                font-weight: 700;
                margin-bottom: 8px;
            }
            .meta {
                font-size: 14px;
                color: #8e8e93;
                margin-bottom: 4px;
            }
            .install-btn {
                display: inline-block;
                margin-top: 28px;
                padding: 14px 48px;
                background: #007aff;
                color: #fff;
                font-size: 17px;
                font-weight: 600;
                border-radius: 12px;
                text-decoration: none;
                transition: background 0.2s;
            }
            .install-btn:active {
                background: #0056b3;
            }
        </style>
    </head>
    <body>
        <div class="card">
            <h1>{{APP_NAME}}</h1>
            <p class="meta">Version {{VERSION}} ({{BUILD}})</p>
            <p class="meta">Built {{BUILD_TIME}}</p>
            <a class="install-btn" href="itms-services://?action=download-manifest&url={{MANIFEST_URL}}">Install</a>
        </div>
    </body>
    </html>
    """

    private static let downloadTemplate = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
        <title>Download {{APP_NAME}}</title>
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
                background: #f2f2f7;
                color: #1c1c1e;
                display: flex;
                justify-content: center;
                align-items: center;
                min-height: 100vh;
                padding: 20px;
            }
            .card {
                background: #fff;
                border-radius: 16px;
                padding: 40px 32px;
                max-width: 380px;
                width: 100%;
                text-align: center;
                box-shadow: 0 2px 12px rgba(0,0,0,0.08);
            }
            h1 {
                font-size: 24px;
                font-weight: 700;
                margin-bottom: 8px;
            }
            .meta {
                font-size: 14px;
                color: #8e8e93;
                margin-bottom: 4px;
            }
            .platform-badge {
                display: inline-block;
                font-size: 12px;
                color: #8e8e93;
                border: 1px solid #c7c7cc;
                border-radius: 6px;
                padding: 2px 8px;
                margin-bottom: 12px;
            }
            .download-btn {
                display: inline-block;
                margin-top: 28px;
                padding: 14px 48px;
                background: #007aff;
                color: #fff;
                font-size: 17px;
                font-weight: 600;
                border-radius: 12px;
                text-decoration: none;
                transition: background 0.2s;
            }
            .download-btn:active {
                background: #0056b3;
            }
        </style>
    </head>
    <body>
        <div class="card">
            <h1>{{APP_NAME}}</h1>
            <span class="platform-badge">macOS</span>
            <p class="meta">Version {{VERSION}} ({{BUILD}})</p>
            <p class="meta">Built {{BUILD_TIME}}</p>
            <a class="download-btn" href="{{DOWNLOAD_URL}}">Download</a>
        </div>
    </body>
    </html>
    """

    private static let indexTemplate = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
        <title>RemoteDeploy</title>
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
                background: #f2f2f7;
                color: #1c1c1e;
                display: flex;
                justify-content: center;
                padding: 40px 20px;
            }
            .container {
                max-width: 420px;
                width: 100%;
            }
            h1 {
                font-size: 28px;
                font-weight: 700;
                margin-bottom: 20px;
                text-align: center;
            }
            .project-card {
                display: flex;
                justify-content: space-between;
                align-items: center;
                background: #fff;
                border-radius: 12px;
                padding: 16px 20px;
                margin-bottom: 10px;
                text-decoration: none;
                color: #1c1c1e;
                box-shadow: 0 1px 4px rgba(0,0,0,0.06);
                transition: background 0.15s;
            }
            .project-card:active {
                background: #e5e5ea;
            }
            .project-name {
                font-size: 17px;
                font-weight: 500;
            }
            .arrow {
                font-size: 22px;
                color: #c7c7cc;
                font-weight: 300;
            }
            .empty {
                text-align: center;
                color: #8e8e93;
                margin-top: 40px;
                font-size: 15px;
            }
        </style>
    </head>
    <body>
        <div class="container">
            <h1>RemoteDeploy</h1>
            {{PROJECT_LIST}}
        </div>
    </body>
    </html>
    """
}
