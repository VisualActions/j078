import Foundation
import CoreBluetooth

// J078 protocol notes, recovered by static reading of the vendor Android app
// ("365 Scooter"). Mostly read from an older 64-bit build (1.1.4); the heartbeat
// was also seen in 1.1.6. Nothing here has been checked against a real scooter yet.
// Anything marked UNVERIFIED is a guess from code reading, not a confirmed fact.
enum J078 {

    // MARK: - UUIDs

    // 16-bit services/characteristics seen in the app's strings.
    static let shortIDs = ["F1F0", "F1F1", "F1F2", "F2F0", "F2F1", "F2F2"]

    // The app only shows the "6e40000x" prefixes. UNVERIFIED: that the full UUIDs
    // are the standard Nordic UART ones below. Matching in this app is done by
    // prefix, so a different 128-bit suffix still gets recognised after connecting.
    static let nusService = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")

    // Used only when "Only scooter services" is on while scanning. UNVERIFIED that
    // the scooter advertises any of these; if the filter finds nothing, turn it off.
    static let scanServices: [CBUUID] = [
        CBUUID(string: "F1F0"),
        CBUUID(string: "F2F0"),
        nusService
    ]

    /// Short readable name for a UUID ("F1F1", "6E400003", or the full UUID).
    static func name(for uuid: CBUUID) -> String {
        let s = uuid.uuidString.uppercased()
        for short in shortIDs {
            if s == short || s.hasPrefix("0000" + short + "-") {
                return short
            }
        }
        for prefix in ["6E400001", "6E400002", "6E400003"] {
            if s.hasPrefix(prefix) {
                return prefix
            }
        }
        return s
    }

    // MARK: - Heartbeat (F1F1)

    // Built by a no-argument function in the app and written to F1F1 on a
    // repeating timer after all channels are found. Same bytes in 1.1.6.
    // Framing theory: A5 [cmd] [~cmd] 5A (UNVERIFIED).
    static let heartbeat: [UInt8] = [0xA5, 0x02, 0xFD, 0x5A]

    // Timer constant in the app is 0x7A120 = 500000. UNVERIFIED that the unit is
    // microseconds, i.e. one heartbeat every 500 ms.
    static let heartbeatInterval: TimeInterval = 0.5

    // MARK: - 6E400003 "decryption"

    // The app passes every byte it sends on 6E400002 through a fixed byte
    // substitution: +A4, ^29, +C7, ^3A, ^7B, +EB, ^DE (all mod 256).
    // Its 6E400003 handler applies the exact inverse below to every received byte.
    // (Checked offline: inverse(encrypt(x)) == x for all 256 values.)
    // Example: "password OK" DB EB CA CA FF would arrive on air as 99 C9 E4 E4 25,
    // IF the scooter uses the same chain (UNVERIFIED).
    static func decryptByte(_ b: UInt8) -> UInt8 {
        var x = b ^ 0xDE
        x = x &- 0xEB
        x = x ^ 0x7B
        x = x ^ 0x3A
        x = x &- 0xC7
        x = x ^ 0x29
        x = x &- 0xA4
        return x
    }

    static func decrypt(_ bytes: [UInt8]) -> [UInt8] {
        return bytes.map { decryptByte($0) }
    }

    // MARK: - Helpers

