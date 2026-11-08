import Testing
@testable import RadarCore

struct ConfigCheckTests {
    @Test func emptyAndValidEnvironmentPass() {
        #expect(ConfigCheck.run(env: [:]).ok)
        let r = ConfigCheck.run(env: ["LAYERS": "radar,lightning,temperature", "DB_PASSWORD_FILE": "/run/secrets/missing"])
        #expect(r.ok && r.lines.contains { $0.contains("lightning,temperature_wms") })
    }

    @Test func internalOrUnknownLayerFails() {
        for bad in ["temperature_wms", "nope"] {
            let r = ConfigCheck.run(env: ["LAYERS": bad])
            #expect(!r.ok && r.lines.contains { $0.hasPrefix("error:") && $0.contains("LAYERS") })
        }
    }

    @Test func otherInvalidValuesFailAndPushNeedsNoKeyFile() {
        #expect(!ConfigCheck.run(env: ["FETCH_WORKERS": "99"]).ok)
        let push = ["PUSH_ENABLED": "true", "APNS_KEY_FILE": "/run/secrets/apns_key", "APNS_KEY_ID": "K", "APNS_TEAM_ID": "T", "APNS_TOPIC": "a.b", "APNS_ENV": "sandbox"]
        #expect(ConfigCheck.run(env: push).ok)
        #expect(!ConfigCheck.run(env: push.merging(["IMAGE_WIDTH": "512"]) { $1 }).ok)
    }
}
