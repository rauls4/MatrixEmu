import CryptoKit
import Foundation

/// ESP-IDF application image (ESP32-S3).
///
/// Layout, matching esptool's ESP32FirmwareImage:
///   8-byte common header (magic 0xE9, segment count, flash mode, size/freq, entry)
///   16-byte extended header (chip id at offset 12, hash flag at offset 23)
///   repeated segments of uint32 load address, uint32 length, payload
///   zero pad, then a checksum byte that 16-byte-aligns the image
///   optional SHA-256 of those bytes when the hash flag is 1
struct FirmwareError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum ESPImage {
    static let magic: UInt8 = 0xE9
    static let chipESP32S3: UInt16 = 0x0009
    static let programAddress: UInt32 = 0x3FC00000
    static let checksumMagic: UInt8 = 0xEF

    /// Bytes of the segment loaded at `programAddress`, or a clear error.
    static func program(in data: Data) throws -> [UInt8] {
        if data.count > 8 * 1024 * 1024 {
            throw FirmwareError(message: "not an ESP32 image (file too large)")
        }
        if data.count < 24 || data[0] != magic {
            throw FirmwareError(message: "not an ESP32 image (missing 0xE9 header)")
        }
        let segCount = Int(data[1])
        if segCount < 1 || segCount > 16 {
            throw FirmwareError(message: "not an ESP32 image (bad segment count)")
        }
        let chip = u16(data, 12)
        if chip != chipESP32S3 {
            throw FirmwareError(message: String(format: "not an ESP32-S3 image (chip id 0x%04X)", chip))
        }
        let hashFlag = data[23]
        if hashFlag > 1 {
            throw FirmwareError(message: "not an ESP32 image (bad hash flag)")
        }

        var off = 24
        var segments: [(UInt32, Data)] = []
        for _ in 0..<segCount {
            if off + 8 > data.count {
                throw FirmwareError(message: "not an ESP32 image (truncated segment header)")
            }
            let addr = u32(data, off)
            let length = Int(u32(data, off + 4))
            off += 8
            if length < 0 || length > 16 * 1024 * 1024 || off + length > data.count {
                throw FirmwareError(message: "not an ESP32 image (bad segment length)")
            }
            if length % 4 != 0 {
                throw FirmwareError(message: "not an ESP32 image (segment length is not a multiple of 4)")
            }
            segments.append((addr, data.subdata(in: off..<(off + length))))
            off += length
        }

        let align = 15 - (off % 16)
        let csumAt = off + align
        if csumAt >= data.count {
            throw FirmwareError(message: "not an ESP32 image (truncated checksum)")
        }
        var expect = checksumMagic
        for (_, payload) in segments {
            for byte in payload {
                expect ^= byte
            }
        }
        if data[csumAt] != expect {
            throw FirmwareError(message: "not an ESP32 image (checksum mismatch)")
        }
        let imageEnd = csumAt + 1
        if hashFlag == 1 {
            if imageEnd + 32 > data.count {
                throw FirmwareError(message: "not an ESP32 image (truncated sha256)")
            }
            let digest = Data(SHA256.hash(data: data.prefix(imageEnd)))
            if data.subdata(in: imageEnd..<(imageEnd + 32)) != digest {
                throw FirmwareError(message: "not an ESP32 image (sha256 mismatch)")
            }
        }

        let programs = segments.filter { $0.0 == programAddress }
        if programs.isEmpty {
            throw FirmwareError(message: "ESP32 image has no program segment at 0x3FC00000")
        }
        if programs.count != 1 {
            throw FirmwareError(message: "ESP32 image has more than one segment at 0x3FC00000")
        }
        if programs[0].1.isEmpty {
            throw FirmwareError(message: "program segment at 0x3FC00000 is empty")
        }
        return [UInt8](programs[0].1)
    }

    /// Build an ESP32-S3 application image with one program segment at `programAddress`.
    /// Matches firmware/assemble.py `build_image` (header, checksum, SHA-256).
    static func build(bytecode: [UInt8], entry: UInt32 = programAddress, loadAddr: UInt32 = programAddress) -> Data {
        var code = bytecode
        if code.count % 4 != 0 {
            code.append(contentsOf: [UInt8](repeating: 0x00, count: 4 - (code.count % 4)))
        }
        precondition(!code.isEmpty && code.count <= 0x100000, "program segment length is invalid")

        var body = Data()
        // Common header: magic, 1 segment, flash mode DIO (2), size/speed 0x5F, entry.
        body.append(magic)
        body.append(1)
        body.append(2)
        body.append(0x5F)
        body.append(contentsOf: le32(entry))
        // Extended header (16 bytes). Chip id at file offset 12.
        body.append(0xEE)
        body.append(0)
        body.append(0)
        body.append(0)
        body.append(contentsOf: le16(chipESP32S3))
        body.append(0) // min_rev
        body.append(contentsOf: le16(0)) // min_rev_full
        body.append(contentsOf: le16(0xFFFF)) // max_rev_full
        body.append(contentsOf: [0, 0, 0, 0])
        body.append(1) // hash appended
        precondition(body.count == 24)

        body.append(contentsOf: le32(loadAddr))
        body.append(contentsOf: le32(UInt32(code.count)))
        body.append(contentsOf: code)

        var checksum = checksumMagic
        for b in code { checksum ^= b }

        let align = 15 - (body.count % 16)
        body.append(contentsOf: [UInt8](repeating: 0, count: align))
        body.append(checksum)
        precondition(body.count % 16 == 0)

        let digest = SHA256.hash(data: body)
        body.append(contentsOf: digest)
        return body
    }

    private static func le16(_ v: UInt16) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
    }

    private static func le32(_ v: UInt32) -> [UInt8] {
        [
            UInt8(v & 0xFF),
            UInt8((v >> 8) & 0xFF),
            UInt8((v >> 16) & 0xFF),
            UInt8((v >> 24) & 0xFF),
        ]
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
