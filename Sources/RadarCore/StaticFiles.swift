import Crypto
import Foundation

/// Static delivery of the dashboard build (docs/dashboard-plan.md 2.3): files below one root only, no traversal, SPA fallback
/// to `index.html` for paths without extension, security headers on every answer.
public struct StaticSite: Sendable {
    public let root: String

    public init(root: String) {
        var r = root
        while r.count > 1, r.hasSuffix("/") { r.removeLast() }
        self.root = r
    }

    static let types: [String: String] = [
        "html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8", "mjs": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8", "json": "application/json", "svg": "image/svg+xml", "png": "image/png",
        "ico": "image/x-icon", "webp": "image/webp", "woff2": "font/woff2", "woff": "font/woff", "txt": "text/plain; charset=utf-8",
        "webmanifest": "application/manifest+json", "map": "application/json",
    ]

    /// Security headers for all dashboard answers; `scriptHashes` extend `script-src` for inline start scripts of the HTML shell.
    public static func securityHeaders(scriptHashes: [String] = []) -> [(String, String)] {
        let hashes = scriptHashes.map { " 'sha256-\($0)'" }.joined()
        let csp = "default-src 'none'; script-src 'self'\(hashes); style-src 'self'; style-src-attr 'unsafe-inline'; img-src 'self' data:; "
            + "font-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"
        return [("Content-Security-Policy", csp), ("X-Content-Type-Options", "nosniff"), ("Referrer-Policy", "no-referrer"),
                ("X-Frame-Options", "DENY"), ("Cross-Origin-Opener-Policy", "same-origin"), ("Cross-Origin-Resource-Policy", "same-origin")]
    }

    /// Normalizes a URL path below `/dash` into relative components; nil for anything unsafe.
    static func safeComponents(_ path: String) -> [String]? {
        guard !path.contains("\0"), !path.contains("\\"), !path.contains("%"), path.hasPrefix("/") else { return nil }
        var parts: [String] = []
        for p in path.split(separator: "/", omittingEmptySubsequences: true) {
            if p == "." || p == ".." || p.hasPrefix(".") { return nil }
            parts.append(String(p))
        }
        return parts
    }

    /// `path` is the full request path (starts with `/dash`).
    public func response(path: String) -> ApiResponse {
        guard var parts = Self.safeComponents(path), parts.first == "dash" else { return Self.notFound() }
        parts.removeFirst()
        var rel = parts.joined(separator: "/")
        let hasExtension = (parts.last ?? "").contains(".")
        if rel.isEmpty { rel = "index.html" }
        else if !hasExtension { rel = "index.html" }  // SPA fallback
        guard let data = read(rel) else { return Self.notFound() }
        let ext = (rel as NSString).pathExtension.lowercased()
        guard let type = Self.types[ext] else { return Self.notFound() }
        let isHTML = ext == "html"
        var hashes: [String] = []
        if isHTML { hashes = Self.inlineScriptHashes(String(decoding: data, as: UTF8.self)) }
        let cache = isHTML ? "no-cache" : (rel.hasPrefix("_app/immutable/") ? "public, max-age=31536000, immutable" : "no-cache")
        let headers = [("Content-Type", type), ("Cache-Control", cache)] + Self.securityHeaders(scriptHashes: hashes)
        return ApiResponse(status: 200, headers: headers, body: data)
    }

    private func read(_ rel: String) -> [UInt8]? {
        let full = root + "/" + rel
        // Resolve symlinks and confirm the file is still below the root.
        let resolvedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        let resolved = URL(fileURLWithPath: full).resolvingSymlinksInPath().path
        guard resolved.hasPrefix(resolvedRoot + "/") else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), !isDir.boolValue,
              let data = FileManager.default.contents(atPath: resolved) else { return nil }
        return Array(data)
    }

    static func inlineScriptHashes(_ html: String) -> [String] {
        var result: [String] = []
        var rest = Substring(html)
        while let open = rest.range(of: "<script") {
            rest = rest[open.upperBound...]
            guard let tagEnd = rest.firstIndex(of: ">") else { break }
            let tag = rest[..<tagEnd]
            rest = rest[rest.index(after: tagEnd)...]
            guard let close = rest.range(of: "</script>") else { break }
            let body = rest[..<close.lowerBound]
            rest = rest[close.upperBound...]
            if tag.contains("src=") || body.isEmpty { continue }
            result.append(Data(SHA256.hash(data: Array(body.utf8))).base64EncodedString())
        }
        return result
    }

    static func notFound() -> ApiResponse {
        ApiResponse(status: 404, headers: [("Cache-Control", "no-store")] + securityHeaders(), body: [])
    }
}
