import Compression
import Foundation

enum ZipArchiveError: Error, Equatable {
    case notAZipArchive
    case corrupt(reason: String)
    case entryNotFound(name: String)
    case tooManyEntries(count: Int)
    case entryTooLarge(name: String, size: Int)
    case totalExpandedSizeExceeded(limit: Int)
    case decompressionFailed(entry: String)
}

final class ZipArchiveReader {
    private struct CentralDirectoryRecord {
        let name: String
        let checksum: UInt32
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let data: Data
    private let records: [CentralDirectoryRecord]
    private let maxEntryBytes: Int
    private let verifyChecksums: Bool

    init(data: Data, maxArchiveBytes: Int = ImportLimits.maxFileSizeBytes, maxEntryBytes: Int = ImportLimits.maxSingleUncompressedBytes, verifyChecksums: Bool = false) throws {
        self.maxEntryBytes = maxEntryBytes
        self.verifyChecksums = verifyChecksums
        guard data.count <= maxArchiveBytes else {
            throw ZipArchiveError.entryTooLarge(name: "<archive>", size: data.count)
        }
        self.data = data
        self.records = try Self.parseCentralDirectory(data)

        guard records.count <= ImportLimits.maxZipEntries else {
            throw ZipArchiveError.tooManyEntries(count: records.count)
        }
    }

    var entryNames: [String] { records.map(\.name) }

    func containsEntry(named name: String) -> Bool {
        records.contains { $0.name == name }
    }

    func uncompressedSize(ofEntry name: String) -> Int? {
        records.first { $0.name == name }?.uncompressedSize
    }

    func extractEntry(_ name: String) throws -> Data {
        guard let record = records.first(where: { $0.name == name }) else {
            throw ZipArchiveError.entryNotFound(name: name)
        }

        guard record.uncompressedSize <= maxEntryBytes else {
            throw ZipArchiveError.entryTooLarge(name: name, size: record.uncompressedSize)
        }

        let headerSignature: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
        let localHeaderStart = record.localHeaderOffset

        guard data.count >= localHeaderStart + 30,
              Array(data[localHeaderStart..<localHeaderStart + 4]) == headerSignature else {
            throw ZipArchiveError.corrupt(reason: "Ungültiger Local Header für \(name)")
        }

        let localNameLength = try Self.readUInt16(data, at: localHeaderStart + 26)
        let localExtraLength = try Self.readUInt16(data, at: localHeaderStart + 28)
        let dataStart = localHeaderStart + 30 + Int(localNameLength) + Int(localExtraLength)
        let compressedEnd = dataStart + record.compressedSize

        guard record.compressedSize >= 0, compressedEnd <= data.count else {
            throw ZipArchiveError.corrupt(reason: "Eintrag \(name) verweist außerhalb der Datei")
        }

        let compressedBytes = data[dataStart..<compressedEnd]

        let extracted: Data
        switch record.compressionMethod {
        case 0:
            guard record.compressedSize == record.uncompressedSize else {
                throw ZipArchiveError.corrupt(reason: "Ungültige Größe für \(name)")
            }
            extracted = Data(compressedBytes)
        case 8:
            extracted = try Self.inflate(compressedBytes, expectedSize: record.uncompressedSize, entry: name)
        default:
            throw ZipArchiveError.decompressionFailed(entry: name)
        }

        if verifyChecksums, BackupArchiveWriter.crc32(extracted) != record.checksum {
            throw ZipArchiveError.corrupt(reason: "Prüfsumme stimmt für \(name) nicht überein")
        }
        return extracted
    }

    private static func parseCentralDirectory(_ data: Data) throws -> [CentralDirectoryRecord] {
        guard let eocdOffset = findEndOfCentralDirectoryOffset(in: data) else {
            throw ZipArchiveError.notAZipArchive
        }

        guard eocdOffset + 22 <= data.count else {
            throw ZipArchiveError.corrupt(reason: "EOCD zu kurz")
        }

        let entryCount = Int(try readUInt16(data, at: eocdOffset + 10))
        let directorySize = Int(try readUInt32(data, at: eocdOffset + 12))
        let directoryStart = Int(try readUInt32(data, at: eocdOffset + 16))

        guard directoryStart >= 0, directorySize >= 0, directoryStart + directorySize <= data.count else {
            throw ZipArchiveError.corrupt(reason: "Central Directory außerhalb der Datei")
        }

        var entries: [CentralDirectoryRecord] = []
        var cursor = directoryStart

        for _ in 0..<entryCount {
            guard cursor + 46 <= data.count else {
                throw ZipArchiveError.corrupt(reason: "Abgeschnittener Central Directory Eintrag")
            }
            guard try readUInt32(data, at: cursor) == 0x02014B50 else {
                throw ZipArchiveError.corrupt(reason: "Ungültige Central Directory Signatur")
            }

            let checksum = try readUInt32(data, at: cursor + 16)
            let compressionMethod = try readUInt16(data, at: cursor + 10)
            let compressedSize = Int(try readUInt32(data, at: cursor + 20))
            let uncompressedSize = Int(try readUInt32(data, at: cursor + 24))
            let nameLength = Int(try readUInt16(data, at: cursor + 28))
            let extraLength = Int(try readUInt16(data, at: cursor + 30))
            let commentLength = Int(try readUInt16(data, at: cursor + 32))
            let localHeaderOffset = Int(try readUInt32(data, at: cursor + 42))

            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLength
            guard nameLength >= 0, extraLength >= 0, commentLength >= 0, nameEnd <= data.count else {
                throw ZipArchiveError.corrupt(reason: "Ungültige Eintragslängen")
            }

            let name = String(decoding: data[nameStart..<nameEnd], as: UTF8.self)

            if !name.hasSuffix("/") {
                entries.append(
                    CentralDirectoryRecord(
                        name: name,
                        checksum: checksum,
                        compressionMethod: compressionMethod,
                        compressedSize: compressedSize,
                        uncompressedSize: uncompressedSize,
                        localHeaderOffset: localHeaderOffset
                    )
                )
            }

            cursor = nameEnd + extraLength + commentLength
        }

        return entries
    }

    private static func findEndOfCentralDirectoryOffset(in data: Data) -> Int? {
        let signature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        let scanWindow = min(66_000, data.count)
        let lowerBound = data.count - scanWindow

        guard lowerBound >= 0, data.count >= 4 else { return nil }

        var index = data.count - 4
        while index >= lowerBound {
            if Array(data[index..<index + 4]) == signature {
                return index
            }
            index -= 1
        }
        return nil
    }

    private static func inflate(_ input: Data, expectedSize: Int, entry: String) throws -> Data {
        guard expectedSize > 0 else { return Data() }

        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: expectedSize)
        defer { destination.deallocate() }

        let decodedSize = input.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) -> Int in
            guard let source = rawBuffer.baseAddress else { return 0 }
            return compression_decode_buffer(
                destination, expectedSize,
                source.assumingMemoryBound(to: UInt8.self), input.count,
                nil, COMPRESSION_ZLIB
            )
        }

        guard decodedSize == expectedSize else {
            throw ZipArchiveError.decompressionFailed(entry: entry)
        }
        return Data(bytes: destination, count: decodedSize)
    }

    private static func readUInt16(_ data: Data, at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else {
            throw ZipArchiveError.corrupt(reason: "Lesen außerhalb der Grenzen (u16 bei \(offset))")
        }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else {
            throw ZipArchiveError.corrupt(reason: "Lesen außerhalb der Grenzen (u32 bei \(offset))")
        }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
