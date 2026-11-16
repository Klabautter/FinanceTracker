import Foundation
import Security

/// Wegwerf-Testschlüssel, bei jedem Testlauf neu im Speicher erzeugt (nie
/// im Schlüsselbund, nie im Repository). Format wie die Datei aus dem
/// Enable-Banking-Control-Panel: PKCS#8, PEM.
enum EnableBankingTestKeys {
    static let privatePEM: String = makePKCS8PEM()

    private static func makePKCS8PEM() -> String {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048,
            kSecAttrIsPermanent: false
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let pkcs1 = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            fatalError("Testschlüssel konnte nicht erzeugt werden")
        }
        // PKCS#8 = SEQUENCE { INTEGER 0, SEQUENCE { rsaEncryption, NULL }, OCTET STRING pkcs1 }
        let version: [UInt8] = [0x02, 0x01, 0x00]
        let algorithm: [UInt8] = [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00]
        let octet = [0x04] + derLength(pkcs1.count) + [UInt8](pkcs1)
        let body = version + algorithm + octet
        let der = Data([0x30] + derLength(body.count) + body)
        let base64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN PRIVATE KEY-----\n\(base64)\n-----END PRIVATE KEY-----"
    }

    private static func derLength(_ length: Int) -> [UInt8] {
        guard length >= 0x80 else { return [UInt8(length)] }
        var bytes: [UInt8] = []
        var remaining = length
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }
}
