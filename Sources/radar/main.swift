import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import NIOFoundationCompat
import RadarCore
import Vapor

/// Liveness marker: the ingest loop touches it regularly; /healthz turns 503 when the loop stalls (15 minutes).
final class Heartbeat: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()
    func beat() { lock.lock(); last = Date(); lock.unlock() }
    var isAlive: Bool { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(last) < 900 }
}

func replicaID() -> String {
    let host = String(ProcessInfo.processInfo.hostName.prefix(40))
    return "\(host)-\(UUID().uuidString.prefix(8).lowercased())"
}

func httpFetch(config: Config) -> Fetch {
    let userAgent = config.userAgent
    let timeout = config.requestTimeoutSeconds
    return { url in
        var request = HTTPClientRequest(url: url)
        request.headers.add(name: "User-Agent", value: userAgent)
        let response = try await HTTPClient.shared.execute(request, timeout: .seconds(Int64(timeout)))
        var body = try await response.body.collect(upTo: 4_000_000)
        return body.readBytes(length: body.readableBytes) ?? []
    }
}

func runIngestLoop(config: Config, repo: any Repo, heartbeat: Heartbeat, activity: ActivityFlag, logger: Logger) async {
    let ingestor = Ingestor(config: config, repo: repo, fetch: httpFetch(config: config), owner: replicaID())
    var failures = 0
    while !Task.isCancelled {
        heartbeat.beat()
        let run = TimeUtil.latestRun(now: Date(), availabilityDelay: config.availabilityDelaySeconds)
        activity.set(true)
        do {
            if try await ingestor.process(run: run) { logger.info("published run \(TimeUtil.toID(run))") }
            failures = 0
        } catch is CancellationError {
            return
        } catch {
            failures += 1
            logger.warning("run \(TimeUtil.toID(run)) not published (\(type(of: error))); consecutive failures: \(failures)")
        }
        activity.set(false)
        var wake = TimeUtil.nextWakeup(now: Date(), availabilityDelay: config.availabilityDelaySeconds)
            .addingTimeInterval(Double.random(in: 0..<max(config.jitterSeconds, 0.001)))
        if failures > 2 { wake = wake.addingTimeInterval(Double(min(60 * (failures - 2), 600))) }  // capped at 10 minutes
        while !Task.isCancelled, Date() < wake {
            heartbeat.beat()
            try? await Task.sleep(nanoseconds: UInt64(min(30, max(0.5, wake.timeIntervalSinceNow)) * 1e9))
        }
    }
}

/// Low-priority history backfill (leader only); starts after the first regular run and pauses while that one works.
func runBackfillLoop(config: Config, repo: any Repo, activity: ActivityFlag, logger: Logger) async {
    let backfiller = Backfiller(config: config, repo: repo, fetch: httpFetch(config: config), owner: replicaID(),
                                isBusy: { activity.isBusy })
    try? await Task.sleep(nanoseconds: UInt64((45 + Double.random(in: 0..<15)) * 1e9))
    var lastRemaining = -1
    while !Task.isCancelled {
        var pause = 60.0
        do {
            let result = try await backfiller.tick()
            if result.isLeader && (result.stored > 0 || result.failed > 0 || result.remaining != lastRemaining) {
                logger.info("history backfill: stored \(result.stored), failed \(result.failed), missing \(result.remaining)")
            }
            lastRemaining = result.remaining
            if result.errorPause { pause = 300; logger.warning("history backfill paused after consecutive failures") }
            else if result.isLeader && result.remaining > 0 { pause = 10 }
        } catch is CancellationError {
            break
        } catch {
            logger.warning("history backfill tick failed (\(type(of: error)))")
            pause = 120
        }
        var slept = 0.0
        while !Task.isCancelled, slept < pause { try? await Task.sleep(nanoseconds: 1_000_000_000); slept += 1 }
    }
    await backfiller.release()
}

func serve(config: Config) async throws {
    var env = Environment(name: "production", arguments: ["radar", "serve", "--hostname", "0.0.0.0", "--port", String(config.httpPort)])
    try LoggingSystem.bootstrap(from: &env)
    let app = try await Application.make(env)
    let repo = MariaRepo(config: config)
    let heartbeat = Heartbeat()
    let api = Api(repo: repo, config: config, alive: { heartbeat.isAlive })
    app.http.server.configuration.serverName = nil

    // No access logs (no IPs, no paths). Database errors never leak details to clients.
    app.get("**") { req async -> Response in
        let path = req.url.path
        do {
            let result = try await api.handle(path: path, ifNoneMatch: req.headers.first(name: .ifNoneMatch))
            var headers = HTTPHeaders()
            for (name, value) in result.headers { headers.add(name: name, value: value) }
            return Response(status: HTTPResponseStatus(statusCode: result.status), headers: headers,
                            body: .init(buffer: ByteBuffer(bytes: result.body)))
        } catch {
            return Response(status: .serviceUnavailable, headers: ["Cache-Control": "no-store"])
        }
    }

    let logger = app.logger
    try await repo.ping()
    let activity = ActivityFlag()
    let loop = Task { await runIngestLoop(config: config, repo: repo, heartbeat: heartbeat, activity: activity, logger: logger) }
    let backfill = Task { await runBackfillLoop(config: config, repo: repo, activity: activity, logger: logger) }
    do {
        try await app.execute()
    } catch {
        loop.cancel(); backfill.cancel()
        await loop.value; await backfill.value
        try? await app.asyncShutdown()
        await repo.shutdown()
        throw error
    }
    loop.cancel(); backfill.cancel()
    await backfill.value
    await loop.value  // let a running ingest hand its run over before the DB pool goes away
    try await app.asyncShutdown()
    await repo.shutdown()
    logger.info("stopped")
}

func migrate(config: Config) async throws {
    let repo = MariaRepo(config: config)
    do { try await repo.migrate() } catch { await repo.shutdown(); throw error }
    await repo.shutdown()
    print("migrations applied")
}

@main
struct Radar {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.first ?? "serve"
        do {
            let config = try Config.fromEnvironment()
            switch command {
            case "serve":
                try await serve(config: config)
            case "migrate":
                guard arguments.contains("--yes") else {
                    FileHandle.standardError.write(Data("migrate changes the database schema: pass --yes to confirm\n".utf8))
                    exit(64)
                }
                try await migrate(config: config)
            default:
                FileHandle.standardError.write(Data("usage: radar [serve | migrate --yes]\n".utf8))
                exit(64)
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }
}
