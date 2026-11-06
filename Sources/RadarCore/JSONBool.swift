import Foundation

/// True for a JSON `true`/`false` decoded by JSONSerialization (NSNumber), false for numbers.
/// Core Foundation type IDs only exist on Apple platforms; swift-corelibs-foundation tags booleans with objCType "c".
func isJSONBool(_ n: NSNumber) -> Bool {
    #if canImport(Darwin)
    return CFGetTypeID(n) == CFBooleanGetTypeID()
    #else
    return String(cString: n.objCType) == "c"
    #endif
}

/// Integer value of a decoded JSON value: only real whole numbers, never booleans, strings or null.
func jsonWholeNumber(_ raw: Any?) -> Int? {
    guard let n = raw as? NSNumber, !isJSONBool(n), n.doubleValue == n.doubleValue.rounded() else { return nil }
    return n.intValue
}
