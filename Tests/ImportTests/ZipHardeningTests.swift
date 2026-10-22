import Foundation
import Testing

@testable import FinanceTracker

@Suite("ZipHardening")
struct ZipHardeningTests {
    private func littleEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }

    private func littleEndian16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    private func buildArchive(
        entryName: String = "a.txt",
        compressionMethod: UInt16 = 0,
        declaredUncompressedSize: UInt32,
        actualPayload: [UInt8]
    ) -> Data {
        let nameBytes = Array(entryName.utf8)

        var local: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
        local += littleEndian16(20)
        local += littleEndian16(0)
        local += littleEndian16(compressionMethod)
        local += littleEndian16(0)
        local += littleEndian16(0)
        local += littleEndian(0)
        local += littleEndian(UInt32(actualPayload.count))
        local += littleEndian(declaredUncompressedSize)
        local += littleEndian16(UInt16(nameBytes.count))
        local += littleEndian16(0)
        local += nameBytes
        local += actualPayload

        var central: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
        central += littleEndian16(20)
        central += littleEndian16(20)
        central += littleEndian16(0)
        central += littleEndian16(compressionMethod)
        central += littleEndian16(0)
        central += littleEndian16(0)
        central += littleEndian(0)
        central += littleEndian(UInt32(actualPayload.count))
        central += littleEndian(declaredUncompressedSize)
        central += littleEndian16(UInt16(nameBytes.count))
        central += littleEndian16(0)
        central += littleEndian16(0)
        central += littleEndian16(0)
        central += littleEndian16(0)
        central += littleEndian(0)
        central += littleEndian(0)
        central += nameBytes

        var eocd: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        eocd += littleEndian16(0)
        eocd += littleEndian16(0)
        eocd += littleEndian16(1)
        eocd += littleEndian16(1)
        eocd += littleEndian(UInt32(central.count))
        eocd += littleEndian(UInt32(local.count))
        eocd += littleEndian16(0)

        return Data(local + central + eocd)
    }

    @Test("Keine Signatur wird abgelehnt")
    func rejectsNonZip() {
        #expect(throws: ZipArchiveError.notAZipArchive) {
            _ = try ZipArchiveReader(data: Data("hello world".utf8))
        }
    }

    @Test("Abgeschnittener EOCD wird kontrolliert abgelehnt")
    func rejectsTruncatedEOCD() throws {
        let valid = buildArchive(declaredUncompressedSize: 3, actualPayload: Array("abc".utf8))
        let truncated = valid.prefix(valid.count - 10)

        #expect(throws: ZipArchiveError.corrupt(reason: "EOCD zu kurz")) {
            _ = try ZipArchiveReader(data: Data(truncated))
        }
    }

    @Test("Manipulierte uncompressedSize wird abgelehnt statt allokiert")
    func rejectsHugeDeclaredSizes() throws {
        let huge: UInt32 = 2_000_000_000
        let archive = buildArchive(
            compressionMethod: 8,
            declaredUncompressedSize: huge,
            actualPayload: Array(repeating: 0x00, count: 8)
        )

        let reader = try ZipArchiveReader(data: archive)
        #expect(throws: ZipArchiveError.entryTooLarge(name: "a.txt", size: Int(huge))) {
            _ = try reader.extractEntry("a.txt")
        }
    }

    @Test("Nicht unterstützte Kompression liefert kontrollierten Fehler")
    func rejectsUnsupportedCompression() throws {
        let payload = Array("stored!".utf8)
        let archive = buildArchive(
            compressionMethod: 99,
            declaredUncompressedSize: UInt32(payload.count),
            actualPayload: payload
        )

        let reader = try ZipArchiveReader(data: archive)
        #expect(throws: ZipArchiveError.decompressionFailed(entry: "a.txt")) {
            _ = try reader.extractEntry("a.txt")
        }
    }

    @Test("Gültige Stored-Einträge werden unverändert gelesen")
    func readsStoredEntries() throws {
        let payload = Array("stored!".utf8)
        let archive = buildArchive(
            compressionMethod: 0,
            declaredUncompressedSize: UInt32(payload.count),
            actualPayload: payload
        )

        let reader = try ZipArchiveReader(data: archive)
        let extracted = try reader.extractEntry("a.txt")
        #expect(String(decoding: extracted, as: UTF8.self) == "stored!")
    }

    @Test("XLSX-Konverter lehnt übergroße Dateien früh ab")
    func converterRejectsOversizedInput() throws {
        var oversized = Data([0x50, 0x4B, 0x03, 0x04])
        oversized.append(Data(repeating: 0x00, count: ImportLimits.maxFileSizeBytes + 1))
        #expect(XLSXConverter.isZipArchive(oversized))

        #expect(throws: XLSXConverterError.fileTooLarge(size: oversized.count)) {
            _ = try XLSXConverter.csvText(from: oversized)
        }
    }
}
