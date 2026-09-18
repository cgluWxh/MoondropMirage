import Foundation

enum MirageError: Error, LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}

struct GaiaPDU {
    let vendor: Int
    let feature: Int
    let type: Int
    let command: Int
    let payload: [UInt8]
}

enum AncMode: UInt8, CaseIterable {
    case off = 0
    case adaptive = 1
    case transparency = 2
    case wind = 3
    case anc = 4

    var title: String {
        switch self {
        case .off: return "关闭"
        case .adaptive: return "自适应"
        case .transparency: return "通透"
        case .wind: return "抗风噪"
        case .anc: return "降噪"
        }
    }
}

struct BatteryLevels {
    var left: UInt8?
    var right: UInt8?
    var chargingCase: UInt8?

    static func parse(_ payload: [UInt8]) -> BatteryLevels {
        var values: [UInt8: UInt8] = [:]
        var index = 0
        while index + 1 < payload.count {
            let value = payload[index + 1]
            values[payload[index]] = value <= 100 ? value : nil
            index += 2
        }
        return BatteryLevels(left: values[1], right: values[2], chargingCase: values[3])
    }
}

struct MultipointDevice: Hashable {
    let slot: String
    let status: UInt8
    let address: String
    let addressBytes: [UInt8]
    let name: String
}

enum GaiaCodec {
    static let vendor = 0x001D

    static func makePDU(feature: Int, command: Int, payload: [UInt8] = []) -> [UInt8] {
        let commandValue = (feature << 9) | (command & 0x7F)
        return [
            UInt8((vendor >> 8) & 0xFF), UInt8(vendor & 0xFF),
            UInt8((commandValue >> 8) & 0xFF), UInt8(commandValue & 0xFF),
        ] + payload
    }

    static func wrapV4(_ pdu: [UInt8]) -> [UInt8] {
        let payloadLength = max(0, pdu.count - 4)
        if payloadLength <= 0xFF {
            return [0xFF, 0x04, 0x00, UInt8(payloadLength)] + pdu
        }
        return [
            0xFF, 0x04, 0x02,
            UInt8((payloadLength >> 8) & 0xFF), UInt8(payloadLength & 0xFF),
        ] + pdu
    }

    static func parsePDU(_ bytes: [UInt8]) -> GaiaPDU? {
        guard bytes.count >= 4 else { return nil }
        let vendor = (Int(bytes[0]) << 8) | Int(bytes[1])
        let value = (Int(bytes[2]) << 8) | Int(bytes[3])
        return GaiaPDU(
            vendor: vendor,
            feature: (value >> 9) & 0x7F,
            type: (value >> 7) & 0x03,
            command: value & 0x7F,
            payload: Array(bytes.dropFirst(4))
        )
    }
}
