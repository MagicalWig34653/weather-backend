import Foundation

// Configuration register of the dashboard (docs/dashboard-plan.md, section 5): every non-secret setting of `Config` with type,
// default, limits, effect (live / restart / env only) and the resolution ENV > dashboard value (database) > default.
// Secrets are listed so the dashboard can show that they exist, but their value is never part of any output model.

public enum ConfigApply: String, Sendable, Codable {
    /// Picked up by the running service within the 30 s reload (needs the consumer to read the snapshot per tick/request).
    case live
    /// Read once at start; a changed dashboard value needs the controlled restart.
    case restart
    /// Bootstrap or sensitive value: environment only, shown read-only, never writable through the dashboard.
    case envOnly
}

public enum ConfigTextRule: String, Sendable, Codable {
    case free, printableASCII, apnsIdentifier, bundleIdentifier
}

public enum ConfigKind: Sendable, Equatable {
    case int(min: Int, max: Int)
    case number(min: Double, max: Double)
    case text(maxLength: Int, rule: ConfigTextRule)
    /// `https` only, optionally restricted to one host.
    case url(host: String?, maxLength: Int)
    case bool
    case layers
    case choice([String])
    /// Not representable as a value (secrets).
    case secret

    public var name: String {
        switch self {
        case .int: "int"
        case .number: "number"
        case .text: "text"
        case .url: "url"
        case .bool: "bool"
        case .layers: "layers"
        case .choice: "choice"
        case .secret: "secret"
        }
    }
}

public enum ConfigSource: String, Sendable, Codable {
    case env, dashboard, `default`
}

public struct ConfigSetting: Sendable {
    public let key: String
    public let group: String
    /// Limits for values entered in the dashboard (may be stricter than what the environment loader accepts).
    public let kind: ConfigKind
    public let defaultValue: String
    public let unit: String?
    public let summary: String
    public let apply: ConfigApply
    public let secret: Bool
    /// The audit log stores only that the value changed (public operator texts).
    public let maskInAudit: Bool

    public var envOnly: Bool { apply == .envOnly }
    public var editable: Bool { !secret && apply != .envOnly }
}

public enum ConfigWriteError: Error, Equatable, Sendable, CustomStringConvertible {
    /// 404
    case unknownKey
    /// 403: secret or environment-only key
    case notEditable
    /// 409 `locked_by_env`
    case lockedByEnv
    /// 422
    case invalid(String)

    public var description: String {
        switch self {
        case .unknownKey: "unknown key"
        case .notEditable: "key is not editable"
        case .lockedByEnv: "locked by environment variable"
        case .invalid(let reason): reason
        }
    }
}

/// Read model for the dashboard. Contains no secret value: for secrets `value` and `defaultValue` stay nil, `isSet` says only
/// whether the environment provides one.
public struct ConfigEntry: Sendable, Codable, Equatable {
    public var key: String
    public var group: String
    public var type: String
    public var unit: String?
    public var summary: String
    public var apply: ConfigApply
    public var secret: Bool
    public var editable: Bool
    public var source: ConfigSource
    public var lockedByEnv: Bool
    public var value: String?
    public var defaultValue: String?
    public var isSet: Bool?
    public var minimum: Double?
    public var maximum: Double?
    public var maxLength: Int?
    public var choices: [String]?
    /// A stored dashboard value with `apply == .restart` differs from the value this process started with.
    public var restartPending: Bool
}

/// Dashboard values as loaded from storage; `revision` is the global counter (`max(revision)`), polled every 30 s.
public struct StoredConfig: Sendable, Equatable {
    public var values: [String: String]
    public var revision: Int
    public init(values: [String: String] = [:], revision: Int = 0) { self.values = values; self.revision = revision }
}

/// Storage of dashboard values. Shaped like `DashboardRepo.configState/setConfigOverride/resetConfigOverride` (WP1), which
/// writes value and audit entry in one transaction; `masked` = the audit log stores only "geändert" (public operator texts).
public protocol ConfigOverrideStore: Sendable {
    func loadOverrides() async throws -> StoredConfig
    /// Cheap poll of the global revision.
    func currentRevision() async throws -> Int
    /// Stores the value (+ audit `set`); returns the new revision.
    func setOverride(key: String, value: String, masked: Bool, now: Date) async throws -> Int
    /// Deletes the value (+ audit `reset`); nil if there was none.
    func resetOverride(key: String, masked: Bool, now: Date) async throws -> Int?
}

/// In-memory store for tests.
public actor MemoryConfigOverrideStore: ConfigOverrideStore {
    private var values: [String: String] = [:]
    private var revision = 0
    /// (action, key, masked) per write.
    public private(set) var audit: [(action: String, key: String, masked: Bool)] = []
    public init() {}

    public func loadOverrides() -> StoredConfig { StoredConfig(values: values, revision: revision) }
    public func currentRevision() -> Int { revision }
    public func setOverride(key: String, value: String, masked: Bool, now: Date) -> Int {
        revision += 1
        values[key] = value
        audit.append(("set", key, masked))
        return revision
    }
    public func resetOverride(key: String, masked: Bool, now: Date) -> Int? {
        guard values.removeValue(forKey: key) != nil else { return nil }
        revision += 1
        audit.append(("reset", key, masked))
        return revision
    }
}

