import Crypto
import Foundation
import X509

/// Apple Root CA - G3 (public certificate, https://www.apple.com/certificateauthority/AppleRootCA-G3.cer, valid until 2039-04-30).
/// SHA-256 fingerprint 63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79 (checked against the download).
public enum AppleRoots {
    static let rootG3Base64 = "MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwSQXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBSb290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtfTjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySrMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gAMGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM6BgD56KyKA=="
    public static func rootG3() -> Certificate? {
        Data(base64Encoded: rootG3Base64).flatMap { try? Certificate(derEncoded: Array($0)) }
    }
}

/// Why an AppTransaction proof was refused. Only the counter sees it; clients get a uniform `403 not_testflight`.
public enum AppTransactionReject: String, Sendable, Equatable, CaseIterable {
    case unverified, production, expired, bundle
}

/// Verifies the StoreKit 2 `AppTransaction.jwsRepresentation` (docs/dashboard-insights-plan.md 4.6, decision D14: own minimal check,
/// no new package beyond swift-certificates): compact JWS, `alg` ES256, `x5c` chain up to a trusted Apple root, Apple marker
/// extensions on leaf and intermediate, signature over `header.payload`, then payload fields `bundleId`, `receiptType`,
/// `receiptCreationDate`. Nothing of the JWS is stored or logged; the result is only pass or a fixed reason.
public struct AppTransactionVerifier: Sendable {
    /// Marker OIDs Apple puts into the leaf (Mac App Store receipt signing) and the WWDR intermediate certificate.
    static let leafMarkerOID = "1.2.840.113635.100.6.11.1"
    static let intermediateMarkerOID = "1.2.840.113635.100.6.2.1"
    static let maxJWSBytes = 8 * 1024

    public let roots: [Certificate]
    public let bundleID: String
    public let allowedEnvironments: Set<String>
    public let maxAgeHours: Int
    /// Tests with self-made chains switch the Apple marker extension check off only when they test something else.
    public let requireAppleMarkers: Bool
    let clock: @Sendable () -> Date

    public init(roots: [Certificate], bundleID: String, allowedEnvironments: Set<String> = ["Sandbox"], maxAgeHours: Int = 24,
                requireAppleMarkers: Bool = true, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.roots = roots; self.bundleID = bundleID; self.allowedEnvironments = allowedEnvironments
        self.maxAgeHours = maxAgeHours; self.requireAppleMarkers = requireAppleMarkers; self.clock = clock
    }

    private struct Header: Decodable { let alg: String; let x5c: [String] }
    private struct Payload: Decodable {
        let bundleId: String
        let receiptType: String
        let receiptCreationDate: Double?
    }

    public func verify(jws: String) async -> AppTransactionReject? {
        guard jws.utf8.count <= Self.maxJWSBytes else { return .unverified }
        let parts = jws.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let headerData = DashboardBase64URL.decode(String(parts[0])).map({ Data($0) }),
              let payloadData = DashboardBase64URL.decode(String(parts[1])).map({ Data($0) }),
              let signature = DashboardBase64URL.decode(String(parts[2])), signature.count == 64,
              let header = try? JSONDecoder().decode(Header.self, from: headerData), header.alg == "ES256",
              (2...5).contains(header.x5c.count) else { return .unverified }
        let certs = header.x5c.compactMap { Data(base64Encoded: $0).flatMap { try? Certificate(derEncoded: Array($0)) } }
        guard certs.count == header.x5c.count else { return .unverified }
        let leaf = certs[0], intermediates = Array(certs.dropFirst())
        let now = clock()

        var verifier = Verifier(rootCertificates: CertificateStore(roots)) { RFC5280Policy(validationTime: now) }
        guard case .validCertificate = await verifier.validate(leafCertificate: leaf, intermediates: CertificateStore(intermediates)) else {
            return .unverified
        }
        if requireAppleMarkers {
            guard Self.hasExtension(leaf, Self.leafMarkerOID), intermediates.contains(where: { Self.hasExtension($0, Self.intermediateMarkerOID) })
            else { return .unverified }
        }
        guard let key = try? P256.Signing.PublicKey(leaf.publicKey),
              let sig = try? P256.Signing.ECDSASignature(rawRepresentation: signature),
              key.isValidSignature(sig, for: Data((String(parts[0]) + "." + String(parts[1])).utf8)) else { return .unverified }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: payloadData) else { return .unverified }
        guard payload.bundleId == bundleID else { return .bundle }
        guard allowedEnvironments.contains(payload.receiptType) else { return payload.receiptType == "Production" ? .production : .unverified }
        if maxAgeHours > 0 {
            // `receiptCreationDate` is milliseconds since 1970 in Apple's AppTransaction payload.
            guard let ms = payload.receiptCreationDate else { return .expired }
            let age = now.timeIntervalSince(Date(timeIntervalSince1970: ms / 1000))
            guard age <= Double(maxAgeHours) * 3600, age >= -300 else { return .expired }
        }
        return nil
    }

    private static func hasExtension(_ cert: Certificate, _ oid: String) -> Bool {
        cert.extensions.contains { $0.oid.description == oid }
    }
}
