import Foundation

/// Minimal JSON tree for the insights answers: explicit `null` for "not collected" (never omitted keys, never 0), sorted keys.
enum IJ: Encodable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([IJ])
    case object([String: IJ])

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .null:
            var c = encoder.singleValueContainer(); try c.encodeNil()
        case .bool(let v):
            var c = encoder.singleValueContainer(); try c.encode(v)
        case .int(let v):
            var c = encoder.singleValueContainer(); try c.encode(v)
        case .double(let v):
            var c = encoder.singleValueContainer(); try c.encode(v)
        case .string(let v):
            var c = encoder.singleValueContainer(); try c.encode(v)
        case .array(let v):
            var c = encoder.unkeyedContainer(); for e in v { try c.encode(e) }
        case .object(let v):
            var c = encoder.container(keyedBy: DynamicKey.self)
            for (k, e) in v { try c.encode(e, forKey: DynamicKey(k)) }
        }
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    // MARK: builders

    static func opt(_ v: Int?) -> IJ { v.map { .int($0) } ?? .null }
    static func opt(_ v: String?) -> IJ { v.map { .string($0) } ?? .null }
    /// Shares and ratios: at most 4 decimals.
    static func ratio(_ v: Double?) -> IJ { v.map { .double(round($0 * 10000) / 10000) } ?? .null }
    static func num(_ v: Double?, decimals: Int = 1) -> IJ {
        guard let v else { return .null }
        let f = pow(10.0, Double(decimals))
        return .double(round(v * f) / f)
    }
    static func date(_ v: Date?) -> IJ { v.map { .string(TimeUtil.toISO($0)) } ?? .null }
    static func strings(_ v: [String]) -> IJ { .array(v.map { .string($0) }) }
}
