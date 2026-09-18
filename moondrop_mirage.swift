#!/usr/bin/env swift

import Foundation
import IOBluetooth

private let defaultDeviceName = "MOONDROP MIRAGE"
private let sppUUID16: BluetoothSDPUUID16 = 0x1101
private let gaiaVendor = 0x001D

private enum CLIError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let text): return text
        }
    }
}

private struct GaiaPDU {
    let vendor: Int
    let feature: Int
    let type: Int
    let command: Int
    let payload: [UInt8]
}

private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

/// GAIA V3/QTiL PDU, also used as the payload of GAIA V4 RFCOMM frames.
private func makePDU(feature: Int, command: Int, payload: [UInt8] = []) -> [UInt8] {
    let commandValue = (feature << 9) | (command & 0x7F)
    return [
        UInt8((gaiaVendor >> 8) & 0xFF), UInt8(gaiaVendor & 0xFF),
        UInt8((commandValue >> 8) & 0xFF), UInt8(commandValue & 0xFF),
    ] + payload
}

/// Official RFCOMM envelope: FF | version | flags | payload-length | PDU.
/// Length counts only bytes after the four-byte vendor/command PDU header.
private func wrapV4(_ pdu: [UInt8]) -> [UInt8] {
    let payloadLength = max(0, pdu.count - 4)
    if payloadLength <= 0xFF {
        return [0xFF, 0x04, 0x00, UInt8(payloadLength)] + pdu
    }
    return [
        0xFF, 0x04, 0x02,
        UInt8((payloadLength >> 8) & 0xFF), UInt8(payloadLength & 0xFF),
    ] + pdu
}

private func parsePDU(_ bytes: [UInt8]) -> GaiaPDU? {
    guard bytes.count >= 4 else { return nil }
    let vendor = (Int(bytes[0]) << 8) | Int(bytes[1])
    let commandValue = (Int(bytes[2]) << 8) | Int(bytes[3])
    return GaiaPDU(
        vendor: vendor,
        feature: (commandValue >> 9) & 0x7F,
        type: (commandValue >> 7) & 0x03,
        command: commandValue & 0x7F,
        payload: Array(bytes.dropFirst(4))
    )
}

private let featureNames: [Int: String] = [
    0x00: "Basic", 0x01: "Earbud", 0x02: "ANC V1", 0x05: "Music Processing/EQ",
    0x07: "Handset Service", 0x08: "Audio Curation", 0x0D: "Battery",
    0x0E: "Voice", 0x0F: "DAC Gain", 0x10: "Codec", 0x12: "Spatial Audio",
    0x13: "LED", 0x14: "One-bring-two/Multipoint", 0x15: "Bluetooth Address",
    0x16: "Touch V2", 0x17: "Audio Resource", 0x18: "Power Control",
    0x19: "Power Timeout", 0x1A: "Touch V3", 0x1B: "Dynamic Bass",
    0x1D: "Audio File Storage", 0x1E: "L/R Channel", 0x20: "ANC V2",
]

private func parseSupportedFeatures(_ payload: [UInt8]) -> [(id: Int, version: Int?)] {
    // Official SDK list form: hasMoreData byte, followed by feature/version pairs.
    if payload.count >= 3 && payload.count % 2 == 1 {
        var result: [(Int, Int?)] = []
        var index = 1
        while index + 1 < payload.count {
            result.append((Int(payload[index]), Int(payload[index + 1])))
            index += 2
        }
        return result
    }
    // Older firmware bitmap form: feature number equals its bit index.
    var result: [(Int, Int?)] = []
    for (byteIndex, byte) in payload.enumerated() {
        for bit in 0..<8 where (byte & UInt8(1 << bit)) != 0 {
            result.append((byteIndex * 8 + bit, nil))
        }
    }
    return result
}

private func readVoiceConfiguration(_ session: BluetoothSession) throws -> (enabled: UInt8, volume: UInt8, index: UInt8) {
    try session.send(makePDU(feature: 0x0E, command: 0x01))
    guard let response = session.waitForResponse(feature: 0x0E, command: 0x01), response.payload.count >= 3 else {
        throw CLIError.message("提示音配置查询失败或设备返回旧版格式")
    }
    return (response.payload[0], response.payload[1], response.payload[2])
}

