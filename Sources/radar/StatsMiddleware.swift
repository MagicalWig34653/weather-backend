import Vapor
import RadarCore

/// Counts finished requests per route group and status class (see `StatsCollector.recordRequest`). The path is only classified,
/// never stored or logged. Statistics never influence the response: the middleware only reads status and body size.
struct StatsMiddleware: AsyncMiddleware {
    let stats: StatsCollector

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let response: Response
        do {
            response = try await next.respond(to: request)
        } catch {
            let status = (error as? any AbortError)?.status.code ?? 500
            stats.recordRequest(path: request.url.path, status: Int(status), bytes: 0)
            throw error
        }
        // Streaming bodies report -1: counted as 0 bytes.
        stats.recordRequest(path: request.url.path, status: Int(response.status.code), bytes: max(0, response.body.count))
        return response
    }
}
