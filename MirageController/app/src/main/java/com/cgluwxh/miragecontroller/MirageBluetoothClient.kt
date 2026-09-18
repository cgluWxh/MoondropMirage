package com.cgluwxh.miragecontroller

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.util.UUID

class MirageBluetoothClient(context: Context) {
    private val adapter: BluetoothAdapter? = (context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter

    companion object {
        private const val DEVICE_NAME = "MOONDROP MIRAGE"
        private val SPP_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
    }

    suspend fun refresh(): DeviceSnapshot = withSocket { socket ->
        val battery = readBattery(socket)
        val anc = readAnc(socket)
        val enabled = request(socket, 0x14, 0x01).payload.firstOrNull()?.toInt() == 1
        val timeout = request(socket, 0x14, 0x03).payload.firstOrNull()?.toInt()?.and(0xff) ?: 0
        val devices = listOfNotNull(parseDevice(request(socket, 0x14, 0x05), "当前设备"), parseDevice(request(socket, 0x14, 0x06), "下一设备"))
        DeviceSnapshot(battery, anc, enabled, timeout, devices)
    }

    suspend fun readBattery(): BatteryLevels = withSocket(::readBattery)
    suspend fun readBatteryAndAnc(): Pair<BatteryLevels, AncMode?> = withSocket { socket ->
        readBattery(socket) to readAnc(socket)
    }

    suspend fun setAnc(mode: AncMode) = send(0x20, 0x04, byteArrayOf(mode.raw.toByte()))
    suspend fun cycleNoiseMode(): AncMode = withSocket { socket ->
        val target = nextNoiseMode(readAnc(socket))
        send(socket, 0x20, 0x04, byteArrayOf(target.raw.toByte()))
        target
    }
    suspend fun setMultipoint(enabled: Boolean) = send(0x14, 0x02, byteArrayOf(if (enabled) 1 else 0))
    suspend fun setTimeout(value: Int) = send(0x14, 0x04, byteArrayOf(value.toByte()))
    suspend fun disconnectDevice(device: MultipointDevice) = send(0x14, 0x07, device.addressBytes)

    private suspend fun readBattery(socket: BluetoothSocket) =
        BatteryLevels.parse(request(socket, 0x0d, 0x01, byteArrayOf(0x01, 0x02)).payload)

    private suspend fun readAnc(socket: BluetoothSocket) =
        AncMode.fromRaw(request(socket, 0x20, 0x03).payload.firstOrNull()?.toInt()?.and(0xff))

    private suspend fun send(feature: Int, command: Int, payload: ByteArray) = withSocket { socket ->
        send(socket, feature, command, payload)
    }

    private suspend fun send(socket: BluetoothSocket, feature: Int, command: Int, payload: ByteArray) {
        socket.outputStream.write(GaiaCodec.frame(feature, command, payload))
        socket.outputStream.flush()
        delay(180)
    }

    @SuppressLint("MissingPermission")
    private suspend fun <T> withSocket(block: suspend (BluetoothSocket) -> T): T = withContext(Dispatchers.IO) {
        val bluetooth = adapter ?: error("此设备不支持蓝牙")
        check(bluetooth.isEnabled) { "请先开启蓝牙" }
        val device = bluetooth.bondedDevices.firstOrNull { it.name.equals(DEVICE_NAME, ignoreCase = true) }
            ?: error("找不到已配对设备 $DEVICE_NAME")
        val socket = device.createRfcommSocketToServiceRecord(SPP_UUID)
        try { socket.connect(); block(socket) } finally { runCatching { socket.close() } }
    }

    private suspend fun request(socket: BluetoothSocket, feature: Int, command: Int, payload: ByteArray = byteArrayOf()): GaiaPdu {
        socket.outputStream.write(GaiaCodec.frame(feature, command, payload)); socket.outputStream.flush()
        val deadline = System.currentTimeMillis() + 3_000
        val buffer = ByteArrayOutputStream()
        val chunk = ByteArray(512)
        while (System.currentTimeMillis() < deadline) {
            val available = socket.inputStream.available()
            if (available == 0) { delay(20); continue }
            val count = socket.inputStream.read(chunk, 0, minOf(chunk.size, available))
            if (count > 0) buffer.write(chunk, 0, count)
            drainFrames(buffer.toByteArray()).lastOrNull { it.feature == feature && it.command == command }?.let { return it }
        }
        error("请求超时：feature=0x${feature.toString(16)} cmd=0x${command.toString(16)}")
    }

    private fun drainFrames(bytes: ByteArray): List<GaiaPdu> {
        val result = mutableListOf<GaiaPdu>(); var offset = 0
        while (offset < bytes.size) {
            while (offset < bytes.size && (bytes[offset].toInt() and 0xff) != 0xff) offset++
            if (offset + 4 > bytes.size) break
            val flags = bytes[offset + 2].toInt() and 0xff
            val extended = (flags and 2) != 0
            val headerSize = if (extended) 5 else 4
            if (offset + headerSize > bytes.size) break
            val payloadSize = if (extended) ((bytes[offset + 3].toInt() and 0xff) shl 8) or (bytes[offset + 4].toInt() and 0xff) else bytes[offset + 3].toInt() and 0xff
            val pduSize = payloadSize + 4
            val totalSize = headerSize + pduSize + if ((flags and 1) != 0) 1 else 0
            if (offset + totalSize > bytes.size) break
            GaiaCodec.parse(bytes.copyOfRange(offset + headerSize, offset + headerSize + pduSize))?.takeIf { it.vendor == GaiaCodec.VENDOR }?.let(result::add)
            offset += totalSize
        }
        return result
    }

    private fun parseDevice(response: GaiaPdu, slot: String): MultipointDevice? {
        if (response.payload.size < 7) return null
        val addressBytes = response.payload.copyOfRange(1, 7)
        if (addressBytes.all { (it.toInt() and 0xff) == 0xff }) return null
        val address = addressBytes.joinToString(":") { "%02X".format(it.toInt() and 0xff) }
        val name = response.payload.copyOfRange(7, response.payload.size).toString(Charsets.UTF_8).ifBlank { "未知设备" }
        return MultipointDevice(slot, response.payload[0].toInt() and 0xff, address, addressBytes, name)
    }
}
