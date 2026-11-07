import Foundation
import ZIPFoundation

public enum WarnFeed: Sendable { case diff, stat }

public enum WarnFeedResponse: Sendable, Equatable {
    case notModified
    case xmlFiles([Data], etag: String?)
}

public protocol WarnFeedSource: Sendable {
    func fetch(feed: WarnFeed, lang: String, ifNoneMatch: String?) async throws -> WarnFeedResponse
}

public struct WarnFeedError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Raw HTTP answer of one GET (status, ETag header, body). The transport (AsyncHTTPClient in the executable) enforces `maxBytes`
/// while reading and sends `If-None-Match` when given; no cookies, no identifying headers.
public struct WarnHTTPResponse: Sendable {
    public var status: Int, etag: String?, body: Data
    public init(status: Int, etag: String?, body: Data) { self.status = status; self.etag = etag; self.body = body }
}
public typealias WarnHTTPGet = @Sendable (_ url: String, _ ifNoneMatch: String?, _ maxBytes: Int) async throws -> WarnHTTPResponse

/// DWD opendata CAP feed (municipality union, DWD premium product): `..._LATEST_...zip` of the DIFF (changes of the last minutes)
/// and STAT (full status) directories, German and English only. Reading is gentle: conditional requests, hard size limits.
public struct DWDWarnFeedSource: WarnFeedSource {
    public static let maxZipBytes = 2 * 1024 * 1024
    public static let maxEntries = 5_000
    public static let maxFileBytes = 4 * 1024 * 1024
    public static let baseURL = "https://opendata.dwd.de/weather/alerts/cap"

    let get: WarnHTTPGet
    let base: String
    public init(base: String = DWDWarnFeedSource.baseURL, get: @escaping WarnHTTPGet) { self.base = base; self.get = get }

    public static func url(base: String = baseURL, feed: WarnFeed, lang: String) throws -> String {
        guard lang == "de" || lang == "en" else { throw WarnFeedError("unsupported language") }
        let (dir, kind) = feed == .diff ? ("DIFF", "DIFFERENCE") : ("STAT", "STATUS")
        return "\(base)/COMMUNEUNION_DWD_\(dir)/Z_CAP_C_EDZW_LATEST_PVW_\(kind)_PREMIUMDWD_COMMUNEUNION_\(lang.uppercased()).zip"
    }

    public func fetch(feed: WarnFeed, lang: String, ifNoneMatch: String?) async throws -> WarnFeedResponse {
        let response = try await get(try Self.url(base: base, feed: feed, lang: lang), ifNoneMatch, Self.maxZipBytes)
        if response.status == 304 { return .notModified }
        guard response.status == 200 else { throw WarnFeedError("unexpected status \(response.status)") }
        return .xmlFiles(try Self.xmlFiles(inZip: response.body), etag: response.etag)
    }

    /// An empty ZIP (no changes) yields no files. Bomb protection: declared and actual size per file, entry count, archive size.
    public static func xmlFiles(inZip data: Data) throws -> [Data] {
        guard data.count <= maxZipBytes else { throw WarnFeedError("zip too large") }
        guard data.count > 22 else { return [] }   // shorter than an end-of-central-directory record: empty archive
        let archive: Archive
        do { archive = try Archive(data: data, accessMode: .read) } catch { throw WarnFeedError("unreadable zip") }
        var files: [Data] = []
        var count = 0
        for entry in archive {
            count += 1
            guard count <= maxEntries else { throw WarnFeedError("too many entries") }
            guard entry.type == .file, entry.path.lowercased().hasSuffix(".xml") else { continue }
            guard entry.uncompressedSize <= UInt64(maxFileBytes) else { throw WarnFeedError("entry too large") }
            var content = Data()
            do {
                _ = try archive.extract(entry, skipCRC32: false) { chunk in
                    content.append(chunk)
                    if content.count > maxFileBytes { throw WarnFeedError("entry too large") }
                }
            } catch let error as WarnFeedError { throw error } catch { throw WarnFeedError("unreadable zip entry") }
            files.append(content)
        }
        return files
    }
}
