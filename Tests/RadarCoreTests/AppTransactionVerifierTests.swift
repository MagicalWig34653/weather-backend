import Crypto
import Foundation
import SwiftASN1
import Testing
import X509
@testable import RadarCore

// StoreKit AppTransaction JWS verification with self-signed test chains (no Apple keys involved).
private struct TestChain {
    let root: Certificate
    let intermediate: Certificate
    let leaf: Certificate
    let leafKey: P256.Signing.PrivateKey

    init(now: Date = Date(), leafValidFrom: Date? = nil, leafValidUntil: Date? = nil, markers: Bool = true) throws {
        let rootKey = P384.Signing.PrivateKey(), midKey = P384.Signing.PrivateKey()
        leafKey = P256.Signing.PrivateKey()
        let rootName = try DistinguishedName { CommonName("Test Root") }
        let midName = try DistinguishedName { CommonName("Test Intermediate") }
        let leafName = try DistinguishedName { CommonName("Test Leaf") }
        let from = now.addingTimeInterval(-86400), until = now.addingTimeInterval(86400 * 365)
        root = try Certificate(
            version: .v3, serialNumber: .init(), publicKey: .init(rootKey.publicKey), notValidBefore: from, notValidAfter: until,
            issuer: rootName, subject: rootName, signatureAlgorithm: .ecdsaWithSHA384,
            extensions: try Certificate.Extensions { Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil)); KeyUsage(keyCertSign: true) },
            issuerPrivateKey: .init(rootKey))
        let midMarker = try Certificate.Extension(oid: ASN1ObjectIdentifier(dotRepresentation: AppTransactionVerifier.intermediateMarkerOID),
                                                  critical: false, value: [5, 0])
        intermediate = try Certificate(
            version: .v3, serialNumber: .init(), publicKey: .init(midKey.publicKey), notValidBefore: from, notValidAfter: until,
            issuer: rootName, subject: midName, signatureAlgorithm: .ecdsaWithSHA384,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0)); KeyUsage(keyCertSign: true)
                if markers { midMarker }
            },
            issuerPrivateKey: .init(rootKey))
        let leafMarker = try Certificate.Extension(oid: ASN1ObjectIdentifier(dotRepresentation: AppTransactionVerifier.leafMarkerOID),
                                                   critical: false, value: [5, 0])
        leaf = try Certificate(
            version: .v3, serialNumber: .init(), publicKey: .init(leafKey.publicKey),
            notValidBefore: leafValidFrom ?? from, notValidAfter: leafValidUntil ?? until,
            issuer: midName, subject: leafName, signatureAlgorithm: .ecdsaWithSHA384,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                if markers { leafMarker }
            },
            issuerPrivateKey: .init(midKey))
    }

    private func der(_ cert: Certificate) throws -> String {
        var serializer = DER.Serializer()
        try cert.serialize(into: &serializer)
        return Data(serializer.serializedBytes).base64EncodedString()
    }

    func jws(bundleID: String = "de.example.app", receiptType: String = "Sandbox", created: Date = Date(),
             alg: String = "ES256", includeRoot: Bool = false) throws -> String {
        let chain = try [der(leaf), der(intermediate)] + (includeRoot ? [der(root)] : [])
        let header = try JSONSerialization.data(withJSONObject: ["alg": alg, "x5c": chain])
        let payload = try JSONSerialization.data(withJSONObject: [
            "bundleId": bundleID, "receiptType": receiptType, "receiptCreationDate": created.timeIntervalSince1970 * 1000, "appTransactionId": "1"])
        let signingInput = DashboardBase64URL.encode(Array(header)) + "." + DashboardBase64URL.encode(Array(payload))
        let sig = try leafKey.signature(for: Data(signingInput.utf8))
        return signingInput + "." + DashboardBase64URL.encode(Array(sig.rawRepresentation))
    }
}

