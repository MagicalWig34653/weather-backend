import Foundation
import Testing
import XCTVapor
@testable import RadarCore
@testable import radar

@Suite("Public listener routing (real HTTP through Vapor)")
struct PublicRoutesTests {
    private func withApp(_ body: (Application) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        let stats = StatsCollector()
        app.middleware.use(StatsMiddleware(stats: stats))
        registerPublicRoutes(app, api: Api(repo: MemoryRepo(), config: smallConfig()))
        do { try await body(app) } catch { try? await app.asyncShutdown(); throw error }
        try await app.asyncShutdown()
    }

    @Test func rootServesGermanLanding() async throws {
        try await withApp { app in
            try await app.test(.GET, "/") { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: "Content-Language") == "de")
                #expect(res.headers.first(name: .contentType)?.hasPrefix("text/html") == true)
                #expect(res.body.string.contains("<html"))
            }
            try await app.test(.HEAD, "/") { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: "Content-Language") == "de")
            }
            try await app.test(.GET, "/en") { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: "Content-Language") == "en")
            }
            try await app.test(.HEAD, "/en") { res async in #expect(res.status == .ok) }
            for p in ["/datenschutz", "/support", "/impressum", "/marketing", "/healthz"] {
                try await app.test(.GET, p) { res async in #expect(res.status == .ok, "\(p)") }
            }
        }
    }
}
