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

func runIngestLoop(config: Config, provider: ConfigProvider, stats: any StatsSink, repo: any Repo, heartbeat: Heartbeat, activity: ActivityFlag, logger: Logger) async {
    let ingestor = Ingestor(configProvider: provider, repo: repo, fetch: httpFetch(config: config), owner: replicaID(), stats: stats)
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
func runBackfillLoop(config: Config, provider: ConfigProvider, repo: any Repo, activity: ActivityFlag, logger: Logger) async {
    let backfiller = Backfiller(configProvider: provider, repo: repo, fetch: httpFetch(config: config), owner: replicaID(),
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
func runLayerLoop(spec: LayerSpec, config: Config, provider: ConfigProvider, stats: any StatsSink, repo: any Repo, logger: Logger) async {
    let ingestor = LayerIngestor(spec: spec, configProvider: provider, repo: repo, fetch: httpFetch(config: config), owner: replicaID(), stats: stats)
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
func makeApnsSender(config: Config, client: HTTPClient, logger: Logger) -> (any ApnsSender)? {
    guard config.push.enabled else { return nil }
    do {
        let sender = try ApnsClient(keyPEM: config.push.keyPEM, keyID: config.push.keyID, teamID: config.push.teamID,
                                    topic: config.push.topic, transport: AhcApnsTransport(client: client))
        let envs = config.push.environments.map(\.rawValue).sorted().joined(separator: ",")
        logger.info("push: APNs environments allowed: \(envs); the key must be valid for each of them (otherwise APNs answers BadDeviceToken/InvalidProviderToken)")
        return sender
    } catch {
        logger.error("push disabled: APNs key not readable")
        return nil
    }
}

func runPushLoop(config: Config, stats: any StatsSink, repo: any Repo, sender: (any ApnsSender)?, logger: Logger) async {
    guard config.push.enabled, let sender else { return }
    let service = PushService(config: config, repo: repo, sender: sender, owner: replicaID(), stats: stats)
    // Dashboard commands of linked devices (leader only, queue polled about every 2 seconds).
    let commands = Task {
        while !Task.isCancelled {
            await service.processCommands()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
    defer { commands.cancel() }
    while !Task.isCancelled {
        do {
            let tick = try await service.tick()
            if tick.evaluatedRun != nil || tick.sent + tick.dropped + tick.retried + tick.unregistered > 0 || tick.purged.installations > 0 {
                logger.info("push: run \(tick.evaluatedRun ?? "-") queued \(tick.queued), sent \(tick.sent), retry \(tick.retried), dropped \(tick.dropped), removed \(tick.unregistered), purged \(tick.purged.installations)\(tick.apnsReasons.isEmpty ? "" : ", apns reasons \(tick.apnsReasons.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))")")
            }
        } catch is CancellationError {
            break
        } catch {
            logger.warning("push tick failed (\(type(of: error)))")
        }
        try? await Task.sleep(nanoseconds: 15_000_000_000)
    }
    await service.release()
}

/// Statistics for every finished request (route group and status class only; the path is classified, never stored).
struct StatsMiddleware: AsyncMiddleware {
    let stats: StatsCollector

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do {
            let response = try await next.respond(to: request)
            stats.recordRequest(path: request.url.path, status: Int(response.status.code), bytes: max(0, response.body.count))
            return response
        } catch {
            let status = (error as? any AbortError)?.status.code ?? 500
            stats.recordRequest(path: request.url.path, status: Int(status), bytes: 0)
            throw error
        }
    }
}

/// No access logs (no IPs, no paths). Database errors never leak details to clients.
func vaporResponse(_ result: ApiResponse) -> Response {
    var headers = HTTPHeaders()
    for (name, value) in result.headers { headers.add(name: name, value: value) }
    return Response(status: HTTPResponseStatus(statusCode: result.status), headers: headers, body: .init(buffer: ByteBuffer(bytes: result.body)))
}

func makeEnvironment(port: Int) -> Environment {
    Environment(name: "production", arguments: ["radar", "serve", "--hostname", "0.0.0.0", "--port", String(port)])
}

/// Dashboard auth configuration, fail closed: `DASH_ORIGIN` is required (plan 2.1); origin and RP ID only ever come from the environment.
func dashboardAuthConfig() throws -> DashboardAuthConfig {
    guard let config = DashboardAuthConfig.fromEnvironment(ProcessInfo.processInfo.environment) else {
        throw StartupError.message("dashboard needs a valid DASH_ORIGIN (https://host[:port]) and, optionally, DASH_RP_ID as parent domain of its host")
    }
    return config
}

enum StartupError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let m) = self { return m }; return "" }
}

func queryItems(_ req: Request) -> [String: String] {
    var result: [String: String] = [:]
    for item in URLComponents(string: req.url.string)?.queryItems ?? [] { if let v = item.value { result[item.name] = v } }
    return result
}

/// Second HTTP listener (own `Application`, own port). Answers only `/dash/**`; everything else is 404.
func makeDashboardApp(port: Int, api: DashboardApi, stats: StatsCollector) async throws -> Application {
    let app = try await Application.make(makeEnvironment(port: port))
    app.http.server.configuration.serverName = nil
    app.middleware.use(StatsMiddleware(stats: stats))
    @Sendable func translate(_ req: Request, method: String, body: [UInt8]) -> DashboardHTTPRequest {
        DashboardHTTPRequest(
            method: method, path: req.url.path, query: queryItems(req), body: body,
            info: DashboardRequestInfo(method: method, cookieHeader: req.headers.first(name: .cookie), origin: req.headers.first(name: .origin),
                                       host: req.headers.first(name: .host), contentType: req.headers.first(name: .contentType),
                                       csrfToken: req.headers.first(name: "X-CSRF-Token")))
    }
    app.get("**") { req async -> Response in vaporResponse(await api.handle(translate(req, method: "GET", body: []))) }
    for method in [HTTPMethod.POST, .PUT, .DELETE] {
        app.on(method, "**", body: .collect(maxSize: "32kb")) { req async -> Response in
            var buffer = req.body.data ?? ByteBuffer()
            return vaporResponse(await api.handle(translate(req, method: method.rawValue, body: buffer.readBytes(length: buffer.readableBytes) ?? [])))
        }
    }
    return app
}

/// Builds the dashboard API on the shared repo and store.
func makeDashboardApi(repo: any Repo, store: ConfigStore, authConfig: DashboardAuthConfig, logger: Logger) -> (DashboardApi, DashboardAuth) {
    // `notice`: these lines (open setup window, login result) must be visible at the production log level.
    let auth = DashboardAuth(repo: repo, config: authConfig, log: { logger.notice("\($0)") })
    let root = ProcessInfo.processInfo.environment["DASH_STATIC_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? "/app/dashboard"
    return (DashboardApi(auth: auth, repo: repo, store: store, staticRoot: root, restartPolicy: RestartPolicy.fromEnvironment()), auth)
}

/// Minute log of the open setup window (plan 2.4, point 5), until a passkey exists.
func runSetupHintLoop(auth: DashboardAuth) async {
    while !Task.isCancelled {
        if await auth.logSetupHintIfNeeded() == nil { return }
        try? await Task.sleep(nanoseconds: 60_000_000_000)
    }
}

func serve(config bootstrap: Config, dashboardOnly: Bool = false) async throws {
    let env = ProcessInfo.processInfo.environment
    let dashboardEnabled = dashboardOnly || env["DASH_ENABLED"] == "true"
    let dashboardPort = env["DASH_PORT"].flatMap(Int.init) ?? 9090
    // Fail closed before anything is opened: without a valid DASH_ORIGIN the dashboard does not start.
    let dashboardAuthSettings = dashboardEnabled ? try dashboardAuthConfig() : nil
    var bootEnv = makeEnvironment(port: dashboardOnly ? dashboardPort : bootstrap.httpPort)
    try LoggingSystem.bootstrap(from: &bootEnv)
    let logger = Logger(label: "radar")
    let repo = MariaRepo(config: bootstrap)
    let stats = StatsCollector(repo: repo)
    let configStore: ConfigStore
    do { configStore = try await ConfigStore(env: env, repo: repo, warn: { logger.warning("\($0)") }) }
    catch { await repo.shutdown(); throw error }
    let config = configStore.snapshot()
    let provider = configStore.provider
    let heartbeat = Heartbeat()
    let apnsClient = HTTPClient(eventLoopGroupProvider: .singleton)
    let sender = dashboardOnly ? nil : makeApnsSender(config: config, client: apnsClient, logger: logger)

    // `radar dashboard`: the main application IS the dashboard listener (no ingest loops, no public routes).
    // `radar serve` with DASH_ENABLED=true: a second application on DASH_PORT next to the public one.
    let app: Application
    var dashboard: Application?
    var dashAuth: DashboardAuth?
    if dashboardEnabled, let dashboardAuthSettings {
        let (api, auth) = makeDashboardApi(repo: repo, store: configStore, authConfig: dashboardAuthSettings, logger: logger)
        dashAuth = auth
        let dashApp = try await makeDashboardApp(port: dashboardPort, api: api, stats: stats)
        if dashboardOnly { app = dashApp } else { app = try await Application.make(makeEnvironment(port: bootstrap.httpPort)); dashboard = dashApp }
    } else {
        app = try await Application.make(makeEnvironment(port: bootstrap.httpPort))
    }
    app.http.server.configuration.serverName = nil

    let pushApi = !dashboardOnly
    if pushApi {
        let api = Api(repo: repo, configProvider: provider, sender: sender, alive: { heartbeat.isAlive }, stats: stats)
        app.middleware.use(StatsMiddleware(stats: stats))
        app.get("**") { req async -> Response in
            let path = req.url.path
            if path.hasPrefix(PushApi.prefix) {
                return vaporResponse(await api.handlePush(method: "GET", path: path, secret: req.headers.first(name: "X-Installation-Secret"), body: []))
            }
            do {
                return vaporResponse(try await api.handle(path: path, ifNoneMatch: req.headers.first(name: .ifNoneMatch)))
            } catch {
                return Response(status: .serviceUnavailable, headers: ["Cache-Control": "no-store"])
            }
        }
        // Push registration (small JSON bodies); answers 404 unless PUSH_ENABLED=true. `/dash` is always 404 here.
        for method in [HTTPMethod.POST, .PUT, .DELETE] {
            app.on(method, "**", body: .collect(maxSize: "8kb")) { req async -> Response in
                var buffer = req.body.data ?? ByteBuffer()
                return vaporResponse(await api.handlePush(method: method.rawValue, path: req.url.path,
                                                          secret: req.headers.first(name: "X-Installation-Secret"),
                                                          body: buffer.readBytes(length: buffer.readableBytes) ?? []))
            }
        }
    }

    try await repo.ping()
    var tasks: [Task<Void, Never>] = []
    let statsTask = Task { await stats.run() }
    let configTask = Task { await configStore.run() }
    var pushTask: Task<Void, Never>?
    var loop: Task<Void, Never>?
    var backfill: Task<Void, Never>?
    var layerLoops: [Task<Void, Never>] = []
    var restartTask: Task<Void, Never>?
    if pushApi {
        let activity = ActivityFlag()
        loop = Task { await runIngestLoop(config: config, provider: provider, stats: stats, repo: repo, heartbeat: heartbeat, activity: activity, logger: logger) }
        backfill = Task { await runBackfillLoop(config: config, provider: provider, repo: repo, activity: activity, logger: logger) }
        pushTask = Task { await runPushLoop(config: config, stats: stats, repo: repo, sender: sender, logger: logger) }
        layerLoops = config.layers.compactMap { id in
            LayerCatalog.specs[id].map { spec in Task { await runLayerLoop(spec: spec, config: config, provider: provider, stats: stats, repo: repo, logger: logger) } }
        }
        // Controlled restart (plan 5.3): the leader flag is not known here, so replicas leave in slot order.
        let coordinator = try? await RestartCoordinator.make(
            repo: repo, replicaID: replicaID(), slot: RestartPolicy.slot(env), policy: RestartPolicy.fromEnvironment(env),
            isLeader: { false }, leaderSlot: { nil }, shutdown: { logger.info("controlled restart: leaving"); raise(SIGTERM) })
        if let coordinator { restartTask = Task { await coordinator.run() } }
        else { logger.warning("restart coordinator not started (database)") }
    }
    let setupHint = dashAuth.map { auth in Task { await runSetupHintLoop(auth: auth) } }
    tasks = [loop, backfill, pushTask, restartTask, setupHint].compactMap { $0 } + layerLoops

    func stopAll() async {
        tasks.forEach { $0.cancel() }
        configTask.cancel()
        for t in tasks { await t.value }
        await configTask.value
        statsTask.cancel()
        await statsTask.value  // final flush
        try? await apnsClient.shutdown()
    }

    do {
        try await dashboard?.startup()
        if dashboardEnabled { logger.notice("dashboard listening on port \(dashboardPort)") }
        try await app.execute()
    } catch {
        await stopAll()
        try? await dashboard?.asyncShutdown()
        try? await app.asyncShutdown()
        await repo.shutdown()
        throw error
    }
    await stopAll()
    try? await dashboard?.asyncShutdown()
    try await app.asyncShutdown()
    await repo.shutdown()
    logger.info("stopped")
}

func dashboardReset(config: Config) async throws {
    let repo = MariaRepo(config: config)
    do {
        let auth = DashboardAuth(repo: repo, config: DashboardAuthConfig(origin: "https://reset.invalid", rpID: "reset.invalid"), log: { _ in })
        let existed = try await auth.resetViaCLI()
        print(existed ? "passkey and sessions deleted; the setup window opens at the next dashboard start" : "no passkey existed; audit entry written")
    } catch { await repo.shutdown(); throw error }
    await repo.shutdown()
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
            case "dashboard":
                try await serve(config: config, dashboardOnly: true)
            case "dashboard-reset":
                guard arguments.contains("--yes") else {
                    FileHandle.standardError.write(Data("dashboard-reset deletes the passkey and all sessions: pass --yes to confirm\n".utf8))
                    exit(64)
                }
                try await dashboardReset(config: config)
            case "migrate":
                guard arguments.contains("--yes") else {
                    FileHandle.standardError.write(Data("migrate changes the database schema: pass --yes to confirm\n".utf8))
                    exit(64)
                }
                try await migrate(config: config)
            default:
                FileHandle.standardError.write(Data("usage: radar [serve | dashboard | dashboard-reset --yes | migrate --yes]\n".utf8))
                exit(64)
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }
}
