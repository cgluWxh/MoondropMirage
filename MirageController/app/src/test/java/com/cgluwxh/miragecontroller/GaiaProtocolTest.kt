package com.cgluwxh.miragecontroller

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class GaiaProtocolTest {
    @Test
    fun batteryRequestMatchesVerifiedFrame() {
        assertArrayEquals(
            bytes("FF 04 00 02 00 1D 1A 01 01 02"),
            GaiaCodec.frame(0x0d, 0x01, byteArrayOf(0x01, 0x02)),
        )
    }

    @Test
    fun invalidCaseBatteryIsHidden() {
        val battery = BatteryLevels.parse(bytes("01 64 02 56 03 FF"))
        assertEquals(100, battery.left)
        assertEquals(86, battery.right)
        assertNull(battery.chargingCase)
    }

    @Test
    fun noiseButtonCyclesNoiseModesButEntersAtAnc() {
        assertEquals(AncMode.ANC, nextNoiseMode(AncMode.OFF))
        assertEquals(AncMode.ANC, nextNoiseMode(AncMode.TRANSPARENCY))
        assertEquals(AncMode.ADAPTIVE, nextNoiseMode(AncMode.ANC))
        assertEquals(AncMode.WIND, nextNoiseMode(AncMode.ADAPTIVE))
        assertEquals(AncMode.ANC, nextNoiseMode(AncMode.WIND))
    }

    private fun bytes(hex: String) = hex.split(" ").map { it.toInt(16).toByte() }.toByteArray()
}
