import Foundation
import Testing
@testable import RadarCore

@Suite struct ConfigRegistryTests {
    @Test func emptyEnvironmentValueCountsAsUnset() throws {
        let c = try Config.fromEnvironment(["CACHE_MAX_MB": "", "DB_POOL_SIZE": "", "RETENTION_RUNS": "", "PUSH_ENABLED": "", "LAYERS": "",
                                            "USER_AGENT": "", "APNS_ENV": "", "OPERATOR_NAME": ""])
        #expect(c.cacheMaxBytes == 64 * 1024 * 1024)
        #expect(c.dbPoolSize == 4)
        #expect(c.retentionRuns == 16)
        #expect(c.userAgent == Config().userAgent)
        #expect(c.layers.isEmpty)
        // Not an empty-string error any more, but non-empty garbage still fails as before.
        #expect(throws: ConfigError.self) { try Config.fromEnvironment(["DB_POOL_SIZE": "x"]) }
    }

    @Test func precedenceEnvThenDashboardThenDefault() throws {
        let stored = ["HISTORY_HOURS": "24", "JITTER_SECONDS": "10", "FETCH_WORKERS": "2"]
        let c = try ConfigRegistry.resolve(env: ["HISTORY_HOURS": "12"], stored: stored)
        #expect(c.historyHours == 12)          // ENV wins
        #expect(c.jitterSeconds == 10)         // dashboard beats default
        #expect(c.workers == 2)
        #expect(c.retentionRuns == 16)         // default
        // Empty ENV does not lock the key.
        let d = try ConfigRegistry.resolve(env: ["HISTORY_HOURS": ""], stored: stored)
        #expect(d.historyHours == 24)
        let entries = ConfigRegistry.entries(env: ["HISTORY_HOURS": "12"], stored: stored)
        let hist = try #require(entries.first { $0.key == "HISTORY_HOURS" })
        #expect(hist.source == .env && hist.lockedByEnv && hist.value == "12")
        let jitter = try #require(entries.first { $0.key == "JITTER_SECONDS" })
        #expect(jitter.source == .dashboard && !jitter.lockedByEnv && jitter.value == "10")
        let retention = try #require(entries.first { $0.key == "RETENTION_RUNS" })
        #expect(retention.source == .default && retention.value == "16")
    }

    @Test func invalidStoredValueFallsBackToDefaultWithWarning() throws {
        var warnings: [String] = []
        let c = try ConfigRegistry.resolve(env: [:], stored: ["RETENTION_RUNS": "5", "HISTORY_HOURS": "abc", "UNKNOWN_KEY": "1",
                                                              "DB_HOST": "evil", "WMS_URL": "https://evil.example", "JITTER_SECONDS": "30"]) {
            warnings.append($0)
        }
        #expect(c.retentionRuns == 16 && c.historyHours == 48)
        #expect(c.dbHost == "127.0.0.1" && c.wmsURL == Config().wmsURL)
        #expect(c.jitterSeconds == 30)
        #expect(warnings.count == 5)
    }