public enum ConfigRegistry {
    private static func s(_ key: String, _ group: String, _ kind: ConfigKind, _ def: String, unit: String? = nil, _ summary: String,
                          _ apply: ConfigApply, mask: Bool = false) -> ConfigSetting {
        ConfigSetting(key: key, group: group, kind: kind, defaultValue: def, unit: unit, summary: summary, apply: apply,
                      secret: kind == .secret, maskInAudit: mask)
    }
    private static let any = ConfigKind.text(maxLength: 500, rule: .free)

    public static let settings: [ConfigSetting] = [
        // Bootstrap (environment only)
        s("DB_HOST", "Datenbank", any, "127.0.0.1", "Datenbank-Host (Bootstrap vor dem ersten DB-Zugriff).", .envOnly),
        s("DB_PORT", "Datenbank", .int(min: 1, max: 65535), "3306", "Datenbank-Port.", .envOnly),
        s("DB_NAME", "Datenbank", any, "showernow", "Name des Schemas.", .envOnly),
        s("DB_USER", "Datenbank", any, "showernow", "Datenbank-Benutzer.", .envOnly),
        s("DB_PASSWORD", "Datenbank", .secret, "", "Passwort (Swarm-Secret), nur per Umgebung.", .envOnly),
        s("DB_POOL_SIZE", "Datenbank", .int(min: 1, max: 10), "4", "Größe des Verbindungspools.", .envOnly),
        s("HTTP_PORT", "Dienst", .int(min: 1, max: 65535), "8080", "Port des Radar-Listeners.", .envOnly),
        s("REPLICA_SLOT", "Neustart", .int(min: 1, max: 99), "", "Replikat-Index aus dem Swarm-Template (Task.Slot).", .envOnly),
        s("RESTART_STAGGER_SECONDS", "Neustart", .int(min: 15, max: 300), "45", unit: "s",
          "Abstand zwischen den Replikaten beim kontrollierten Neustart.", .envOnly),
        s("DASH_ENABLED", "Dashboard", .bool, "false", "Dashboard-Listener einschalten.", .envOnly),
        s("DASH_PORT", "Dashboard", .int(min: 1, max: 65535), "9090", "Port des Dashboard-Listeners.", .envOnly),
        s("DASH_ORIGIN", "Dashboard", any, "", "Erlaubter Origin (WebAuthn, CSRF).", .envOnly),
        s("DASH_RP_ID", "Dashboard", any, "", "WebAuthn Relying-Party-ID.", .envOnly),
        s("DASH_SETUP_WINDOW_MINUTES", "Dashboard", .int(min: 1, max: 120), "15", unit: "min", "Zeitfenster der Ersteinrichtung.", .envOnly),
        s("DASH_SESSION_HOURS", "Dashboard", .int(min: 1, max: 72), "12", unit: "h", "Maximale Sitzungsdauer.", .envOnly),
        s("DASH_IDLE_MINUTES", "Dashboard", .int(min: 1, max: 240), "30", unit: "min", "Abmeldung bei Inaktivität.", .envOnly),
        s("DASH_PROXY_TOKEN", "Dashboard", .secret, "",
          "Geheimnis, das der Reverse Proxy als Header X-Dashboard-Proxy-Token setzt (Swarm-Secret per DASH_PROXY_TOKEN_FILE, mind. 32 Zeichen). Erzeugen: openssl rand -base64 32 | tr '+/' '-_' | tr -d '='.", .envOnly),
        s("DASH_PROXY_TOKEN_PREVIOUS", "Dashboard", .secret, "",
          "Vorheriges Proxy-Token, bei Rotation parallel gültig (DASH_PROXY_TOKEN_PREVIOUS_FILE).", .envOnly),
        s("DASH_PROXY_TOKEN_REQUIRED", "Dashboard", .bool, "true",
          "Ohne gültiges Proxy-Token startet das Dashboard nicht; nur false erlaubt den Start ohne (laute Warnung im Log).", .envOnly),
        s("MIGRATIONS_DIR", "Dienst", any, "migrations", "Verzeichnis der SQL-Migrationen.", .envOnly),
        s("BUILD_REVISION", "Dienst", any, "", "Commit des Images (nur Anzeige).", .envOnly),
        s("WMS_URL", "Quellen", any, "https://maps.dwd.de/geoserver/ows", "DWD-WMS (nur für Tests ändern).", .envOnly),
        s("EUMETSAT_WMS_URL", "Quellen", any, "https://view.eumetsat.int/geoserver/wms", "EUMETSAT-WMS (nur für Tests ändern).", .envOnly),
        s("APNS_KEY", "Push", .secret, "", "APNs-Schlüssel (.p8, Swarm-Secret), nur per Umgebung.", .envOnly),
        // Cache and ingest
        s("CACHE_MAX_MB", "Cache", .int(min: 8, max: 1024), "64", unit: "MB", "Größe des Bild-Caches im Speicher.", .restart),
        s("IMAGE_WIDTH", "Radar", .int(min: 256, max: 2048), "1024", unit: "px",
          "Breite des Radarbilds; mit Push fest 1024. Änderung entwertet das Bildraster.", .restart),
        s("LAYERS", "Ebenen", .layers, "", "Zusätzliche Ebenen (Komma-getrennt); Radar läuft immer. Braucht Migration 004.", .restart),
        s("RETENTION_RUNS", "Radar", .int(min: 15, max: 96), "16", "Aufbewahrte Radar-Läufe.", .live),
        s("HISTORY_HOURS", "Radar", .int(min: 1, max: 72), "48", unit: "h", "Stunden Radar-Historie (history.json).", .live),
        s("FETCH_WORKERS", "Radar", .int(min: 1, max: 6), "3", "Parallele Abrufe beim DWD.", .restart),
        s("AVAILABILITY_DELAY_SECONDS", "Radar", .number(min: 60, max: 900), "200", unit: "s",
          "Wartezeit nach dem Rasterzeitpunkt bis zum Abruf.", .restart),
        s("JITTER_SECONDS", "Radar", .number(min: 0, max: 120), "20", unit: "s", "Zufälliger Zusatz vor Abrufen.", .restart),
        s("REQUEST_TIMEOUT_SECONDS", "Radar", .number(min: 5, max: 120), "30", unit: "s", "Timeout je Abruf.", .restart),
        s("USER_AGENT", "Radar", .text(maxLength: 200, rule: .printableASCII), "ShowerNow-radar-ingest/1.0", "Wird an DWD und EUMETSAT gesendet.", .restart),
        s("PRESSURE_FORECAST_HOURS", "Ebenen", .int(min: 1, max: 168), "48", unit: "h", "Vorhersagestunden Luftdruck.", .live),
        s("PRESSURE_EU_FORECAST_HOURS", "Ebenen", .int(min: 1, max: 168), "24", unit: "h", "Vorhersagestunden Luftdruck Europa (Bild 4,3-fach größer).", .live),
        s("PRESSURE_RETENTION_RUNS", "Ebenen", .int(min: 2, max: 8), "2", "Aufbewahrte Luftdruck-Läufe.", .live),
        s("LIGHTNING_HISTORY_HOURS", "Ebenen", .int(min: 1, max: 24), "3", unit: "h", "Historie Blitze.", .live),
        s("CLOUDS_HISTORY_HOURS", "Ebenen", .int(min: 1, max: 24), "3", unit: "h", "Historie Wolken.", .live),
        s("CLOUDMASK_HISTORY_HOURS", "Ebenen", .int(min: 1, max: 24), "3", unit: "h", "Historie Wolkenmaske.", .live),
        s("CLOUDMASK_VIS_HISTORY_HOURS", "Ebenen", .int(min: 1, max: 24), "3", unit: "h", "Historie sichtbarer Kanal.", .live),
        s("CLOUDMASK_VIS_EU_HISTORY_HOURS", "Ebenen", .int(min: 1, max: 24), "3", unit: "h", "Historie sichtbarer Kanal Europa.", .live),
        s("LAYER_PAUSE_SECONDS", "Ebenen", .number(min: 1, max: 60), "2", unit: "s",
          "Pause zwischen zwei Abrufen einer Zusatzebene (Dashboard strenger als der Code, schont den DWD).", .live),
        // Public pages
        s("OPERATOR_NAME", "Betreiberseiten", any, "", "Name auf /datenschutz.", .live, mask: true),
        s("OPERATOR_ADDRESS", "Betreiberseiten", any, "", "Anschrift auf /datenschutz.", .live, mask: true),
        s("OPERATOR_EMAIL", "Betreiberseiten", any, "", "E-Mail auf /datenschutz.", .live, mask: true),
        s("PROXY_LOG_NOTE", "Betreiberseiten", any, "", "Satz zu Zugriffsprotokollen des Reverse Proxys.", .live, mask: true),
        s("APP_STORE_URL", "Betreiberseiten", .url(host: "apps.apple.com", maxLength: 500), "", "App-Store-Link auf /marketing.", .live),
        s("TESTFLIGHT_URL", "Betreiberseiten", .url(host: "testflight.apple.com", maxLength: 500), "", "TestFlight-Link auf /marketing.", .live),
        // Push
        s("PUSH_ENABLED", "Push", .bool, "false", "Server-Push einschalten (braucht APNs-Werte, Schlüssel und IMAGE_WIDTH=1024).", .restart),
        s("APNS_KEY_ID", "Push", .text(maxLength: 10, rule: .apnsIdentifier), "", "Key-ID des APNs-Schlüssels (10 Zeichen).", .restart),
        s("APNS_TEAM_ID", "Push", .text(maxLength: 10, rule: .apnsIdentifier), "", "Apple Team-ID (10 Zeichen).", .restart),
        s("APNS_TOPIC", "Push", .text(maxLength: 155, rule: .bundleIdentifier), "", "Bundle-ID der App.", .restart),
        s("APNS_ENV", "Push", .choice(["sandbox", "production", "both"]), "production", "Erlaubte APNs-Hosts.", .restart),
        s("PUSH_MAX_INSTALLATIONS", "Push-Grenzen", .int(min: 1, max: 1_000_000), "100000", "Obergrenze Installationen (503 server_full).", .live),
        s("PUSH_MAX_SUBSCRIPTIONS", "Push-Grenzen", .int(min: 1, max: 5_000_000), "400000", "Obergrenze Abos.", .live),
        s("PUSH_MAX_REGION_CELLS", "Push-Grenzen", .int(min: 1, max: 500_000_000), "50000000", "Obergrenze Regionszellen (etwa 1 s je 50 Mio. Zellen).", .live),
        s("PUSH_MAX_ACTIVITY_SUBSCRIPTIONS", "Push-Grenzen", .int(min: 1, max: 50_000), "5000", "Obergrenze Live-Activity-Abos.", .live),
        s("PUSH_MAX_REGIONS_PER_INSTALLATION", "Push-Grenzen", .int(min: 1, max: 10), "3", "Regionen je Installation.", .live),
        s("PUSH_MAX_CELLS_PER_INSTALLATION", "Push-Grenzen", .int(min: 500, max: 50_000), "8000", "Rasterzellen je Installation.", .live),
        s("PUSH_RATE_PER_INSTALLATION", "Push-Ratenlimits", .int(min: 10, max: 600), "60", unit: "pro Minute", "Anfragen je Installation.", .live),
        s("PUSH_RATE_GLOBAL_REGISTRATIONS", "Push-Ratenlimits", .int(min: 60, max: 6_000), "600", unit: "pro Minute", "Registrierungen je Replikat.", .live),
        s("PUSH_RATE_GLOBAL_REQUESTS", "Push-Ratenlimits", .int(min: 300, max: 30_000), "3000", unit: "pro Minute", "Alle Push-Anfragen je Replikat (Überlastschutz).", .live),
        s("PUSH_RATE_FAILED_AUTH", "Push-Ratenlimits", .int(min: 3, max: 60), "10", unit: "pro Minute", "Fehlgeschlagene Anmeldungen je Installation.", .live),
        s("PUSH_TEST_LIMIT_PER_HOUR", "Push-Ratenlimits", .int(min: 1, max: 10), "3", unit: "pro Stunde", "Testmeldungen je Installation.", .live),
        // Dashboard thresholds (insights findings; read per request from the live values, no field in `Config`)
        s("DASH_WARN_LAYER_AGE_FACTOR_YELLOW", "Dashboard-Schwellen", .number(min: 1, max: 100), "2", "Ebene veraltet, gelb: Alter als Vielfaches des Takts.", .live),
        s("DASH_WARN_LAYER_AGE_FACTOR_RED", "Dashboard-Schwellen", .number(min: 1, max: 100), "4", "Ebene veraltet, rot: Alter als Vielfaches des Takts.", .live),
        s("DASH_WARN_ERROR_RATE_5XX_YELLOW", "Dashboard-Schwellen", .number(min: 0, max: 1), "0.005", "5xx-Anteil der letzten Stunde, gelb.", .live),
        s("DASH_WARN_ERROR_RATE_5XX_RED", "Dashboard-Schwellen", .number(min: 0, max: 1), "0.02", "5xx-Anteil der letzten Stunde, rot.", .live),
        s("DASH_WARN_OUTBOX_AGE_SECONDS_YELLOW", "Dashboard-Schwellen", .number(min: 1, max: 86400), "120", unit: "s", "Ältester Outbox-Eintrag, gelb.", .live),
        s("DASH_WARN_OUTBOX_AGE_SECONDS_RED", "Dashboard-Schwellen", .number(min: 1, max: 86400), "600", unit: "s", "Ältester Outbox-Eintrag, rot.", .live),
        s("DASH_WARN_APNS_REJECTION_YELLOW", "Dashboard-Schwellen", .number(min: 0, max: 1), "0.05", "Anteil abgelehnter APNs-Sendungen, gelb.", .live),
        s("DASH_WARN_APNS_REJECTION_RED", "Dashboard-Schwellen", .number(min: 0, max: 1), "0.25", "Anteil abgelehnter APNs-Sendungen, rot.", .live),
        s("DASH_WARN_TOKEN_INVALIDATION_YELLOW", "Dashboard-Schwellen", .number(min: 0, max: 1), "0.05", "Anteil ungültig gewordener Token (24 h), gelb.", .live),
        s("DASH_WARN_TOKEN_INVALIDATION_RED", "Dashboard-Schwellen", .number(min: 0, max: 1), "0.2", "Anteil ungültig gewordener Token (24 h), rot.", .live),
        s("DASH_WARN_CACHE_HIT_YELLOW", "Dashboard-Schwellen", .number(min: 0, max: 1), "0.8", "Cache-Trefferquote, untere Grenze gelb.", .live),
        s("DASH_WARN_CACHE_HIT_RED", "Dashboard-Schwellen", .number(min: 0, max: 1), "0.5", "Cache-Trefferquote, untere Grenze rot.", .live),
        s("DASH_WARN_CAP_FILL_YELLOW", "Dashboard-Schwellen", .number(min: 0, max: 1), "0.8", "Füllgrad einer Obergrenze, gelb.", .live),
        s("DASH_WARN_CAP_FILL_RED", "Dashboard-Schwellen", .number(min: 0, max: 1), "0.95", "Füllgrad einer Obergrenze, rot.", .live),
        s("DASH_WARN_LA_START_RATIO_YELLOW", "Dashboard-Schwellen", .number(min: 0, max: 1), "0.7", "Anteil zugestellter Live-Activity-Starts, untere Grenze gelb.", .live),
        s("DASH_WARN_LA_START_RATIO_RED", "Dashboard-Schwellen", .number(min: 0, max: 1), "0.3", "Anteil zugestellter Live-Activity-Starts, untere Grenze rot.", .live),
        s("DASH_MIN_GROUP", "Dashboard-Schwellen", .int(min: 3, max: 50), "5", "k-Unterdrückung: Gruppen darunter erscheinen als „<k“.", .live),
        // Device link (read from the environment only; shown read-only)
        s("DEVICE_LINK_ENABLED", "Geräte-Kopplung", .bool, "false", "Geräte-Kopplung für TestFlight-Geräte einschalten (braucht Push).", .envOnly),
        s("DEVICE_LINK_BUNDLE_ID", "Geräte-Kopplung", .text(maxLength: 155, rule: .bundleIdentifier), "", "Bundle-ID der AppTransaction; leer = Basis von APNS_TOPIC.", .envOnly),
        s("DEVICE_LINK_ALLOWED_ENVS", "Geräte-Kopplung", any, "Sandbox", "Erlaubte receiptType-Werte (Sandbox, Xcode, LocalTesting; Production nie).", .envOnly),
        s("DEVICE_LINK_MAX_AGE_HOURS", "Geräte-Kopplung", .int(min: 0, max: 8760), "24", unit: "h", "Höchstalter des AppTransaction-Belegs.", .envOnly),
        s("DEVICE_LINK_REQUIRE_TESTFLIGHT", "Geräte-Kopplung", .bool, "false", "Zusätzlich den TestFlight-Nachweis (AppTransaction) für Koppelcodes verlangen.", .envOnly),
        s("DEVICE_LINK_WINDOW_MINUTES", "Geräte-Kopplung", .int(min: 1, max: 15), "5", unit: "min", "Standarddauer des Kopplungsfensters im Dashboard.", .envOnly),
        s("DASH_MAX_DEVICES", "Geräte-Kopplung", .int(min: 1, max: 5), "3", "Höchstzahl gekoppelter Geräte.", .envOnly),
        s("DASH_DEVICE_TTL_DAYS", "Geräte-Kopplung", .int(min: 0, max: 365), "0", unit: "Tage", "Ablauf einer Kopplung; 0 = kein Ablauf.", .envOnly),
        s("DASH_DEVICE_STALE_DAYS", "Geräte-Kopplung", .int(min: 1, max: 365), "14", unit: "Tage", "Anzeige „zuletzt gesehen“ als veraltet ab.", .envOnly),
    ]