@Suite("AppTransaction JWS verification")
struct AppTransactionVerifierTests {
    private func verifier(_ chain: TestChain, env: Set<String> = ["Sandbox"], maxAge: Int = 24, markers: Bool = true,
                          clock: @escaping @Sendable () -> Date = { Date() }) -> AppTransactionVerifier {
        AppTransactionVerifier(roots: [chain.root], bundleID: "de.example.app", allowedEnvironments: env, maxAgeHours: maxAge,
                               requireAppleMarkers: markers, clock: clock)
    }

    @Test func acceptsSandboxProof() async throws {
        let chain = try TestChain()
        #expect(await verifier(chain).verify(jws: try chain.jws()) == nil)
        #expect(await verifier(chain).verify(jws: try chain.jws(includeRoot: true)) == nil)
    }

    @Test func refusesProductionAndOtherEnvironments() async throws {
        let chain = try TestChain()
        #expect(await verifier(chain).verify(jws: try chain.jws(receiptType: "Production")) == .production)
        #expect(await verifier(chain).verify(jws: try chain.jws(receiptType: "Xcode")) == .unverified)
        #expect(await verifier(chain, env: ["Sandbox", "Xcode"]).verify(jws: try chain.jws(receiptType: "Xcode")) == nil)
        // Production is refused even when misconfigured into the allowed set? It is the configuration's job; the default never allows it.
        #expect(AppTransactionVerifier(roots: [], bundleID: "x").allowedEnvironments == ["Sandbox"])
    }

    @Test func refusesWrongBundleAndStaleProof() async throws {
        let chain = try TestChain()
        #expect(await verifier(chain).verify(jws: try chain.jws(bundleID: "de.other.app")) == .bundle)
        #expect(await verifier(chain).verify(jws: try chain.jws(created: Date().addingTimeInterval(-25 * 3600))) == .expired)
        #expect(await verifier(chain, maxAge: 0).verify(jws: try chain.jws(created: Date().addingTimeInterval(-900 * 3600))) == nil)
    }

    @Test func refusesWrongChainAndExpiredCertificate() async throws {
        let chain = try TestChain(), other = try TestChain()
        // Signed by a chain that does not lead to the trusted root.
        #expect(await verifier(chain).verify(jws: try other.jws()) == .unverified)
        // Leaf expired at verification time.
        let expired = try TestChain(leafValidFrom: Date().addingTimeInterval(-4 * 86400), leafValidUntil: Date().addingTimeInterval(-2 * 86400))
        #expect(await verifier(expired).verify(jws: try expired.jws()) == .unverified)
        // Missing Apple marker extensions.
        let plain = try TestChain(markers: false)
        #expect(await verifier(plain).verify(jws: try plain.jws()) == .unverified)
        #expect(await verifier(plain, markers: false).verify(jws: try plain.jws()) == nil)
    }

    @Test func refusesTamperedAndMalformedProofs() async throws {
        let chain = try TestChain()
        let good = try chain.jws()
        let parts = good.split(separator: ".").map(String.init)
        // Changed payload (Production claim) with the old signature.
        let forged = DashboardBase64URL.encode(Array(#"{"bundleId":"de.example.app","receiptType":"Production","receiptCreationDate":0}"#.utf8))
        #expect(await verifier(chain, env: ["Sandbox", "Production"]).verify(jws: "\(parts[0]).\(forged).\(parts[2])") == .unverified)
        #expect(await verifier(chain).verify(jws: try chain.jws(alg: "RS256")) == .unverified)
        for bad in ["", "a.b", "a.b.c", "....", good + "x", String(repeating: "a", count: 9000)] {
            #expect(await verifier(chain).verify(jws: bad) == .unverified, "\(bad.prefix(10))")
        }
    }

    @Test func bundledAppleRootIsTheKnownCertificate() throws {
        let root = try #require(AppleRoots.rootG3())
        #expect(root.subject.description.contains("Apple Root CA - G3"))
        var serializer = DER.Serializer()
        try root.serialize(into: &serializer)
        let digest = SHA256.hash(data: Data(serializer.serializedBytes)).map { String(format: "%02X", $0) }.joined(separator: ":")
        #expect(digest == "63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79")
    }
}
