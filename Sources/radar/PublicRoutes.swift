import RadarCore
import Vapor

/// Routes of the public listener. `**` does not match the root path in Vapor, so `/` (German landing page) is registered separately
/// for GET (HEAD falls back to GET). POST/PUT/DELETE only serve the push registration.
func registerPublicRoutes(_ app: Application, api: Api) {
    @Sendable func get(_ req: Request) async -> Response {
        let path = req.url.path
        if path.hasPrefix(PushApi.prefix) {
            return vaporResponse(await api.handlePush(method: "GET", path: path, secret: req.headers.first(name: "X-Installation-Secret"), body: []))
        }
        do {
            return vaporResponse(try await api.handle(path: path, ifNoneMatch: req.headers.first(name: .ifNoneMatch), acceptLanguage: req.headers.first(name: .acceptLanguage)))
        } catch {
            return Response(status: .serviceUnavailable, headers: ["Cache-Control": "no-store"])
        }
    }
    app.get("**") { req async -> Response in await get(req) }
    app.get { req async -> Response in await get(req) }
    // Push registration (small JSON bodies); answers 404 unless PUSH_ENABLED=true. `/dash` is always 404 here.
    for method in [HTTPMethod.POST, .PUT, .DELETE] {
        @Sendable func push(_ req: Request) async -> Response {
            var buffer = req.body.data ?? ByteBuffer()
            return vaporResponse(await api.handlePush(method: method.rawValue, path: req.url.path,
                                                      secret: req.headers.first(name: "X-Installation-Secret"),
                                                      body: buffer.readBytes(length: buffer.readableBytes) ?? []))
        }
        app.on(method, "**", body: .collect(maxSize: "8kb")) { req async -> Response in await push(req) }
        app.on(method, body: .collect(maxSize: "8kb")) { req async -> Response in await push(req) }
    }
}
