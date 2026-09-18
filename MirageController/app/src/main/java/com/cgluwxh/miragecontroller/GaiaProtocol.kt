package com.cgluwxh.miragecontroller

data class GaiaPdu(val vendor: Int, val feature: Int, val type: Int, val command: Int, val payload: ByteArray)

enum class AncMode(val raw: Int, val title: String) {
    OFF(0, "关闭"), ADAPTIVE(1, "自适应"), TRANSPARENCY(2, "通透"), WIND(3, "抗风噪"), ANC(4, "降噪");
    companion object { fun fromRaw(value: Int?) = entries.firstOrNull { it.raw == value } }
}

fun nextNoiseMode(current: AncMode?): AncMode = when (current) {
    AncMode.ANC -> AncMode.ADAPTIVE
    AncMode.ADAPTIVE -> AncMode.WIND
    AncMode.WIND -> AncMode.ANC
    else -> AncMode.ANC
}

data class BatteryLevels(val left: Int? = null, val right: Int? = null, val chargingCase: Int? = null) {
    companion object {
        fun parse(payload: ByteArray): BatteryLevels {
            val values = mutableMapOf<Int, Int?>()
            var index = 0
            while (index + 1 < payload.size) {
                val value = payload[index + 1].toInt() and 0xff
                values[payload[index].toInt() and 0xff] = value.takeIf { it <= 100 }
                index += 2
            }
            return BatteryLevels(values[1], values[2], values[3])
        }
    }
}

data class MultipointDevice(val slot: String, val status: Int, val address: String, val addressBytes: ByteArray, val name: String)
data class DeviceSnapshot(val battery: BatteryLevels, val anc: AncMode?, val multipointEnabled: Boolean, val timeout: Int, val devices: List<MultipointDevice>)

object GaiaCodec {
    const val VENDOR = 0x001d

    fun frame(feature: Int, command: Int, payload: ByteArray = byteArrayOf()): ByteArray {
        val commandValue = (feature shl 9) or (command and 0x7f)
        val pdu = byteArrayOf((VENDOR ushr 8).toByte(), VENDOR.toByte(), (commandValue ushr 8).toByte(), commandValue.toByte()) + payload
        return byteArrayOf(0xff.toByte(), 0x04, 0x00, (pdu.size - 4).toByte()) + pdu
    }

    fun parse(bytes: ByteArray): GaiaPdu? {
        if (bytes.size < 4) return null
        val vendor = ((bytes[0].toInt() and 0xff) shl 8) or (bytes[1].toInt() and 0xff)
        val value = ((bytes[2].toInt() and 0xff) shl 8) or (bytes[3].toInt() and 0xff)
        return GaiaPdu(vendor, (value ushr 9) and 0x7f, (value ushr 7) and 3, value and 0x7f, bytes.copyOfRange(4, bytes.size))
    }
}
