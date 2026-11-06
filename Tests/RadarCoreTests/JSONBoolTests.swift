import Foundation
import Testing
@testable import RadarCore

@Suite("JSONBool")
struct JSONBoolTests {
    private func decode(_ json: String) throws -> Any? {
        let o = try JSONSerialization.jsonObject(with: Data("{\"v\":\(json)}".utf8)) as? [String: Any]
        return o?["v"]
    }

    @Test("Bool vs number")
    func boolVsNumber() throws {
        for (json, isBool) in [("true", true), ("false", true), ("1", false), ("0", false), ("1.5", false), ("1.0", false)] {
            let n = try #require(try decode(json) as? NSNumber)
            #expect(isJSONBool(n) == isBool, "\(json)")
        }
    }

    @Test("jsonWholeNumber")
    func wholeNumber() throws {
        #expect(jsonWholeNumber(try decode("5")) == 5)
        #expect(jsonWholeNumber(try decode("1")) == 1)
        #expect(jsonWholeNumber(try decode("0")) == 0)
        #expect(jsonWholeNumber(try decode("2.0")) == 2)
        #expect(jsonWholeNumber(try decode("true")) == nil)
        #expect(jsonWholeNumber(try decode("false")) == nil)
        #expect(jsonWholeNumber(try decode("1.5")) == nil)
        #expect(jsonWholeNumber(try decode("\"1\"")) == nil)
        #expect(jsonWholeNumber(try decode("null")) == nil)
        #expect(jsonWholeNumber(nil) == nil)
    }
}