    private static let index: [String: ConfigSetting] = Dictionary(settings.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })

    public static func setting(_ key: String) -> ConfigSetting? { index[key] }

    // MARK: Validation

    /// Checks `raw` against the dashboard limits of `key` and returns the canonical stored form.
    public static func validate(key: String, raw: String) throws -> String {
        guard let setting = index[key] else { throw ConfigWriteError.unknownKey }
        guard setting.editable else { throw ConfigWriteError.notEditable }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw ConfigWriteError.invalid("\(key): leerer Wert; zum Entfernen den Wert zurücksetzen") }
        return try normalize(setting, value)
    }

    /// `DASH_WARN_*` come in pairs (`..._YELLOW`/`..._RED`). Metrics that get worse upwards need yellow < red; the lower bounds
    /// (cache hit rate, live activity start ratio) need yellow > red. The partner's effective value is env, then stored, then default.
    static let fallingWarnBases: Set<String> = ["DASH_WARN_CACHE_HIT", "DASH_WARN_LA_START_RATIO"]

    static func checkWarnPair(key: String, env: [String: String], stored: [String: String]) throws {
        guard key.hasPrefix("DASH_WARN_") else { return }
        let isYellow = key.hasSuffix("_YELLOW")
        guard isYellow || key.hasSuffix("_RED") else { return }
        let base = String(key.dropLast(isYellow ? "_YELLOW".count : "_RED".count))
        func value(_ k: String) -> Double? {
            let raw = env[k].flatMap { $0.isEmpty ? nil : $0 } ?? stored[k] ?? index[k]?.defaultValue
            return raw.flatMap(Double.init)
        }
        guard let yellow = value(base + "_YELLOW"), let red = value(base + "_RED") else { return }
        let falling = fallingWarnBases.contains(base)
        guard falling ? yellow > red : yellow < red else {
            throw ConfigWriteError.invalid("\(key): Gelb muss \(falling ? "über" : "unter") Rot liegen (\(base)_YELLOW \(falling ? ">" : "<") \(base)_RED)")
        }
    }

    private static func normalize(_ setting: ConfigSetting, _ value: String) throws -> String {
        let key = setting.key
        func bad(_ text: String) -> ConfigWriteError { .invalid("\(key): \(text)") }
        switch setting.kind {
        case .int(let lo, let hi):
            guard let n = Int(value) else { throw bad("muss eine ganze Zahl sein") }
            guard (lo...hi).contains(n) else { throw bad("muss zwischen \(lo) und \(hi) liegen") }
            return String(n)
        case .number(let lo, let hi):
            guard let d = Double(value), d.isFinite else { throw bad("muss eine Zahl sein") }
            guard d >= lo, d <= hi else { throw bad("muss zwischen \(Int(lo)) und \(Int(hi)) liegen") }
            return d == d.rounded() ? String(Int(d)) : String(d)
        case .bool:
            switch value.lowercased() {
            case "true": return "true"
            case "false": return "false"
            default: throw bad("muss true oder false sein")
            }
        case .choice(let options):
            let v = value.lowercased()
            guard options.contains(v) else { throw bad("erlaubt: \(options.joined(separator: ", "))") }
            return v
        case .layers:
            do { return try LayerCatalog.parse(value).joined(separator: ",") } catch { throw bad("unbekannte Ebene") }
        case .text(let maxLength, let rule):
            guard value.count <= maxLength else { throw bad("höchstens \(maxLength) Zeichen") }
            guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" }) else {
                throw bad("Steuerzeichen nicht erlaubt")
            }
            switch rule {
            case .free: break
            case .printableASCII:
                guard value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) else { throw bad("nur druckbare ASCII-Zeichen") }
            case .apnsIdentifier:
                guard value.count == 10, value.unicodeScalars.allSatisfy({ ($0.value >= 65 && $0.value <= 90) || ($0.value >= 48 && $0.value <= 57) }) else {
                    throw bad("genau 10 Zeichen A bis Z und 0 bis 9")
                }
            case .bundleIdentifier:
                let parts = value.split(separator: ".", omittingEmptySubsequences: false)
                let ok = parts.count >= 2 && parts.allSatisfy { part in
                    !part.isEmpty && !part.hasPrefix("-") && !part.hasSuffix("-")
                        && part.unicodeScalars.allSatisfy { ($0.value < 128) && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
                }
                guard ok else { throw bad("ungültige Bundle-ID") }
            }
            return value
        case .url(let host, let maxLength):
            guard value.count <= maxLength, !value.contains(where: { $0.isWhitespace }),
                  let parts = URLComponents(string: value), parts.scheme == "https", parts.user == nil, parts.password == nil,
                  let urlHost = parts.host?.lowercased(), !urlHost.isEmpty, host == nil || urlHost == host else {
                throw bad("https-Adresse\(host.map { " auf \($0)" } ?? "") erwartet")
            }
            return value
        case .secret:
            throw ConfigWriteError.notEditable
        }
    }

    // MARK: Resolution

    /// The overrides that actually apply: unknown, secret, env-only, ENV-set and invalid ones are dropped (the latter with a
    /// warning), so a stale stored value can never abort the start (plan 5.1).
    public static func effectiveOverrides(env: [String: String], stored: [String: String], warn: (String) -> Void = { _ in }) -> [String: String] {
        var out: [String: String] = [:]
        for key in stored.keys.sorted() {
            guard let setting = index[key], setting.editable else { warn("config override \(key) ignored (not editable)"); continue }
            if let e = env[key], !e.isEmpty { continue }
            do { out[key] = try validate(key: key, raw: stored[key] ?? "") } catch { warn("config override \(key) ignored: \(error)") }
        }
        return out
    }

    /// Effective configuration: environment first (empty = unset), then the dashboard values, then defaults. An override that would
    /// break a cross-field rule (push needs key, IDs, topic and width 1024; retention at least 15) is dropped with a warning.
    public static func resolve(env: [String: String] = ProcessInfo.processInfo.environment, stored: [String: String],
                               warn: (String) -> Void = { _ in }) throws -> Config {
        var config = try Config.fromEnvironment(env)
        let valid = effectiveOverrides(env: env, stored: stored, warn: warn)
        for key in valid.keys.sorted() {
            do { config = try config.applying(overrides: [key: valid[key]!], env: env) } catch {
                warn("config override \(key) ignored: \(error)")
            }
        }
        return config
    }

    /// Validates a write against type, limits and cross-field rules given the other stored values; returns the canonical value.
    public static func validateWrite(key: String, raw: String, env: [String: String], stored: [String: String]) throws -> String {
        let value = try validate(key: key, raw: raw)
        if let e = env[key], !e.isEmpty { throw ConfigWriteError.lockedByEnv }
        var others = stored
        others[key] = value
        do {
            var config = try Config.fromEnvironment(env)
            let valid = effectiveOverrides(env: env, stored: others)
            for k in valid.keys.sorted() { config = try config.applying(overrides: [k: valid[k]!], env: env) }
            _ = config
        } catch let error as ConfigError {
            throw ConfigWriteError.invalid(error.description)
        }
        try checkWarnPair(key: key, env: env, stored: others)
        return value
    }

    // MARK: Read model

    /// Register rows for the dashboard. `startOverrides` are the dashboard values the process started with; keys of `restart`
    /// settings whose stored value differs are flagged `restartPending`.
    public static func entries(env: [String: String], stored: [String: String], startOverrides: [String: String]? = nil) -> [ConfigEntry] {
        let valid = effectiveOverrides(env: env, stored: stored)
        let start = startOverrides.map { effectiveOverrides(env: env, stored: $0) } ?? valid
        return settings.map { setting in
            let envRaw = env[setting.key].flatMap { $0.isEmpty ? nil : $0 }
            var entry = ConfigEntry(
                key: setting.key, group: setting.group, type: setting.kind.name, unit: setting.unit, summary: setting.summary,
                apply: setting.apply, secret: setting.secret, editable: setting.editable, source: .default, lockedByEnv: false,
                value: nil, defaultValue: nil, isSet: nil, minimum: nil, maximum: nil, maxLength: nil, choices: nil, restartPending: false)
            if setting.secret {
                let file = env["\(setting.key)_FILE"].map { !$0.isEmpty } ?? false
                entry.isSet = envRaw != nil || file
                entry.source = entry.isSet == true ? .env : .default
                entry.lockedByEnv = true
                return entry
            }
            entry.defaultValue = setting.defaultValue
            switch setting.kind {
            case .int(let lo, let hi): entry.minimum = Double(lo); entry.maximum = Double(hi)
            case .number(let lo, let hi): entry.minimum = lo; entry.maximum = hi
            case .text(let n, _), .url(_, let n): entry.maxLength = n
            case .choice(let options): entry.choices = options
            default: break
            }
            if let envRaw {
                entry.value = envRaw; entry.source = .env; entry.lockedByEnv = true
            } else if let stored = valid[setting.key] {
                entry.value = stored; entry.source = .dashboard
            } else {
                entry.value = setting.defaultValue
            }
            if setting.apply == .restart, envRaw == nil, valid[setting.key] != start[setting.key] { entry.restartPending = true }
            return entry
        }
    }

    /// Keys with a pending restart (for the banner and the confirmation dialog).
    public static func restartPendingKeys(env: [String: String], stored: [String: String], startOverrides: [String: String]) -> [String] {
        entries(env: env, stored: stored, startOverrides: startOverrides).filter(\.restartPending).map(\.key)
    }

    // MARK: Writing

    /// Sets (`raw != nil`) or resets (`raw == nil`) one dashboard value: validation, ENV lock, cross rules, then store (value and
    /// audit entry together, masked for public texts). Returns the new revision (nil: reset of a value that was not stored).
    @discardableResult
    public static func write(key: String, raw: String?, env: [String: String], store: any ConfigOverrideStore,
                             now: Date = Date()) async throws -> Int? {
        guard let setting = index[key] else { throw ConfigWriteError.unknownKey }
        guard setting.editable else { throw ConfigWriteError.notEditable }
        if let e = env[key], !e.isEmpty { throw ConfigWriteError.lockedByEnv }
        guard let raw else { return try await store.resetOverride(key: key, masked: setting.maskInAudit, now: now) }
        let stored = try await store.loadOverrides()
        let value = try validateWrite(key: key, raw: raw, env: env, stored: stored.values)
        return try await store.setOverride(key: key, value: value, masked: setting.maskInAudit, now: now)
    }
}