    @Test func limitsAreEnforcedOnWrite() throws {
        func rejects(_ key: String, _ raw: String) {
            #expect(throws: ConfigWriteError.self, "\(key)=\(raw)") { try ConfigRegistry.validate(key: key, raw: raw) }
        }
        rejects("RETENTION_RUNS", "14"); rejects("RETENTION_RUNS", "97")
        rejects("CACHE_MAX_MB", "7"); rejects("CACHE_MAX_MB", "1025")
        rejects("PUSH_MAX_REGION_CELLS", "0"); rejects("PUSH_MAX_REGION_CELLS", "500000001")
        rejects("PUSH_MAX_INSTALLATIONS", "1000001")
        rejects("LAYER_PAUSE_SECONDS", "0"); rejects("LAYER_PAUSE_SECONDS", "61"); rejects("LAYER_PAUSE_SECONDS", "nan")
        rejects("AVAILABILITY_DELAY_SECONDS", "59"); rejects("REQUEST_TIMEOUT_SECONDS", "4"); rejects("JITTER_SECONDS", "121")
        rejects("HISTORY_HOURS", "73"); rejects("FETCH_WORKERS", "7"); rejects("IMAGE_WIDTH", "4096")
        rejects("LAYERS", "pressure,bogus"); rejects("APNS_ENV", "everything"); rejects("PUSH_ENABLED", "yes")
        rejects("USER_AGENT", "caf\u{e9}"); rejects("USER_AGENT", String(repeating: "a", count: 201))
        rejects("OPERATOR_NAME", String(repeating: "a", count: 501)); rejects("OPERATOR_NAME", "   ")
        rejects("APP_STORE_URL", "javascript:alert(1)"); rejects("APP_STORE_URL", "http://apps.apple.com/x")
        rejects("APP_STORE_URL", "https://evil.example/apps.apple.com"); rejects("TESTFLIGHT_URL", "https://apps.apple.com/x")
        rejects("APNS_KEY_ID", "short"); rejects("APNS_TEAM_ID", "abcdefghij"); rejects("APNS_TOPIC", "nodots"); rejects("APNS_TOPIC", "a..b")
        #expect(try ConfigRegistry.validate(key: "RETENTION_RUNS", raw: " 20 ") == "20")
        #expect(try ConfigRegistry.validate(key: "LAYER_PAUSE_SECONDS", raw: "2.0") == "2")
        #expect(try ConfigRegistry.validate(key: "LAYERS", raw: "Lightning clouds") == "lightning,clouds")
        #expect(try ConfigRegistry.validate(key: "APP_STORE_URL", raw: "https://apps.apple.com/app/id1") == "https://apps.apple.com/app/id1")
        #expect(try ConfigRegistry.validate(key: "APNS_TOPIC", raw: "de.linolaske.showernow") == "de.linolaske.showernow")
    }

    @Test func secretsAndEnvOnlyKeysAreNotWritable() async throws {
        let store = MemoryConfigOverrideStore()
        for key in ["DB_PASSWORD", "APNS_KEY", "DB_HOST", "WMS_URL", "HTTP_PORT", "DASH_ORIGIN", "REPLICA_SLOT"] {
            await #expect(throws: ConfigWriteError.notEditable, "\(key)") { try await ConfigRegistry.write(key: key, raw: "x", env: [:], store: store) }
        }
        await #expect(throws: ConfigWriteError.unknownKey) { try await ConfigRegistry.write(key: "NOPE", raw: "1", env: [:], store: store) }
        #expect(await store.loadOverrides().revision == 0)
    }

