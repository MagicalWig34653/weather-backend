import Crypto

enum Hashing {
    static func sha256Hex(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: bytes).map { String($0, radix: 16).count == 1 ? "0" + String($0, radix: 16) : String($0, radix: 16) }
            .joined()
    }
}
