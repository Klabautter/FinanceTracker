import Foundation
import Security

/// Enable Banking API-Authentifizierung: RS256-signierte JWTs pro Request.
///
/// - Header: {typ: JWT, alg: RS256, kid: <Application ID>}
/// - Payload: {iss: "enablebanking.com", aud: "api.enablebanking.com", iat, exp}
/// - Signatur: RSASSA-PKCS1-v1_5 mit SHA-256 über dem privaten RSA-Schlüssel
///   der Anwendung (PEM, PKCS#8: wird bei der App-Registrierung erzeugt).
///
/// Sicherheit: Der private Schlüssel lebt ausschließlich im
/// Keychain; hier wird er nur im Speicher gehalten und niemals geloggt.
struct EnableBankingJWTSigner: Sendable {

    struct SignerError: Error, Equatable {
        enum Reason: Equatable {
            case invalidPEM
            case unsupportedKeyFormat
            case keyCreationFailed(status: Int32)
            case signingFailed(status: Int32)
        }

        let reason: Reason
    }

    let applicationID: String
    let privateKeyPEM: String
    private let clock: @Sendable () -> Date

    init(applicationID: String, privateKeyPEM: String, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.applicationID = applicationID
        self.privateKeyPEM = privateKeyPEM
        self.clock = clock
    }

    /// Erzeugt ein frisches, kurzlebiges JWT (exp = iat + 1 h gemäß Doku).
    func makeToken(now: Date? = nil) throws -> String {
        let timestamp = Int((now ?? clock()).timeIntervalSince1970)
        let headerJSON = #"{"typ":"JWT","alg":"RS256","kid":"\#(applicationID)"}"#
        let payloadJSON = #"{"iss":"enablebanking.com","aud":"api.enablebanking.com","iat":\#(timestamp),"exp":\#(timestamp + 3600)}"#

        let header = Self.base64URL(Data(headerJSON.utf8))
        let payload = Self.base64URL(Data(payloadJSON.utf8))
        let signingInput = "\(header).\(payload)"

        let key = try Self.loadPrivateKey(pem: privateKeyPEM)
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            key,
            .rsaSignatureMessagePKCS1v15SHA256,
            Data(signingInput.utf8) as CFData,
            &error
        ) else {
            throw SignerError(reason: .signingFailed(status: -1))
        }

        return "\(signingInput).\(Self.base64URL(signature as Data))"
    }

    // MARK: - Base64URL (RFC 7515, ohne Padding)

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Key Loading

    /// Lädt einen RSA-Privatschlüssel aus PEM (PKCS#8 oder PKCS#1) als SecKey.
    static func loadPrivateKey(pem: String) throws -> SecKey {
        let der = try derFromPEM(pem)
        let pkcs1: Data
        if Self.isPKCS8(der: der) {
            pkcs1 = try Self.pkcs1FromPKCS8(der: der)
        } else {
            pkcs1 = der
        }

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(
            pkcs1 as CFData,
            [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary,
            &error
        ) else {
            throw SignerError(reason: .keyCreationFailed(status: -1))
        }
        return key
    }

    /// Extrahiert die Base64-Payload aus einer PEM-Datei (ignoriert Header/
    /// Footer/Whitespace).
    static func derFromPEM(_ pem: String) throws -> Data {
        let base64 = pem
            .components(separatedBy: .newlines)
            .filter { !$0.contains("-----") }
            .joined()
            .trimmingCharacters(in: .whitespaces)
        guard !base64.isEmpty, let der = Data(base64Encoded: base64) else {
            throw SignerError(reason: .invalidPEM)
        }
        return der
    }

    /// PKCS#8 beginnt mit SEQ { INTEGER version 0, SEQ (AlgorithmIdentifier),
    /// OCTET STRING }, erkennbar am führenden Byte-Muster 0x30 0x82 … 0x02 0x01 0x00 0x30 0x0d.
    static func isPKCS8(der: Data) -> Bool {
        // SEQ(header) + version INTEGER 0 + AlgorithmIdentifier SEQ startet mit 0x30 0x0D 0x06 0x09 (rsaEncryption OID).
        let pattern: [UInt8] = [0x02, 0x01, 0x00, 0x30]
        guard der.count > 16, der[der.startIndex] == 0x30 else { return false }
        let bytes = [UInt8](der.subdata(in: der.startIndex + 4 ..< der.startIndex + 8))
        return bytes == pattern
    }

    /// Minimaler DER-Parser: entpackt PKCS#8 → PKCS#1 (RSAPrivateKey).
    static func pkcs1FromPKCS8(der: Data) throws -> Data {
        var reader = DERReader(data: der)

        // Äußere SEQUENCE
        guard reader.readTag() == 0x30 else { throw SignerError(reason: .unsupportedKeyFormat) }
        let outerLength = try reader.readLength()
        let outer = try reader.readContents(of: outerLength)

        var inner = DERReader(data: outer)
        // version INTEGER
        guard inner.readTag() == 0x02 else { throw SignerError(reason: .unsupportedKeyFormat) }
        let versionLength = try inner.readLength()
        let version = try inner.readContents(of: versionLength)
        guard version == Data([0x00]) || version == Data([0x02]) else {
            throw SignerError(reason: .unsupportedKeyFormat)
        }
        // AlgorithmIdentifier SEQUENCE
        guard inner.readTag() == 0x30 else { throw SignerError(reason: .unsupportedKeyFormat) }
        let algLength = try inner.readLength()
        _ = try inner.readContents(of: algLength)
        // OCTET STRING mit dem PKCS#1-Schlüssel
        guard inner.readTag() == 0x04 else { throw SignerError(reason: .unsupportedKeyFormat) }
        let keyLength = try inner.readLength()
        let pkcs1 = try inner.readContents(of: keyLength)
        return pkcs1
    }
}

/// Minimaler, nicht-escaping DER/TLV-Reader für den einzigen Zweck:
/// PKCS#8 → PKCS#1-Extraktion (definiertes Format, keine Fremd-Eingaben).
struct DERReader {
    let data: Data
    var offset: Int

    init(data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    mutating func readTag() -> UInt8? {
        guard offset < data.endIndex else { return nil }
        let tag = data[offset]
        offset += 1
        return tag
    }

    mutating func readLength() throws -> Int {
        guard offset < data.endIndex else { throw EnableBankingJWTSigner.SignerError(reason: .invalidPEM) }
        let first = Int(data[offset])
        offset += 1
        if first < 0x80 { return first }
        let lengthBytes = first & 0x7F
        guard lengthBytes <= 4 else { throw EnableBankingJWTSigner.SignerError(reason: .invalidPEM) }
        var length = 0
        for _ in 0..<lengthBytes {
            guard offset < data.endIndex else { throw EnableBankingJWTSigner.SignerError(reason: .invalidPEM) }
            length = (length << 8) | Int(data[offset])
            offset += 1
        }
        return length
    }

    mutating func readContents() throws -> Data {
        let length = try readLength()
        return try readContents(of: length)
    }

    mutating func readContents(of length: Int) throws -> Data {
        guard offset + length <= data.endIndex else {
            throw EnableBankingJWTSigner.SignerError(reason: .invalidPEM)
        }
        let content = data.subdata(in: offset ..< offset + length)
        offset += length
        return content
    }
}