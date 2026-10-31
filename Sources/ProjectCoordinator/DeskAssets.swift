import Foundation

/// Logos, favicon, PWA manifest, and raster icons for the local desk.
public enum DeskAssets {
    public static let themeColorLight = "#2f5d50"
    public static let themeColorDark = "#161513"
    public static let backgroundColor = "#f6f4ef"
    public static let displayName = "Dev Project Coordinator"
    public static let shortName = "DPC"

    public static let logoLightSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" class="logo logo-light" role="img" aria-hidden="true"><rect width="512" height="512" rx="114" fill="#2f5d50"/><g fill="#f6f4ef"><rect x="103" y="146" width="34" height="220" rx="17"/><rect x="171" y="146" width="34" height="220" rx="17"/><rect x="239" y="146" width="34" height="220" rx="17" fill="#7fa598"/><rect x="307" y="226" width="34" height="140" rx="17"/><rect x="375" y="146" width="34" height="220" rx="17"/></g><rect x="290" y="128" width="96" height="66" rx="18" fill="#8fbfb0" transform="rotate(-9 338 161)"/></svg>
    """

    public static let logoDarkSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" class="logo logo-dark" role="img" aria-hidden="true"><rect width="512" height="512" rx="114" fill="#161513"/><g fill="#f3efe6"><rect x="103" y="146" width="34" height="220" rx="17"/><rect x="171" y="146" width="34" height="220" rx="17"/><rect x="239" y="146" width="34" height="220" rx="17" fill="#5d5a52"/><rect x="307" y="226" width="34" height="140" rx="17"/><rect x="375" y="146" width="34" height="220" rx="17"/></g><rect x="290" y="128" width="96" height="66" rx="18" fill="#8fbfb0" transform="rotate(-9 338 161)"/></svg>
    """

    /// 16px mark: three bars plus the lifted card, thicker strokes.
    public static let faviconSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><rect width="16" height="16" rx="3.6" fill="#2f5d50"/><g fill="#f6f4ef"><rect x="2.2" y="3.4" width="2.8" height="9.2" rx="1.4"/><rect x="6.6" y="3.4" width="2.8" height="9.2" rx="1.4"/><rect x="11" y="6.4" width="2.8" height="6.2" rx="1.4"/></g><rect x="8.4" y="2.2" width="5.6" height="3.8" rx="1.1" fill="#8fbfb0" transform="rotate(-9 11.2 4.1)"/></svg>
    """

    public static var faviconDataURI: String {
        "data:image/svg+xml;base64,\(Data(faviconSVG.utf8).base64EncodedString())"
    }

    public static func manifestJSON() -> String {
        """
        {
          "name": "\(displayName)",
          "short_name": "\(shortName)",
          "display": "standalone",
          "start_url": "/",
          "scope": "/",
          "theme_color": "\(themeColorLight)",
          "background_color": "\(backgroundColor)",
          "icons": [
            { "src": "/icon-180.png", "sizes": "180x180", "type": "image/png" },
            { "src": "/icon-192.png", "sizes": "192x192", "type": "image/png" },
            { "src": "/icon-512.png", "sizes": "512x512", "type": "image/png" },
            { "src": "/icon.svg", "sizes": "any", "type": "image/svg+xml", "purpose": "any" }
          ]
        }
        """
    }

    public static func pngIcon(size: Int) -> Data? {
        let name: String
        switch size {
        case 180: name = "icon-180"
        case 192: name = "icon-192"
        case 512: name = "icon-512"
        default: return nil
        }
        guard let url = Bundle.module.url(forResource: name, withExtension: "png") else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    public static func headMarkup(mode: DeskPageMode) -> String {
        var tags = """
        <link rel="icon" href="\(faviconDataURI)">
        <meta name="theme-color" content="\(themeColorLight)" media="(prefers-color-scheme: light)">
        <meta name="theme-color" content="\(themeColorDark)" media="(prefers-color-scheme: dark)">
        <meta name="apple-mobile-web-app-capable" content="yes">
        <meta name="mobile-web-app-capable" content="yes">
        <meta name="apple-mobile-web-app-title" content="\(shortName)">
        """
        if mode == .live {
            tags += """
            <link rel="manifest" href="/manifest.webmanifest">
            <link rel="apple-touch-icon" href="/icon-180.png">
            """
        }
        return tags
    }
}
