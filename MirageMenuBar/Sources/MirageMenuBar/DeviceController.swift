import Foundation

struct DeviceSnapshot {
    let battery: BatteryLevels
    let anc: AncMode?
    let multipointEnabled: Bool
    let timeout: UInt8
    let devices: [MultipointDevice]
}

final class DeviceController {
    private let queue = DispatchQueue(label: "moondrop.mirage.bluetooth", qos: .userInitiated)
    private let session = BluetoothSession()

    func readBattery(disconnectAfter: Bool, completion: @escaping (Result<BatteryLevels, Error>) -> Void) {
        queue.async {
            do {
                let response = try self.session.request(
                    feature: 0x0D,
                    command: 0x01,
                    payload: [0x01, 0x02]
                )
                let battery = BatteryLevels.parse(response.payload)
                if disconnectAfter { self.session.disconnect() }
                DispatchQueue.main.async { completion(.success(battery)) }
            } catch {
                self.session.disconnect()
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func refresh(completion: @escaping (Result<DeviceSnapshot, Error>) -> Void) {
        queue.async {
            do {
                let batteryResponse = try self.session.request(feature: 0x0D, command: 0x01, payload: [0x01, 0x02])
                let ancResponse = try self.session.request(feature: 0x20, command: 0x03)
                let stateResponse = try self.session.request(feature: 0x14, command: 0x01)
                let timeoutResponse = try self.session.request(feature: 0x14, command: 0x03)
                var devices: [MultipointDevice] = []
                for (command, slot) in [(0x05, "当前设备"), (0x06, "下一设备")] {
                    if let device = self.parseDevice(
                        try self.session.request(feature: 0x14, command: command),
                        slot: slot
                    ) {
                        devices.append(device)
                    }
                }
                let snapshot = DeviceSnapshot(
                    battery: BatteryLevels.parse(batteryResponse.payload),
                    anc: ancResponse.payload.first.flatMap(AncMode.init(rawValue:)),
                    multipointEnabled: stateResponse.payload.first == 1,
                    timeout: timeoutResponse.payload.first ?? 0,
                    devices: devices
                )
                DispatchQueue.main.async { completion(.success(snapshot)) }
            } catch {
                self.session.disconnect()
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func setANC(_ mode: AncMode, completion: @escaping (Result<Void, Error>) -> Void) {
        perform(completion) {
            try self.session.sendWithoutRequiredResponse(feature: 0x20, command: 0x04, payload: [mode.rawValue])
        }
    }

    func setMultipoint(_ enabled: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        perform(completion) {
            try self.session.sendWithoutRequiredResponse(feature: 0x14, command: 0x02, payload: [enabled ? 1 : 0])
        }
    }

    func setTimeout(_ value: UInt8, completion: @escaping (Result<Void, Error>) -> Void) {
        perform(completion) {
            try self.session.sendWithoutRequiredResponse(feature: 0x14, command: 0x04, payload: [value])
        }
    }

    func disconnectDevice(_ device: MultipointDevice, completion: @escaping (Result<Void, Error>) -> Void) {
        perform(completion) {
            try self.session.sendWithoutRequiredResponse(feature: 0x14, command: 0x07, payload: device.addressBytes)
        }
    }

    func close() { queue.async { self.session.disconnect() } }

    private func perform(_ completion: @escaping (Result<Void, Error>) -> Void, work: @escaping () throws -> Void) {
        queue.async {
            do {
                try work()
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                self.session.disconnect()
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func parseDevice(_ response: GaiaPDU, slot: String) -> MultipointDevice? {
        guard response.payload.count >= 7 else { return nil }
        let bytes = Array(response.payload[1...6])
        // MIRAGE represents an unused multipoint slot as an all-FF address.
        // The leading status byte cannot identify emptiness: a valid current
        // device has also been observed with status 0x00.
        guard !bytes.allSatisfy({ $0 == 0xFF }) else { return nil }
        let address = bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
        let name = String(bytes: response.payload.dropFirst(7), encoding: .utf8) ?? "未知设备"
        return MultipointDevice(slot: slot, status: response.payload[0], address: address, addressBytes: bytes, name: name)
    }
}
