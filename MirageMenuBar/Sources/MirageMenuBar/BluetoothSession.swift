import Foundation
import IOBluetooth

final class BluetoothSession: NSObject, IOBluetoothRFCOMMChannelDelegate {
    private let deviceName = "MOONDROP MIRAGE"
    private let sppUUID16: BluetoothSDPUUID16 = 0x1101
    private var received: [GaiaPDU] = []
    private var framedBuffer: [UInt8] = []
    private var channel: IOBluetoothRFCOMMChannel?
    private var closed = false
    private var sdpFinished = false
    private var sdpStatus: IOReturn = kIOReturnError
    private var openFinished = false
    private var openStatus: IOReturn = kIOReturnError

    var isConnected: Bool { channel?.isOpen() == true && !closed }

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
        if chunk.count >= 4 && chunk[0] == 0x00 && chunk[1] == 0x1D {
            var boundary: Int?
            if chunk.count > 4 {
                for index in 4..<chunk.count where chunk[index] == 0xFF ||
                    (chunk[index] == 0 && index + 1 < chunk.count && chunk[index + 1] == 0x1D) {
                    boundary = index
                    break
                }
            }
            if let boundary {
                acceptPDU(Array(chunk[..<boundary]))
                framedBuffer += chunk[boundary...]
                drainFrames()
            } else {
                acceptPDU(chunk)
            }
            return
        }
        framedBuffer += chunk
        drainFrames()
    }

    @objc func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        closed = true
    }

    @objc func rfcommChannelOpenComplete(
        _ rfcommChannel: IOBluetoothRFCOMMChannel!,
        status: IOReturn
    ) {
        if status == kIOReturnSuccess { channel = rfcommChannel }
        openStatus = status
        openFinished = true
    }

    func connectIfNeeded() throws {
        if isConnected { return }
        disconnect()
        closed = false
        received.removeAll()
        framedBuffer.removeAll()

        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        guard let device = devices.first(where: {
            ($0.name ?? "").caseInsensitiveCompare(deviceName) == .orderedSame
        }) else {
            throw MirageError.message("找不到已配对设备 MOONDROP MIRAGE")
        }

        sdpFinished = false
        let result = device.performSDPQuery(self)
        guard result == kIOReturnSuccess else {
            throw MirageError.message(String(format: "启动 SDP 查询失败：0x%08X", result))
        }
        pump(until: Date().addingTimeInterval(12)) { self.sdpFinished }
        guard sdpFinished, sdpStatus == kIOReturnSuccess else {
            throw MirageError.message("SPP 服务查询失败或超时")
        }
        guard let record = device.getServiceRecord(for: IOBluetoothSDPUUID.uuid16(sppUUID16)) else {
            throw MirageError.message("设备没有公开 SPP 服务 0x1101")
        }
        var channelID: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess, channelID != 0 else {
            throw MirageError.message("无法取得 RFCOMM 通道")
        }
        try openRFCOMM(device: device, channelID: channelID)
    }

    func request(feature: Int, command: Int, payload: [UInt8] = [], timeout: TimeInterval = 3) throws -> GaiaPDU {
        try connectIfNeeded()
        let receivedCount = received.count
        try send(GaiaCodec.makePDU(feature: feature, command: command, payload: payload))
        pump(until: Date().addingTimeInterval(timeout)) {
            self.closed || self.received.dropFirst(receivedCount).contains {
                $0.feature == feature && $0.command == command
            }
        }
        guard let response = received.dropFirst(receivedCount).last(where: {
            $0.feature == feature && $0.command == command
        }) else {
            throw MirageError.message(String(format: "请求超时：feature=0x%02X cmd=0x%02X", feature, command))
        }
        return response
    }

    func sendWithoutRequiredResponse(feature: Int, command: Int, payload: [UInt8]) throws {
        try connectIfNeeded()
        try send(GaiaCodec.makePDU(feature: feature, command: command, payload: payload))
    }

    func disconnect() {
        _ = channel?.close()
        channel = nil
        closed = true
    }

    private func send(_ pdu: [UInt8]) throws {
        guard let channel, channel.isOpen() else { throw MirageError.message("RFCOMM 未连接") }
        let frame = GaiaCodec.wrapV4(pdu)
        let result = frame.withUnsafeBytes { buffer -> IOReturn in
            channel.writeSync(
                UnsafeMutableRawPointer(mutating: buffer.baseAddress!),
                length: UInt16(frame.count)
            )
        }
        guard result == kIOReturnSuccess else {
            throw MirageError.message(String(format: "RFCOMM 写入失败：0x%08X", result))
        }
    }

    private func openRFCOMM(device: IOBluetoothDevice, channelID: BluetoothRFCOMMChannelID) throws {
        var lastStatus: IOReturn = kIOReturnError
        for attempt in 0..<2 {
            openFinished = false
            openStatus = kIOReturnError
            var opened: IOBluetoothRFCOMMChannel?
            let startStatus = device.openRFCOMMChannelAsync(
                &opened,
                withChannelID: channelID,
                delegate: self
            )
            lastStatus = startStatus
            if startStatus == kIOReturnSuccess {
                // Keep the channel alive while waiting for the delegate completion.
                channel = opened
                pump(until: Date().addingTimeInterval(8)) { self.openFinished }
                if openFinished && openStatus == kIOReturnSuccess && channel?.isOpen() == true {
                    closed = false
                    return
                }
                lastStatus = openFinished ? openStatus : kIOReturnTimeout
            }
            _ = opened?.close()
            channel = nil

            // First access can finish while macOS is presenting the Bluetooth TCC prompt.
            if attempt == 0 {
                pump(until: Date().addingTimeInterval(1.5)) { false }
            }
        }
        if lastStatus == kIOReturnNotPermitted || lastStatus == kIOReturnNotPrivileged {
            throw MirageError.message("没有蓝牙权限。请在“系统设置 → 隐私与安全性 → 蓝牙”中允许 Mirage Menu Bar。")
        }
        throw MirageError.message(String(format: "打开 RFCOMM 失败：0x%08X", lastStatus))
    }

    private func acceptPDU(_ bytes: [UInt8]) {
        guard let pdu = GaiaCodec.parsePDU(bytes), pdu.vendor == GaiaCodec.vendor else { return }
        received.append(pdu)
    }

    private func drainFrames() {
        while true {
            while !framedBuffer.isEmpty && framedBuffer[0] != 0xFF { framedBuffer.removeFirst() }
            guard framedBuffer.count >= 4 else { return }
            let flags = Int(framedBuffer[2])
            let extended = Int(framedBuffer[1]) >= 4 && (flags & 0x02) != 0
            let headerLength = extended ? 5 : 4
            guard framedBuffer.count >= headerLength else { return }
            let payloadLength = extended
                ? (Int(framedBuffer[3]) << 8) | Int(framedBuffer[4])
                : Int(framedBuffer[3])
            let totalLength = headerLength + payloadLength + 4 + ((flags & 1) != 0 ? 1 : 0)
            guard framedBuffer.count >= totalLength else { return }
            acceptPDU(Array(framedBuffer[headerLength..<(headerLength + payloadLength + 4)]))
            framedBuffer.removeFirst(totalLength)
        }
    }

    private func pump(until deadline: Date, condition: () -> Bool) {
        while Date() < deadline && !condition() {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.04))
        }
    }
}