private func parseBluetoothAddress(_ text: String) throws -> [UInt8] {
    let compact = text.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
    guard compact.count == 12 else { throw CLIError.message("MAC 地址格式错误：\(text)") }
    var bytes: [UInt8] = []
    for offset in stride(from: 0, to: compact.count, by: 2) {
        let start = compact.index(compact.startIndex, offsetBy: offset)
        let end = compact.index(start, offsetBy: 2)
        guard let byte = UInt8(compact[start..<end], radix: 16) else {
            throw CLIError.message("MAC 地址格式错误：\(text)")
        }
        bytes.append(byte)
    }
    return bytes
}

private final class BluetoothSession: NSObject, IOBluetoothRFCOMMChannelDelegate {
    private(set) var received: [GaiaPDU] = []
    private(set) var closed = false
    private var framedBuffer: [UInt8] = []
    private var sdpFinished = false
    private var sdpStatus: IOReturn = kIOReturnError
    private var channel: IOBluetoothRFCOMMChannel?

    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        sdpStatus = status
        sdpFinished = true
    }

    @objc func rfcommChannelData(
        _ rfcommChannel: IOBluetoothRFCOMMChannel!,
        data dataPointer: UnsafeMutableRawPointer!,
        length dataLength: Int
    ) {
        let chunk = [UInt8](Data(bytes: dataPointer, count: dataLength))
        print("RX raw: \(hex(chunk))")

        // Some firmware sends a bare PDU, sometimes in addition to the framed copy.
        if chunk.count >= 4 && chunk[0] == 0x00 && chunk[1] == 0x1D {
            // A few devices emit "bare PDU + framed copy" in one RFCOMM burst.
            // Split at the next recognizable frame marker when present.
            var boundary: Int?
            if chunk.count > 4 {
                for index in 4..<chunk.count {
                    if chunk[index] == 0xFF ||
                        (chunk[index] == 0x00 && index + 1 < chunk.count && chunk[index + 1] == 0x1D) {
                        boundary = index
                        break
                    }
                }
            }
            if let boundary {
                acceptPDU(Array(chunk[..<boundary]))
                framedBuffer += Array(chunk[boundary...])
                drainFramedBuffer()
            } else {
                acceptPDU(chunk)
            }
            return
        }

        framedBuffer += chunk
        drainFramedBuffer()
    }

    @objc func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        closed = true
    }

    private func acceptPDU(_ bytes: [UInt8]) {
        guard let pdu = parsePDU(bytes), pdu.vendor == gaiaVendor else { return }
        print(String(
            format: "RX GAIA: feature=0x%02X type=%d command=0x%02X payload=[%@]",
            pdu.feature, pdu.type, pdu.command, hex(pdu.payload)
        ))
        received.append(pdu)
    }

    private func drainFramedBuffer() {
        while true {
            while !framedBuffer.isEmpty && framedBuffer[0] != 0xFF {
                framedBuffer.removeFirst()
            }
            guard framedBuffer.count >= 4 else { return }

            let version = Int(framedBuffer[1])
            let flags = Int(framedBuffer[2])
            let extended = version >= 4 && (flags & 0x02) != 0
            let headerLength = extended ? 5 : 4
            guard framedBuffer.count >= headerLength else { return }

            let payloadLength: Int
            if extended {
                payloadLength = (Int(framedBuffer[3]) << 8) | Int(framedBuffer[4])
            } else {
                payloadLength = Int(framedBuffer[3])
            }
            let checksumLength = (flags & 0x01) != 0 ? 1 : 0
            let pduLength = payloadLength + 4
            let totalLength = headerLength + pduLength + checksumLength
            guard framedBuffer.count >= totalLength else { return }

            let pdu = Array(framedBuffer[headerLength..<(headerLength + pduLength)])
            framedBuffer.removeFirst(totalLength)
            acceptPDU(pdu)
        }
    }

    private func pumpRunLoop(until deadline: Date, condition: () -> Bool) {
        while Date() < deadline && !condition() {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    func connect(deviceName: String, forcedChannelID: BluetoothRFCOMMChannelID?) throws {
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        guard let device = devices.first(where: {
            ($0.name ?? "").caseInsensitiveCompare(deviceName) == .orderedSame
        }) else {
            let names = devices.compactMap { $0.name }.joined(separator: ", ")
            throw CLIError.message(
                "找不到已配对设备 \"\(deviceName)\"。请先在系统设置中配对。\n已配对设备：\(names.isEmpty ? "（无）" : names)"
            )
        }

        print("设备：\(device.name ?? deviceName) [\(device.addressString ?? "unknown")]" )

        let channelID: BluetoothRFCOMMChannelID
        if let forcedChannelID {
            channelID = forcedChannelID
        } else {
            sdpFinished = false
            let queryResult = device.performSDPQuery(self)
            guard queryResult == kIOReturnSuccess else {
                throw CLIError.message(String(format: "启动 SDP 查询失败：0x%08X", queryResult))
            }
            pumpRunLoop(until: Date().addingTimeInterval(12)) { self.sdpFinished }
            guard sdpFinished else { throw CLIError.message("SDP 查询超时") }
            guard sdpStatus == kIOReturnSuccess else {
                throw CLIError.message(String(format: "SDP 查询失败：0x%08X", sdpStatus))
            }

            let uuid = IOBluetoothSDPUUID.uuid16(sppUUID16)
            guard let record = device.getServiceRecord(for: uuid) else {
                throw CLIError.message("设备未公开标准 SPP 服务 UUID 0x1101；可用 --channel N 手工指定 RFCOMM 通道")
            }
            var discoveredID: BluetoothRFCOMMChannelID = 0
            let idResult = record.getRFCOMMChannelID(&discoveredID)
            guard idResult == kIOReturnSuccess && discoveredID != 0 else {
                throw CLIError.message("无法从 SPP 服务记录取得 RFCOMM 通道")
            }
            channelID = discoveredID
        }

        print("RFCOMM 通道：\(channelID)")
        var openedChannel: IOBluetoothRFCOMMChannel?
        let openResult = device.openRFCOMMChannelSync(
            &openedChannel,
            withChannelID: channelID,
            delegate: self
        )
        guard openResult == kIOReturnSuccess, let openedChannel else {
            throw CLIError.message(String(format: "打开 RFCOMM 通道失败：0x%08X", openResult))
        }
        channel = openedChannel
    }

    func send(_ pdu: [UInt8]) throws {
        guard let channel, channel.isOpen() else {
            throw CLIError.message("RFCOMM 通道未连接")
        }
        let frame = wrapV4(pdu)
        print("TX:     \(hex(frame))")
        let result = frame.withUnsafeBytes { rawBuffer -> IOReturn in
            channel.writeSync(
                UnsafeMutableRawPointer(mutating: rawBuffer.baseAddress!),
                length: UInt16(frame.count)
            )
        }
        guard result == kIOReturnSuccess else {
            throw CLIError.message(String(format: "RFCOMM 写入失败：0x%08X", result))
        }
    }

    func waitForResponse(feature: Int, command: Int, timeout: TimeInterval = 3) -> GaiaPDU? {
        let existing = received.count
        pumpRunLoop(until: Date().addingTimeInterval(timeout)) {
            self.closed || self.received.dropFirst(existing).contains {
                $0.feature == feature && $0.command == command
            }
        }
        return received.dropFirst(existing).last {
            $0.feature == feature && $0.command == command
        }
    }

    func disconnect() {
        _ = channel?.close()
        channel = nil
    }
}

private enum AncMode: String, CaseIterable {
    case off
    case adaptive
    case transparency
    case wind
    case anc

    var deviceValue: UInt8 {
        switch self {
        case .off: return 0x00
        case .adaptive: return 0x01
        case .transparency: return 0x02
        case .wind: return 0x03
        case .anc: return 0x04
        }
    }

    static func from(deviceValue: UInt8) -> AncMode? {
        allCases.first { $0.deviceValue == deviceValue }
    }

    var displayName: String {
        switch self {
        case .off: return "关闭"
        case .adaptive: return "自适应降噪"
        case .transparency: return "通透"
        case .wind: return "抗风噪"
        case .anc: return "基础降噪"
        }
    }
}

private enum GainLevel: String, CaseIterable {
    case low
    case medium
    case high

    var deviceValue: UInt8 {
        switch self {
        case .low: return 0x02
        case .medium: return 0x01
        case .high: return 0x00
        }
    }

    static func from(deviceValue: UInt8) -> GainLevel? {
        allCases.first { $0.deviceValue == deviceValue }
    }

    static func fromCLI(_ value: String) -> GainLevel? {
        if let named = GainLevel(rawValue: value.lowercased()) { return named }
        switch value {
        case "0": return .high
        case "1": return .medium
        case "2": return .low
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        }
    }
}

private struct Options {
    var deviceName = defaultDeviceName
    var channelID: BluetoothRFCOMMChannelID?
    var command: [String] = []
}

private func usage() -> String {
    """
    用法：
      swift moondrop_mirage.swift [--device NAME] [--channel N] battery
      swift moondrop_mirage.swift [--device NAME] [--channel N] features
      swift moondrop_mirage.swift [--device NAME] [--channel N] anc get
      swift moondrop_mirage.swift [--device NAME] [--channel N] anc set MODE
      swift moondrop_mirage.swift [--device NAME] [--channel N] anc cycle get
      swift moondrop_mirage.swift [--device NAME] [--channel N] anc cycle set LIST
      swift moondrop_mirage.swift [--device NAME] [--channel N] gain get
      swift moondrop_mirage.swift [--device NAME] [--channel N] gain set LEVEL
      swift moondrop_mirage.swift [--device NAME] [--channel N] voice get
      swift moondrop_mirage.swift [--device NAME] [--channel N] voice on|off
      swift moondrop_mirage.swift [--device NAME] [--channel N] voice volume 0...100
      swift moondrop_mirage.swift [--device NAME] [--channel N] voice index 0...255
      swift moondrop_mirage.swift [--device NAME] [--channel N] lhdc get|on|off
      swift moondrop_mirage.swift [--device NAME] [--channel N] led get|on|off
      swift moondrop_mirage.swift [--device NAME] [--channel N] multipoint get|on|off
      swift moondrop_mirage.swift [--device NAME] [--channel N] multipoint devices
      swift moondrop_mirage.swift [--device NAME] [--channel N] multipoint timeout
      swift moondrop_mirage.swift [--device NAME] [--channel N] multipoint timeout set off|5|10|30|60
      swift moondrop_mirage.swift [--device NAME] [--channel N] multipoint disconnect MAC

    MODE：off | adaptive | transparency | wind | anc
    LEVEL：low | medium | high，也可直接用原始值 0 | 1 | 2
    LIST：按循环顺序写 on/off/transparent，用逗号分隔，例如 on,transparent,off

    默认设备名：\(defaultDeviceName)
    --channel 通常无需设置；仅在 SDP 无法发现标准 SPP 服务时使用。
    """
}

private func parseOptions() throws -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        if args[0] == "--device" {
            guard args.count >= 2 else { throw CLIError.message("--device 缺少名称") }
            options.deviceName = args[1]
            args.removeFirst(2)
        } else if args[0] == "--channel" {
            guard args.count >= 2, let value = UInt8(args[1]), value > 0 else {
                throw CLIError.message("--channel 必须是 1...255")
            }
            options.channelID = value
            args.removeFirst(2)
        } else if args[0] == "-h" || args[0] == "--help" {
            print(usage())
            exit(0)
        } else {
            options.command = args
            break
        }
    }
    guard !options.command.isEmpty else { throw CLIError.message(usage()) }
    return options
}

