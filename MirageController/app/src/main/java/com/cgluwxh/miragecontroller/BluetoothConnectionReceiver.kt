package com.cgluwxh.miragecontroller

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

class BluetoothConnectionReceiver : BroadcastReceiver() {
    @SuppressLint("MissingPermission")
    override fun onReceive(context: Context, intent: Intent) {
        val device = if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
        } ?: return

        if (!device.name.equals(DEVICE_NAME, ignoreCase = true)) return
        when (intent.action) {
            BluetoothDevice.ACTION_ACL_CONNECTED -> runCatching { MirageMonitorService.start(context) }
            BluetoothDevice.ACTION_ACL_DISCONNECTED -> MirageMonitorService.stop(context)
        }
    }

    private companion object { const val DEVICE_NAME = "MOONDROP MIRAGE" }
}
