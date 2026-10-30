import Foundation

public enum RadarConstants {
    /// Germany in EPSG:3857 (approx. 5.5-15.6 E, 47.0-55.1 N), as measured in docs/decisions.md.
    public static let bbox: [Double] = [612257.0, 5942074.0, 1736584.0, 7381298.0]
    public static let layer = "dwd:Niederschlagsradar"
    public static let attribution = "Quelle: Deutscher Wetterdienst"
    public static let modificationNotice = "Datenbasis: Deutscher Wetterdienst, Rasterdaten bildlich wiedergegeben"

    public static func imageHeight(width: Int) -> Int {
        Int(((Double(width) * (bbox[3] - bbox[1]) / (bbox[2] - bbox[0]))).rounded(.toNearestOrEven))
    }

    public static func mercatorToWGS84(x: Double, y: Double) -> (lon: Double, lat: Double) {
        let radius = 6378137.0
        let lon = x / radius * 180 / .pi
        let lat = (2 * atan(exp(y / radius)) - .pi / 2) * 180 / .pi
        return (lon, lat)
    }
}

public struct ConfigError: Error, CustomStringConvertible {
    public let description: String
}

/// Configuration from environment variables (no secrets are needed in stage 1).
public struct Config: Sendable {
    public var dbHost = "127.0.0.1"
    public var dbPort = 3306
    public var dbName = "showernow"
    public var dbUser = "showernow"
    public var dbPassword = ""
    public var dbPoolSize = 4
    public var httpPort = 8080
    public var cacheMaxBytes = 64 * 1024 * 1024
    public var leaseSeconds = 150
    public var maxRunAttempts = 2
    public var wmsURL = "https://maps.dwd.de/geoserver/ows"
    public var width = 1024
    public var retentionRuns = 16
    public var workers = 3
    public var availabilityDelaySeconds = 200.0
    public var jitterSeconds = 20.0
    public var requestTimeoutSeconds = 30.0
    public var userAgent = "ShowerNow-radar-ingest/1.0"
    public var migrationsDirectory = "migrations"
    public var site = SiteInfo()

    public init() {}

    public var height: Int { RadarConstants.imageHeight(width: width) }

    /// Secret from NAME_FILE (Swarm secret, preferred) or NAME; never logged.
    private static func secret(_ env: [String: String], _ name: String, _ fallback: String) throws -> String {
        if let path = env["\(name)_FILE"], !path.isEmpty {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return env[name] ?? fallback
    }

    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) throws -> Config {
        var c = Config()
        func int(_ key: String, _ fallback: Int) throws -> Int {
            guard let raw = env[key] else { return fallback }
            guard let value = Int(raw) else { throw ConfigError(description: "\(key) must be an integer") }
            return value
        }
        func double(_ key: String, _ fallback: Double) throws -> Double {
            guard let raw = env[key] else { return fallback }
            guard let value = Double(raw) else { throw ConfigError(description: "\(key) must be a number") }
            return value
        }
        c.dbHost = env["DB_HOST"] ?? c.dbHost
        c.dbPort = try int("DB_PORT", c.dbPort)
        c.dbName = env["DB_NAME"] ?? c.dbName
        c.dbUser = env["DB_USER"] ?? c.dbUser
        c.dbPassword = try secret(env, "DB_PASSWORD", c.dbPassword)
        c.dbPoolSize = try int("DB_POOL_SIZE", c.dbPoolSize)
        c.httpPort = try int("HTTP_PORT", c.httpPort)
        c.cacheMaxBytes = Int(try double("CACHE_MAX_MB", Double(c.cacheMaxBytes) / 1_048_576) * 1_048_576)
        c.wmsURL = env["WMS_URL"] ?? c.wmsURL
        c.width = try int("IMAGE_WIDTH", c.width)
        c.retentionRuns = try int("RETENTION_RUNS", c.retentionRuns)
        c.workers = try int("FETCH_WORKERS", c.workers)
        c.availabilityDelaySeconds = try double("AVAILABILITY_DELAY_SECONDS", c.availabilityDelaySeconds)
        c.jitterSeconds = try double("JITTER_SECONDS", c.jitterSeconds)
        c.requestTimeoutSeconds = try double("REQUEST_TIMEOUT_SECONDS", c.requestTimeoutSeconds)
        c.userAgent = env["USER_AGENT"] ?? c.userAgent
        c.migrationsDirectory = env["MIGRATIONS_DIR"] ?? c.migrationsDirectory
        func text(_ key: String) -> String { String((env[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)) }
        c.site.operatorName = text("OPERATOR_NAME")
        c.site.operatorAddress = text("OPERATOR_ADDRESS")
        c.site.operatorEmail = text("OPERATOR_EMAIL")
        c.site.proxyLogNote = text("PROXY_LOG_NOTE")
        c.site.appStoreURL = text("APP_STORE_URL")
        c.site.testflightURL = text("TESTFLIGHT_URL")
        guard (256...2048).contains(c.width) else { throw ConfigError(description: "IMAGE_WIDTH must be between 256 and 2048") }
        guard c.retentionRuns >= 15 else {
            throw ConfigError(description: "RETENTION_RUNS must be at least 15 (12 history analyses, current run, slack)")
        }
        guard (1...10).contains(c.dbPoolSize) else { throw ConfigError(description: "DB_POOL_SIZE must be between 1 and 10") }
        guard (1...6).contains(c.workers) else { throw ConfigError(description: "FETCH_WORKERS must be between 1 and 6") }
        return c
    }
}
