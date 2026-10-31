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
        var body = try await response.body.collect(upTo: 8_000_000)
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

/// Loop of one additional layer (leader-only work inside `tick`); polls gently, never faster than every 2 minutes.
func runLayerLoop(spec: LayerSpec, config: Config, repo: any Repo, logger: Logger) async {
    let ingestor = LayerIngestor(spec: spec, config: config, repo: repo, fetch: httpFetch(config: config), owner: replicaID())
    let interval = spec.kind == .forecast ? 600.0 : max(120.0, spec.stepSeconds / 3)
    try? await Task.sleep(nanoseconds: UInt64((20 + Double.random(in: 0..<30)) * 1e9))
    var failures = 0
    while !Task.isCancelled {
        var pause = interval
        do {
            let r = try await ingestor.tick()
            if r.stored > 0 || r.failed > 0 { logger.info("layer \(spec.id): stored \(r.stored), failed \(r.failed)") }
            failures = r.failed > 0 && r.stored == 0 ? failures + 1 : 0
        } catch is CancellationError {
            break
        } catch {
            failures += 1
            logger.warning("layer \(spec.id) tick failed (\(type(of: error)))")
        }
        if failures > 2 { pause += Double(min(60 * (failures - 2), 600)) }
        var slept = 0.0
        while !Task.isCancelled, slept < pause { try? await Task.sleep(nanoseconds: 1_000_000_000); slept += 1 }
    }
    await ingestor.release()
}

/// HTTP/2 transport to APNs (AsyncHTTPClient negotiates h2 via ALPN). Not yet exercised against the real service.
struct AhcApnsTransport: ApnsTransport {
    let client: HTTPClient
    func perform(_ request: ApnsHTTPRequest) async throws -> ApnsHTTPResponse {
        var http = HTTPClientRequest(url: request.url)
        http.method = .POST
        for (name, value) in request.headers { http.headers.add(name: name, value: value) }
        http.body = .bytes(request.body)
        let response = try await client.execute(http, timeout: .seconds(15))
        var body = try await response.body.collect(upTo: 64 * 1024)
        return ApnsHTTPResponse(status: Int(response.status.code), body: body.readBytes(length: body.readableBytes) ?? [])
    }
}

/// Leader-only push loop: evaluation after each radar run, outbox delivery, retention. Idle when push is disabled.
func runPushLoop(config: Config, repo: any Repo, logger: Logger) async {
    guard config.push.enabled else { return }
    let client = HTTPClient(eventLoopGroupProvider: .singleton)
    let sender: any ApnsSender
    do {
        sender = try ApnsClient(keyPEM: config.push.keyPEM, keyID: config.push.keyID, teamID: config.push.teamID,
                                topic: config.push.topic, transport: AhcApnsTransport(client: client))
    } catch {
        logger.error("push disabled: APNs key not readable")
        try? await client.shutdown()
        return
    }
    let service = PushService(config: config, repo: repo, sender: sender, owner: replicaID())
    while !Task.isCancelled {
        do {
            let tick = try await service.tick()
            if tick.evaluatedRun != nil || tick.sent + tick.dropped + tick.retried + tick.unregistered > 0 || tick.purged.installations > 0 {
                logger.info("push: run \(tick.evaluatedRun ?? "-") queued \(tick.queued), sent \(tick.sent), retry \(tick.retried), dropped \(tick.dropped), removed \(tick.unregistered), purged \(tick.purged.installations)")
            }
        } catch is CancellationError {
            break
        } catch {
            logger.warning("push tick failed (\(type(of: error)))")
        }
        try? await Task.sleep(nanoseconds: 15_000_000_000)
    }
    await service.release()
    try? await client.shutdown()
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
    func respond(_ result: ApiResponse) -> Response {
        var headers = HTTPHeaders()
        for (name, value) in result.headers { headers.add(name: name, value: value) }
        return Response(status: HTTPResponseStatus(statusCode: result.status), headers: headers, body: .init(buffer: ByteBuffer(bytes: result.body)))
    }
    app.get("**") { req async -> Response in
        let path = req.url.path
        if path.hasPrefix(PushApi.prefix) {
            return respond(await api.handlePush(method: "GET", path: path, secret: req.headers.first(name: "X-Installation-Secret"), body: []))
        }
        do {
            return respond(try await api.handle(path: path, ifNoneMatch: req.headers.first(name: .ifNoneMatch)))
        } catch {
            return Response(status: .serviceUnavailable, headers: ["Cache-Control": "no-store"])
        }
    }
    // Push registration (small JSON bodies); answers 404 unless PUSH_ENABLED=true.
    for method in [HTTPMethod.POST, .PUT, .DELETE] {
        app.on(method, "**", body: .collect(maxSize: "4kb")) { req async -> Response in
            var buffer = req.body.data ?? ByteBuffer()
            return respond(await api.handlePush(method: method.rawValue, path: req.url.path,
                                                secret: req.headers.first(name: "X-Installation-Secret"),
                                                body: buffer.readBytes(length: buffer.readableBytes) ?? []))
        }
    }

    let logger = app.logger
    try await repo.ping()
    let activity = ActivityFlag()
    let loop = Task { await runIngestLoop(config: config, repo: repo, heartbeat: heartbeat, activity: activity, logger: logger) }
    let backfill = Task { await runBackfillLoop(config: config, repo: repo, activity: activity, logger: logger) }
    let pushLoop = Task { await runPushLoop(config: config, repo: repo, logger: logger) }
    let layerLoops = config.layers.compactMap { id in
        LayerCatalog.specs[id].map { spec in Task { await runLayerLoop(spec: spec, config: config, repo: repo, logger: logger) } }
    }
    do {
        try await app.execute()
    } catch {
        loop.cancel(); backfill.cancel(); pushLoop.cancel(); layerLoops.forEach { $0.cancel() }
        for t in layerLoops { await t.value }
        await loop.value; await backfill.value; await pushLoop.value
        try? await app.asyncShutdown()
        await repo.shutdown()
        throw error
    }
    loop.cancel(); backfill.cancel(); pushLoop.cancel(); layerLoops.forEach { $0.cancel() }
    for t in layerLoops { await t.value }
    await backfill.value
    await pushLoop.value
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