extension Config {
    /// Applies already validated dashboard values (raw strings by key) to a copy. Unknown, secret and env-only keys are rejected.
    /// `env` is only used to read the APNs key (Swarm secret) when the result enables push. Throws `ConfigError` if the result
    /// breaks a cross-field rule.
    public func applying(overrides: [String: String], env: [String: String] = ProcessInfo.processInfo.environment) throws -> Config {
        var c = self
        func int(_ key: String, _ raw: String) throws -> Int {
            guard let v = Int(raw) else { throw ConfigError(description: "\(key) must be an integer") }
            return v
        }
        func double(_ key: String, _ raw: String) throws -> Double {
            guard let v = Double(raw) else { throw ConfigError(description: "\(key) must be a number") }
            return v
        }
        for key in overrides.keys.sorted() {
            let raw = overrides[key]!
            guard let setting = ConfigRegistry.setting(key), setting.editable else {
                throw ConfigError(description: "\(key) is not a dashboard setting")
            }
            switch key {
            case "CACHE_MAX_MB": c.cacheMaxBytes = try int(key, raw) * 1_048_576
            case "IMAGE_WIDTH": c.width = try int(key, raw)
            case "LAYERS": c.layers = try LayerCatalog.parse(raw)
            case "RETENTION_RUNS": c.retentionRuns = try int(key, raw)
            case "HISTORY_HOURS": c.historyHours = try int(key, raw)
            case "FETCH_WORKERS": c.workers = try int(key, raw)
            case "AVAILABILITY_DELAY_SECONDS": c.availabilityDelaySeconds = try double(key, raw)
            case "JITTER_SECONDS": c.jitterSeconds = try double(key, raw)
            case "REQUEST_TIMEOUT_SECONDS": c.requestTimeoutSeconds = try double(key, raw)
            case "USER_AGENT": c.userAgent = raw
            case "PRESSURE_FORECAST_HOURS": c.pressureForecastHours = try int(key, raw)
            case "PRESSURE_EU_FORECAST_HOURS": c.pressureEUForecastHours = try int(key, raw)
            case "PRESSURE_RETENTION_RUNS": c.pressureRetentionRuns = try int(key, raw)
            case "LIGHTNING_HISTORY_HOURS": c.lightningHistoryHours = try int(key, raw)
            case "CLOUDS_HISTORY_HOURS": c.cloudsHistoryHours = try int(key, raw)
            case "CLOUDMASK_HISTORY_HOURS": c.cloudmaskHistoryHours = try int(key, raw)
            case "CLOUDMASK_VIS_HISTORY_HOURS": c.cloudmaskVisHistoryHours = try int(key, raw)
            case "CLOUDMASK_VIS_EU_HISTORY_HOURS": c.cloudmaskVisEUHistoryHours = try int(key, raw)
            case "LAYER_PAUSE_SECONDS": c.layerPauseSeconds = try double(key, raw)
            case "OPERATOR_NAME": c.site.operatorName = raw
            case "OPERATOR_ADDRESS": c.site.operatorAddress = raw
            case "OPERATOR_EMAIL": c.site.operatorEmail = raw
            case "PROXY_LOG_NOTE": c.site.proxyLogNote = raw
            case "APP_STORE_URL": c.site.appStoreURL = raw
            case "TESTFLIGHT_URL": c.site.testflightURL = raw
            case "PUSH_ENABLED": c.push.enabled = raw.lowercased() == "true"
            case "APNS_KEY_ID": c.push.keyID = raw
            case "APNS_TEAM_ID": c.push.teamID = raw
            case "APNS_TOPIC": c.push.topic = raw
            case "APNS_ENV":
                switch raw.lowercased() {
                case "sandbox": c.push.environments = [.sandbox]
                case "production": c.push.environments = [.production]
                case "both": c.push.environments = [.sandbox, .production]
                default: throw ConfigError(description: "APNS_ENV must be sandbox, production or both")
                }
            case "PUSH_MAX_INSTALLATIONS": c.push.maxInstallations = try int(key, raw)
            case "PUSH_MAX_SUBSCRIPTIONS": c.push.regionLimits.maxSubscriptionsServerwide = try int(key, raw)
            case "PUSH_MAX_REGION_CELLS": c.push.regionLimits.maxCellsServerwide = try int(key, raw)
            case "PUSH_MAX_ACTIVITY_SUBSCRIPTIONS": c.push.regionLimits.maxLiveActivitySubscriptions = try int(key, raw)
            case "PUSH_MAX_REGIONS_PER_INSTALLATION": c.push.regionLimits.maxRegionsPerInstallation = try int(key, raw)
            case "PUSH_MAX_CELLS_PER_INSTALLATION": c.push.regionLimits.maxCellsPerInstallation = try int(key, raw)
            case "PUSH_RATE_PER_INSTALLATION": c.push.rateLimits.perInstallation = try int(key, raw)
            case "PUSH_RATE_GLOBAL_REGISTRATIONS": c.push.rateLimits.globalRegistration = try int(key, raw)
            case "PUSH_RATE_GLOBAL_REQUESTS": c.push.rateLimits.globalRequest = try int(key, raw)
            case "PUSH_RATE_FAILED_AUTH": c.push.rateLimits.failedAuth = try int(key, raw)
            case "PUSH_TEST_LIMIT_PER_HOUR": c.push.rateLimits.testPerHour = try int(key, raw)
            case _ where key.hasPrefix("DASH_WARN_") || key == "DASH_MIN_GROUP":
                break  // validated by the register; read from the live values by the insights (`InsightsThresholds`)
            default: throw ConfigError(description: "\(key) has no dashboard mapping")
            }
        }
        if c.push.enabled, c.push.keyPEM.isEmpty {
            let environment = env.filter { !$0.value.isEmpty }
            c.push.keyPEM = try Config.secretValue(environment, "APNS_KEY")
        }
        return try c.validated()
    }

    static func secretValue(_ env: [String: String], _ name: String) throws -> String { try secret(env, name, "") }
}

/// Binds `ConfigOverrideStore` to the dashboard database (WP1). Value and audit entry are written by the repo in one transaction.
public struct DashboardConfigStore: ConfigOverrideStore {
    public let repo: any DashboardRepo
    public init(repo: any DashboardRepo) { self.repo = repo }

    public func loadOverrides() async throws -> StoredConfig {
        let state = try await repo.configState()
        return StoredConfig(values: Dictionary(state.overrides.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 }), revision: state.revision)
    }
    public func currentRevision() async throws -> Int { try await repo.configRevision() }
    public func setOverride(key: String, value: String, masked: Bool, now: Date) async throws -> Int {
        try await repo.setConfigOverride(key: key, value: value, audit: masked ? .masked : .values, now: now)
    }
    public func resetOverride(key: String, masked: Bool, now: Date) async throws -> Int? {
        try await repo.resetConfigOverride(key: key, audit: masked ? .masked : .values, now: now)
    }
}
