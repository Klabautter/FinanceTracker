import Foundation

/// WP29: Minimaler ZIP-Writer (STORED, unkomprimiert) für das
/// `.ftbackup`-Package. Bewusst nur STORED: Kein Kompressionsbedarf im
/// Export-Pfad, der bestehende `ZipArchiveReader` kann das Archiv lesen.
enum BackupArchiveWriter {
    struct Entry {
        let name: String
        let data: Data
    }

    enum ArchiveError: Error {
        case entryNameInvalid(String)
    }

    /// Erzeugt ein ZIP-Archiv mit den Einträgen (Pfade mit "/").
    static func archive(entries: [Entry]) throws -> Data {
        var output = Data()
        var centralDirectory = Data()
        var entryCount = 0

        for entry in entries {
            try validate(entryName: entry.name)

            let nameData = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(output.count)
            let dosDate = dosDateTime()

            // Local File Header
            output.appendLE(UInt32(0x0403_4b50))
            output.appendLE(UInt16(20))          // version needed
            output.appendLE(UInt16(0))           // flags
            output.appendLE(UInt16(0))           // method: stored
            output.appendLE(UInt16(dosDate.time))
            output.appendLE(UInt16(dosDate.date))
            output.appendLE(crc)
            output.appendLE(size)                // compressed
            output.appendLE(size)                // uncompressed
            output.appendLE(UInt16(nameData.count))
            output.appendLE(UInt16(0))           // extra length
            output.append(nameData)
            output.append(entry.data)

            // Central Directory Eintrag
            centralDirectory.appendLE(UInt32(0x0201_4b50))
            centralDirectory.appendLE(UInt16(20))  // version made by
            centralDirectory.appendLE(UInt16(20))  // version needed
            centralDirectory.appendLE(UInt16(0))   // flags
            centralDirectory.appendLE(UInt16(0))   // method: stored
            centralDirectory.appendLE(UInt16(dosDate.time))
            centralDirectory.appendLE(UInt16(dosDate.date))
            centralDirectory.appendLE(crc)
            centralDirectory.appendLE(size)
            centralDirectory.appendLE(size)
            centralDirectory.appendLE(UInt16(nameData.count))
            centralDirectory.appendLE(UInt16(0))   // extra
            centralDirectory.appendLE(UInt16(0))   // comment
            centralDirectory.appendLE(UInt16(0))   // disk number
            centralDirectory.appendLE(UInt16(0))   // internal attrs
            centralDirectory.appendLE(UInt32(0))   // external attrs
            centralDirectory.appendLE(offset)
            centralDirectory.append(nameData)

            entryCount += 1
        }

        let centralOffset = UInt32(output.count)
        output.append(centralDirectory)

        // End of Central Directory
        output.appendLE(UInt32(0x0605_4b50))
        output.appendLE(UInt16(0))   // disk
        output.appendLE(UInt16(0))   // cd disk
        output.appendLE(UInt16(entryCount))
        output.appendLE(UInt16(entryCount))
        output.appendLE(UInt32(centralDirectory.count))
        output.appendLE(centralOffset)
        output.appendLE(UInt16(0))   // comment length

        return output
    }

    private static func validate(entryName name: String) throws {
        guard !name.isEmpty,
              !name.hasPrefix("/"),
              !name.contains(".."),
              !name.contains("\\") else {
            throw ArchiveError.entryNameInvalid(name)
        }
    }

    private static func dosDateTime() -> (time: UInt16, date: UInt16) {
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        let year = max(1980, components.year ?? 1980)
        let date = UInt16(((year - 1980) << 9) | ((components.month ?? 1) << 5) | (components.day ?? 1))
        let time = UInt16(((components.hour ?? 0) << 11) | ((components.minute ?? 0) << 5) | ((components.second ?? 0) / 2))
        return (time, date)
    }

    // MARK: - CRC32

    private static let crcTable: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
            }
            return value
        }
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