private func run() throws {
    let options = try parseOptions()
    let session = BluetoothSession()
    defer { session.disconnect() }
    try session.connect(deviceName: options.deviceName, forcedChannelID: options.channelID)

    switch options.command {
    case ["features"]:
        try session.send(makePDU(feature: 0x00, command: 0x01))
        guard let response = session.waitForResponse(feature: 0x00, command: 0x01) else {
            throw CLIError.message("能力查询超时（未收到 BASIC feature=0/cmd=1 回包）")
        }
        let features = parseSupportedFeatures(response.payload)
        if features.isEmpty {
            print("设备未报告任何能力，原始 payload=[\(hex(response.payload))]")
        } else {
            print("设备能力：")
            for feature in features {
                let name = featureNames[feature.id] ?? "Unknown"
                let version = feature.version.map { " v\($0)" } ?? ""
                print(String(format: "  0x%02X  %@%@", feature.id, name, version))
            }
        }

    case ["battery"]:
        // Pudding: BATTERY feature 0x0D, GET_BATTERY_LEVELS cmd 1.
        // Ask for left, right and case; firmware may return any available subset.
        try session.send(makePDU(feature: 0x0D, command: 0x01, payload: [0x01, 0x02]))
        guard let response = session.waitForResponse(feature: 0x0D, command: 0x01) else {
            throw CLIError.message("电量查询超时（未收到 feature=0x0D/cmd=1 回包）")
        }
        var values: [UInt8: UInt8] = [:]
        var index = 0
        while index + 1 < response.payload.count {
            values[response.payload[index]] = response.payload[index + 1]
            index += 2
        }
        let labels: [(UInt8, String)] = [(1, "左耳"), (2, "右耳"), (3, "充电盒")]
        for (id, label) in labels {
            if let value = values[id], value <= 100 { print("\(label)：\(value)%") }
            else if let value = values[id] {
                print("\(label)：不可用（原始值 0x\(String(format: "%02X", value))）")
            }
            else { print("\(label)：未返回") }
        }

    case ["anc", "get"]:
        try session.send(makePDU(feature: 0x20, command: 0x03))
        guard let response = session.waitForResponse(feature: 0x20, command: 0x03),
              let value = response.payload.first else {
            throw CLIError.message("ANC 查询超时（未收到 feature=0x20/cmd=3 回包）")
        }
        if let mode = AncMode.from(deviceValue: value) {
            print("ANC：\(mode.displayName)（0x\(String(format: "%02X", value))）")
        } else {
            print("ANC：未知模式 0x\(String(format: "%02X", value))")
        }

    case ["anc", "cycle", "get"]:
        try session.send(makePDU(feature: 0x20, command: 0x29))
        guard let response = session.waitForResponse(feature: 0x20, command: 0x29) else {
            throw CLIError.message("ANC 按键循环配置查询超时（未收到 feature=0x20/cmd=41 回包）")
        }
        guard response.payload.count >= 5 else {
            throw CLIError.message("ANC 按键循环配置长度异常：payload=[\(hex(response.payload))]")
        }
        let fields = ["STATE", "ANC_ON", "ANC_OFF", "TRANSPARENT", "ORDER"]
        let orderNames = [
            "ANC_ON → ANC_OFF → TRANSPARENT",
            "ANC_OFF → ANC_ON → TRANSPARENT",
            "TRANSPARENT → ANC_ON → ANC_OFF",
            "ANC_ON → TRANSPARENT → ANC_OFF",
            "ANC_OFF → TRANSPARENT → ANC_ON",
            "TRANSPARENT → ANC_OFF → ANC_ON",
        ]
        print("ANC 按键循环原始值：[\(hex(response.payload))]")
        for index in 0..<4 {
            print("  \(fields[index])：\(response.payload[index] == 1 ? "启用" : "禁用")（0x\(String(format: "%02X", response.payload[index]))）")
        }
        let order = Int(response.payload[4])
        print("  ORDER：\(order < orderNames.count ? orderNames[order] : "未知")（\(order)）")

    case let command where command.count == 4 && command[0] == "anc" && command[1] == "cycle" && command[2] == "set":
        let requested = command[3].lowercased().split(separator: ",").map(String.init)
        let valid = Set(["on", "off", "transparent"])
        guard requested.count >= 2, requested.count <= 3,
              Set(requested).count == requested.count,
              requested.allSatisfy({ valid.contains($0) }) else {
            throw CLIError.message("ANC 循环 LIST 必须包含 2～3 个不重复模式：on/off/transparent")
        }
        let missing = ["on", "off", "transparent"].filter { !requested.contains($0) }
        let completeOrder = requested + missing
        let orderMap: [[String]: UInt8] = [
            ["on", "off", "transparent"]: 0,
            ["off", "on", "transparent"]: 1,
            ["transparent", "on", "off"]: 2,
            ["on", "transparent", "off"]: 3,
            ["off", "transparent", "on"]: 4,
            ["transparent", "off", "on"]: 5,
        ]
        guard let order = orderMap[completeOrder] else { throw CLIError.message("无法编码 ANC 循环顺序") }
        let payload: [UInt8] = [
            1,
            requested.contains("on") ? 1 : 0,
            requested.contains("off") ? 1 : 0,
            requested.contains("transparent") ? 1 : 0,
            order,
        ]
        try session.send(makePDU(feature: 0x20, command: 0x2A, payload: payload))
        _ = session.waitForResponse(feature: 0x20, command: 0x2A, timeout: 1.5)
        print("ANC 按键循环已设置：\(requested.joined(separator: " → "))；payload=[\(hex(payload))]")

    case let command where command.count == 3 && command[0] == "anc" && command[1] == "set":
        guard let mode = AncMode(rawValue: command[2].lowercased()) else {
            throw CLIError.message("未知 ANC 模式 \"\(command[2])\"；可选：off/adaptive/transparency/wind/anc")
        }
        try session.send(makePDU(feature: 0x20, command: 0x04, payload: [mode.deviceValue]))
        if let response = session.waitForResponse(feature: 0x20, command: 0x04, timeout: 1.5) {
            let returned = response.payload.first ?? mode.deviceValue
            let returnedMode = AncMode.from(deviceValue: returned)?.displayName ?? "未知"
            print("ANC 已设置：\(returnedMode)（0x\(String(format: "%02X", returned))）")
        } else {
            // Some firmware treats SET as fire-and-forget. Verify with GET.
            try session.send(makePDU(feature: 0x20, command: 0x03))
            if let response = session.waitForResponse(feature: 0x20, command: 0x03),
               let returned = response.payload.first {
                let returnedMode = AncMode.from(deviceValue: returned)?.displayName ?? "未知"
                print("ANC 已设置并读回：\(returnedMode)（0x\(String(format: "%02X", returned))）")
            } else {
                print("设置命令已发送，但设备未返回 ACK/查询结果；请听感确认")
            }
        }

    case ["gain", "get"]:
        // MIRAGE: DAC_GAIN feature 0x0F, GET_GAIN cmd 1; 00/01/02 = high/medium/low.
        try session.send(makePDU(feature: 0x0F, command: 0x01))
        guard let response = session.waitForResponse(feature: 0x0F, command: 0x01),
              let value = response.payload.first else {
            throw CLIError.message("增益查询超时（未收到 feature=0x0F/cmd=1 回包）")
        }
        if let level = GainLevel.from(deviceValue: value) {
            print("增益：\(level.displayName)（0x\(String(format: "%02X", value))）")
        } else {
            print("增益：未知档位 0x\(String(format: "%02X", value))")
        }

    case let command where command.count == 3 && command[0] == "gain" && command[1] == "set":
        guard let level = GainLevel.fromCLI(command[2]) else {
            throw CLIError.message("未知增益档位 \"\(command[2])\"；可选：low/medium/high 或原始值 0/1/2")
        }
        try session.send(makePDU(feature: 0x0F, command: 0x02, payload: [level.deviceValue]))
        if let response = session.waitForResponse(feature: 0x0F, command: 0x02, timeout: 1.5) {
            let returned = response.payload.first ?? level.deviceValue
            let returnedLevel = GainLevel.from(deviceValue: returned)?.displayName ?? "未知"
            print("增益已设置：\(returnedLevel)（0x\(String(format: "%02X", returned))）")
        } else {
            // Match FxxkMoondrop: SET ACK is optional; query again for verification.
            try session.send(makePDU(feature: 0x0F, command: 0x01))
            if let response = session.waitForResponse(feature: 0x0F, command: 0x01),
               let returned = response.payload.first {
                let returnedLevel = GainLevel.from(deviceValue: returned)?.displayName ?? "未知"
                print("增益已设置并读回：\(returnedLevel)（0x\(String(format: "%02X", returned))）")
            } else {
                print("增益设置命令已发送，但设备未返回 ACK/查询结果；请听感确认")
            }
        }

    case ["voice", "get"]:
        let config = try readVoiceConfiguration(session)
        print("提示音：\(config.enabled == 1 ? "开" : "关")")
        print("提示音音量：\(config.volume)")
        print("提示音索引/语言：\(config.index)")
        print("原始值：[\(hex([config.enabled, config.volume, config.index]))]")

    case let command where command.count == 2 && command[0] == "voice" && (command[1] == "on" || command[1] == "off"):
        let old = try readVoiceConfiguration(session)
        let enabled: UInt8 = command[1] == "on" ? 1 : 0
        let payload = [enabled, old.volume, old.index]
        try session.send(makePDU(feature: 0x0E, command: 0x02, payload: payload))
        _ = session.waitForResponse(feature: 0x0E, command: 0x02, timeout: 1.5)
        print("提示音已设置：\(enabled == 1 ? "开" : "关")；保留音量 \(old.volume)、索引 \(old.index)")

    case let command where command.count == 3 && command[0] == "voice" && command[1] == "volume":
        guard let volume = UInt8(command[2]), volume <= 100 else {
            throw CLIError.message("提示音音量必须为 0...100")
        }
        let old = try readVoiceConfiguration(session)
        let payload = [old.enabled, volume, old.index]
        try session.send(makePDU(feature: 0x0E, command: 0x02, payload: payload))
        _ = session.waitForResponse(feature: 0x0E, command: 0x02, timeout: 1.5)
        print("提示音音量已设置：\(volume)；保留开关 \(old.enabled)、索引 \(old.index)")

    case let command where command.count == 3 && command[0] == "voice" && command[1] == "index":
        guard let index = UInt8(command[2]) else { throw CLIError.message("提示音索引必须为 0...255") }
        let old = try readVoiceConfiguration(session)
        let payload = [old.enabled, old.volume, index]
        try session.send(makePDU(feature: 0x0E, command: 0x02, payload: payload))
        _ = session.waitForResponse(feature: 0x0E, command: 0x02, timeout: 1.5)
        print("提示音索引已设置：\(index)；保留开关 \(old.enabled)、音量 \(old.volume)")

    case ["lhdc", "get"]:
        try session.send(makePDU(feature: 0x10, command: 0x05))
        guard let response = session.waitForResponse(feature: 0x10, command: 0x05),
              let value = response.payload.first else {
            throw CLIError.message("LHDC 查询超时（未收到 feature=0x10/cmd=5 回包）")
        }
        print("LHDC：\(value == 1 ? "开" : value == 0 ? "关" : "未知")（0x\(String(format: "%02X", value))）")

    case let command where command.count == 2 && command[0] == "lhdc" && (command[1] == "on" || command[1] == "off"):
        let enabled = command[1] == "on"
        try session.send(makePDU(feature: 0x10, command: 0x06, payload: [enabled ? 1 : 0]))
        if session.waitForResponse(feature: 0x10, command: 0x06, timeout: 1.5) == nil {
            try session.send(makePDU(feature: 0x10, command: 0x05))
            _ = session.waitForResponse(feature: 0x10, command: 0x05)
        }
        print("LHDC 设置命令已发送：\(enabled ? "开" : "关")")

    case ["led", "get"]:
        try session.send(makePDU(feature: 0x13, command: 0x01))
        guard let response = session.waitForResponse(feature: 0x13, command: 0x01),
              let value = response.payload.first else {
            throw CLIError.message("指示灯查询超时（未收到 feature=0x13/cmd=1 回包）")
        }
        print("指示灯：\(value == 1 ? "开" : value == 0 ? "关" : "未知")（0x\(String(format: "%02X", value))）")

    case let command where command.count == 2 && command[0] == "led" && (command[1] == "on" || command[1] == "off"):
        let enabled = command[1] == "on"
        try session.send(makePDU(feature: 0x13, command: 0x02, payload: [enabled ? 1 : 0]))
        if session.waitForResponse(feature: 0x13, command: 0x02, timeout: 1.5) == nil {
            try session.send(makePDU(feature: 0x13, command: 0x01))
            _ = session.waitForResponse(feature: 0x13, command: 0x01)
        }
        print("指示灯设置命令已发送：\(enabled ? "开" : "关")")

    case ["multipoint", "get"]:
        try session.send(makePDU(feature: 0x14, command: 0x01))
        guard let response = session.waitForResponse(feature: 0x14, command: 0x01),
              let value = response.payload.first else {
            throw CLIError.message("双设备连接查询超时（未收到 feature=0x14/cmd=1 回包）")
        }
        print("双设备连接：\(value == 1 ? "开" : value == 0 ? "关" : "未知")（0x\(String(format: "%02X", value))）")

    case let command where command.count == 2 && command[0] == "multipoint" && (command[1] == "on" || command[1] == "off"):
        let enabled = command[1] == "on"
        try session.send(makePDU(feature: 0x14, command: 0x02, payload: [enabled ? 1 : 0]))
        if session.waitForResponse(feature: 0x14, command: 0x02, timeout: 1.5) == nil {
            try session.send(makePDU(feature: 0x14, command: 0x01))
            guard let response = session.waitForResponse(feature: 0x14, command: 0x01),
                  let value = response.payload.first else {
                print("双设备连接设置命令已发送，但未收到 ACK/查询结果")
                return
            }
            print("双设备连接读回：\(value == 1 ? "开" : "关")（0x\(String(format: "%02X", value))）")
        } else {
            print("双设备连接已设置：\(enabled ? "开" : "关")")
        }

    case ["multipoint", "devices"]:
        for (command, slotName) in [(0x05, "当前设备"), (0x06, "下一设备")] {
            try session.send(makePDU(feature: 0x14, command: command))
            if let response = session.waitForResponse(feature: 0x14, command: command), response.payload.count >= 7 {
                let status = response.payload[0]
                let addressBytes = response.payload[1...6]
                // MIRAGE uses FF:FF:FF:FF:FF:FF for an empty multipoint slot.
                // A status byte of 0x00 is not enough to decide: the current,
                // valid device can also carry status 0x00.
                if addressBytes.allSatisfy({ $0 == 0xFF }) { continue }
                let address = addressBytes.map { String(format: "%02X", $0) }.joined(separator: ":")
                let nameBytes = response.payload.dropFirst(7)
                let name = String(bytes: nameBytes, encoding: .utf8) ?? "<invalid UTF-8>"
                print("\(slotName)：\(name) [\(address)]（状态 0x\(String(format: "%02X", status))）")
            } else {
                print("\(slotName)：未返回")
            }
        }

    case ["multipoint", "timeout"]:
        try session.send(makePDU(feature: 0x14, command: 0x03))
        guard let response = session.waitForResponse(feature: 0x14, command: 0x03),
              let value = response.payload.first else {
            throw CLIError.message("双设备连接超时配置查询失败（未收到 feature=0x14/cmd=3 回包）")
        }
        let likelyLabels = ["关闭", "5 分钟", "10 分钟", "30 分钟", "60 分钟"]
        let label = Int(value) < likelyLabels.count ? likelyLabels[Int(value)] : "未知"
        print("双设备连接超时：\(label)（原始值 \(value) / 0x\(String(format: "%02X", value))）")

    case let command where command.count == 4 && command[0] == "multipoint" && command[1] == "timeout" && command[2] == "set":
        let timeoutMap: [String: UInt8] = ["off": 0, "0": 0, "5": 1, "10": 2, "30": 3, "60": 4]
        guard let value = timeoutMap[command[3].lowercased()] else {
            throw CLIError.message("超时档位必须是 off/5/10/30/60")
        }
        try session.send(makePDU(feature: 0x14, command: 0x04, payload: [value]))
        _ = session.waitForResponse(feature: 0x14, command: 0x04, timeout: 1.5)
        print("双设备连接超时已设置：\(command[3]) 分钟（原始值 \(value)）")

    case let command where command.count == 3 && command[0] == "multipoint" && command[1] == "disconnect":
        let address = try parseBluetoothAddress(command[2])
        try session.send(makePDU(feature: 0x14, command: 0x07, payload: address))
        _ = session.waitForResponse(feature: 0x14, command: 0x07, timeout: 1.5)
        print("已发送断开设备命令：\(command[2])")

    default:
        throw CLIError.message(usage())
    }
}

do {
    try run()
} catch {
    fputs("错误：\(error)\n", stderr)
    exit(1)
}