    static func hex(_ bytes: [UInt8]) -> String {
        return bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// CRC16-Modbus (init FFFF, poly A001 reflected). The app uses this for its
    /// AC 00 0A ... and Modbus 01 03 / 01 10 packets on F1F1. Low byte goes first.
    static func crc16Modbus(_ data: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for b in data {
            crc ^= UInt16(b)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xA001
                } else {
                    crc = crc >> 1
                }
            }
        }
        return crc
    }

    // MARK: - Parsing

    /// Short reply frames on 6E400003 after decryption: DB EB [type] [sub] [result...]
    /// Labels come from the app's own log strings. Byte layouts past the first
    /// few bytes are not decoded yet.
    static func parseDBEB(_ d: [UInt8]) -> String? {
        guard d.count >= 3, d[0] == 0xDB, d[1] == 0xEB else { return nil }
        if d.count >= 18 && d[2] == 0xFA && d[3] == 0xDB {
            return "big status packet (DB EB FA DB, \(d.count) bytes), layout not decoded yet"
        }
        switch d[2] {
        case 0xBA:
            return "password reply (DB EB BA)"
        case 0x10 where d.count >= 4 && d[3] == 0xB0:
            return "supported-feature list (DB EB 10 B0)"
        case 0x20 where d.count >= 4 && d[3] == 0xB0:
            return "fault code data (DB EB 20 B0)"
        case 0xCA:
            if d.count >= 5 && d[3] == 0xCA && d[4] == 0xFF {
                return "password OK (DB EB CA CA FF)"
            }
            if d.count >= 5 && d[3] == 0xCA && d[4] == 0xAA {
                return "password wrong (DB EB CA CA AA)"
            }
            return "reset-password reply (DB EB CA ..)"
        default:
            return String(format: "DB EB reply, type %02X (not in the map yet)", d[2])
        }
    }

    /// Guesses about a raw frame on any channel. These are only hints.
    static func rawHints(_ b: [UInt8]) -> [String] {
        var hints: [String] = []
        if b.count >= 4, b[0] == 0xA5, b[b.count - 1] == 0x5A {
            if b[2] == ~b[1] {
                hints.append(String(format: "A5 frame, cmd %02X, byte 3 = ~cmd (guess)", b[1]))
            } else {
                hints.append("A5 ... 5A frame, byte 3 is not ~cmd")
            }
        }
        if b.count >= 5 {
            let body = Array(b[0..<(b.count - 2)])
            let crc = crc16Modbus(body)
            let lo = UInt8(crc & 0xFF)
            let hi = UInt8(crc >> 8)
            if b[b.count - 2] == lo && b[b.count - 1] == hi {
                hints.append(String(format: "CRC16-Modbus OK (maybe Modbus/AC frame, first bytes %02X %02X)", b[0], b[1]))
            }
        }
        return hints
    }

    /// Text shown under a received packet.
    static func describe(_ bytes: [UInt8], channel: String) -> String {
        var lines: [String] = []
        if channel == "6E400003" {
            let d = decrypt(bytes)
            lines.append("decrypted: " + hex(d))
            if let label = parseDBEB(d) {
                lines.append(label)
            }
        }
        lines.append(contentsOf: rawHints(bytes))
        return lines.joined(separator: "\n")
    }

    // MARK: - TODO: settings writes (NOT in v1, on purpose)
    //
    // Do not add these until the packets above are confirmed on the real scooter
    // (nRF Connect or this app's log). All of it is UNVERIFIED:
    //
    // - F1F1, 10 bytes: AC 00 0A [flags] 00 00 00 00 [crcLo] [crcHi]
    //   flags = (a & 3) + b<<2 + c<<4 + d<<5 + e<<6 + f<<7 from six settings
    //   (lock, start mode, current mode, gear, km/mi ... which bit is which is unknown).
    //   CRC16-Modbus over the first 8 bytes.
    // - F1F1, Modbus RTU read:  01 03 [addrHi] [addrLo] 00 01 [crcLo] [crcHi]
    // - F1F1, Modbus RTU write: 01 10 [addrHi] [addrLo] [cntHi] [cntLo] [2*cnt]
    //   [data words, big endian] [crcLo] [crcHi]
    //   (speed limits S/D/E/pedestrian, brake strength, start strength, units).
    //   Register addresses are not mapped yet.
    // - F1F1, 8 bytes: A5 00 FF 00 00 00 00 5A, sent in a 500 ms loop (poll?).
    // - 6E400002: [BD BE AB] + data, every byte through the encrypt chain
    //   (lights, password, lock/unlock). Also a 3-byte AF FF FF after the
    //   heartbeat starts (purpose unknown).
    //
    // No lock, password or firmware features belong in this app until proven safe.
}