    @Test func writeRespectsEnvLockAndAuditsMasked() async throws {
        let store = MemoryConfigOverrideStore()
        await #expect(throws: ConfigWriteError.lockedByEnv) {
            try await ConfigRegistry.write(key: "HISTORY_HOURS", raw: "10", env: ["HISTORY_HOURS": "48"], store: store)
        }
        // Empty ENV does not lock.
        let rev = try await ConfigRegistry.write(key: "HISTORY_HOURS", raw: "10", env: ["HISTORY_HOURS": ""], store: store)
        #expect(rev == 1)
        _ = try await ConfigRegistry.write(key: "OPERATOR_NAME", raw: "Max Mustermann", env: [:], store: store)
        let audit = await store.audit
        #expect(audit.map(\.key) == ["HISTORY_HOURS", "OPERATOR_NAME"])
        #expect(audit.map(\.masked) == [false, true])
        #expect(try await ConfigRegistry.write(key: "HISTORY_HOURS", raw: nil, env: [:], store: store) == 3)
        #expect(try await ConfigRegistry.write(key: "HISTORY_HOURS", raw: nil, env: [:], store: store) == nil)
        #expect(await store.loadOverrides().values == ["OPERATOR_NAME": "Max Mustermann"])
        await #expect(throws: ConfigWriteError.self) { try await ConfigRegistry.write(key: "RETENTION_RUNS", raw: "3", env: [:], store: store) }
    }

    @Test func crossRulesForPush() async throws {
        let store = MemoryConfigOverrideStore()
        // Push without key and identity values is refused.
        await #expect(throws: ConfigWriteError.self) { try await ConfigRegistry.write(key: "PUSH_ENABLED", raw: "true", env: [:], store: store) }
        let env = ["APNS_KEY": "-----BEGIN PRIVATE KEY-----x", "APNS_KEY_ID": "ABCDE12345", "APNS_TEAM_ID": "ABCDE12345", "APNS_TOPIC": "de.example.app"]
        _ = try await ConfigRegistry.write(key: "PUSH_ENABLED", raw: "true", env: env, store: store)
        // With push enabled the width must stay 1024.
        await #expect(throws: ConfigWriteError.self) { try await ConfigRegistry.write(key: "IMAGE_WIDTH", raw: "2048", env: env, store: store) }
        let c = try ConfigRegistry.resolve(env: env, stored: await store.loadOverrides().values)
        #expect(c.push.enabled && c.push.keyPEM == "-----BEGIN PRIVATE KEY-----x" && c.push.topic == "de.example.app")
        // A stored combination that is no longer valid is dropped at start instead of aborting.
        var warned = false
        let degraded = try ConfigRegistry.resolve(env: [:], stored: ["PUSH_ENABLED": "true"]) { _ in warned = true }
        #expect(!degraded.push.enabled && warned)
    }

    @Test func applyingOverridesToSnapshot() throws {
        let base = try Config.fromEnvironment([:])
        let c = try base.applying(overrides: ["PUSH_MAX_INSTALLATIONS": "7", "PUSH_MAX_ACTIVITY_SUBSCRIPTIONS": "9", "CACHE_MAX_MB": "10", "OPERATOR_NAME": "N",
                                              "LAYERS": "lightning", "APNS_ENV": "both"])
        #expect(c.push.maxInstallations == 7 && c.push.regionLimits.maxLiveActivitySubscriptions == 9)
        #expect(c.cacheMaxBytes == 10 * 1_048_576 && c.site.operatorName == "N" && c.layers == ["lightning"])
        #expect(c.push.environments == [.sandbox, .production])
        #expect(base.push.maxInstallations == 100_000)
        #expect(throws: ConfigError.self) { try base.applying(overrides: ["DB_HOST": "x"]) }
    }

    @Test func outputModelNeverContainsSecrets() throws {
        let secrets = ["S3CR3T-DB-PASSWORD", "TOP-SECRET-APNS-PEM"]
        let env = ["DB_PASSWORD": secrets[0], "APNS_KEY": secrets[1], "DB_PASSWORD_FILE": "/run/secrets/x", "HISTORY_HOURS": "12"]
        let entries = ConfigRegistry.entries(env: env, stored: [:])
        let json = String(decoding: try JSONEncoder().encode(entries), as: UTF8.self)
        for secret in secrets { #expect(!json.contains(secret)) }
        let pw = try #require(entries.first { $0.key == "DB_PASSWORD" })
        #expect(pw.secret && pw.value == nil && pw.defaultValue == nil && pw.isSet == true && !pw.editable)
        let key = try #require(entries.first { $0.key == "APNS_KEY" })
        #expect(key.isSet == true && key.value == nil)
        let unset = ConfigRegistry.entries(env: [:], stored: [:]).first { $0.key == "DB_PASSWORD" }
        #expect(unset?.isSet == false)
        // The register itself holds no secret default and every secret key is env only.
        for s in ConfigRegistry.settings where s.secret { #expect(s.defaultValue.isEmpty && s.envOnly) }
    }

    @Test func registryCoversEveryEditableConfigKey() throws {
        // Every editable key must be mapped by applying(), and its default must pass its own validation.
        for setting in ConfigRegistry.settings where setting.editable {
            if !setting.defaultValue.isEmpty {
                #expect(try ConfigRegistry.validate(key: setting.key, raw: setting.defaultValue) != "", "\(setting.key)")
                _ = try Config().applying(overrides: [setting.key: setting.defaultValue])
            }
        }
        let keys = ConfigRegistry.settings.map(\.key)
        #expect(Set(keys).count == keys.count)
        // Defaults in the register equal the defaults in Config.
        let d = Config()
        #expect(ConfigRegistry.setting("CACHE_MAX_MB")?.defaultValue == String(d.cacheMaxBytes / 1_048_576))
        #expect(ConfigRegistry.setting("RETENTION_RUNS")?.defaultValue == String(d.retentionRuns))
        #expect(ConfigRegistry.setting("HISTORY_HOURS")?.defaultValue == String(d.historyHours))
        #expect(ConfigRegistry.setting("PUSH_MAX_REGION_CELLS")?.defaultValue == String(d.push.regionLimits.maxCellsServerwide))
        #expect(ConfigRegistry.setting("USER_AGENT")?.defaultValue == d.userAgent)
        #expect(ConfigRegistry.setting("AVAILABILITY_DELAY_SECONDS")?.defaultValue == "200")
    }

    @Test func restartPendingOnlyForChangedRestartKeys() {
        let start = ["FETCH_WORKERS": "3"]
        let stored = ["FETCH_WORKERS": "2", "HISTORY_HOURS": "10"]
        let keys = ConfigRegistry.restartPendingKeys(env: [:], stored: stored, startOverrides: start)
        #expect(keys == ["FETCH_WORKERS"])   // HISTORY_HOURS is live
        #expect(ConfigRegistry.restartPendingKeys(env: [:], stored: stored, startOverrides: stored).isEmpty)
        #expect(ConfigRegistry.restartPendingKeys(env: ["FETCH_WORKERS": "5"], stored: stored, startOverrides: start).isEmpty)
    }
}

@Suite struct DashboardAdapterTests {
    @Test func configStoreOnMemoryRepo() async throws {
        let repo = MemoryRepo()
        let store = DashboardConfigStore(repo: repo)
        let rev = try await ConfigRegistry.write(key: "HISTORY_HOURS", raw: "10", env: [:], store: store)
        #expect(rev == 1)
        _ = try await ConfigRegistry.write(key: "OPERATOR_NAME", raw: "Max", env: [:], store: store)
        let stored = try await store.loadOverrides()
        #expect(stored.values == ["HISTORY_HOURS": "10", "OPERATOR_NAME": "Max"] && stored.revision == 2)
        // Operator texts are masked in the audit log, numbers are not.
        let audit = try await repo.auditEntries(limit: 10)
        #expect(!audit.contains { $0.newValue == "Max" || $0.oldValue == "Max" })
        #expect(audit.contains { $0.key == "HISTORY_HOURS" && $0.newValue == "10" })
        #expect(try await ConfigRegistry.write(key: "HISTORY_HOURS", raw: nil, env: [:], store: store) == 3)
        #expect(try await store.currentRevision() == 3)
    }

    @Test func coordinatorOnMemoryRepoRestartsOnce() async throws {
        let repo = MemoryRepo()
        nonisolated(unsafe) var exited = false
        let c = try await RestartCoordinator.make(repo: repo, replicaID: "a", slot: 1, isLeader: { true }, leaderSlot: { 1 },
                                                  shutdown: { exited = true })
        #expect(await c.tick() == .none)
        #expect(try await repo.requestRestart(minInterval: 300, now: Date()) == 1)
        #expect(try await repo.requestRestart(minInterval: 300, now: Date()) == nil)   // minimum interval
        #expect(await c.tick() == .exit && exited)
        // The new process starts with the current generation and stays quiet.
        let again = try await RestartCoordinator.make(repo: repo, replicaID: "a", slot: 1, isLeader: { true }, leaderSlot: { 1 }, shutdown: {})
        #expect(await again.tick() == .none)
        #expect(try await repo.replicas(now: Date()).first?.appliedGeneration == 1)
    }

    @Test func unreadableSecretFileGivesAClearError() throws {
        let missing = "/nonexistent-\(UUID().uuidString)/apns_key"
        do {
            _ = try Config.fromEnvironment(["PUSH_ENABLED": "true", "APNS_KEY_ID": "ABCDE12345", "APNS_TEAM_ID": "ZYXWV98765",
                                            "APNS_TOPIC": "de.example.app", "APNS_KEY_FILE": missing])
            Issue.record("expected a ConfigError")
        } catch let error as ConfigError {
            #expect(error.description == "APNS_KEY_FILE nicht lesbar: Secret apns_key gemountet? (stack.yaml hängt es immer ein)")
            #expect(!error.description.contains(missing))
        }
        do {
            _ = try Config.fromEnvironment(["DB_PASSWORD_FILE": missing])
            Issue.record("expected a ConfigError")
        } catch let error as ConfigError {
            #expect(error.description.hasPrefix("DB_PASSWORD_FILE nicht lesbar"))
        }
    }
}
