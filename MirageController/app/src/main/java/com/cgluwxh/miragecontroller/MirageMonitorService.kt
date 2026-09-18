package com.cgluwxh.miragecontroller

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

class MirageMonitorService : Service() {
    private val serviceJob = SupervisorJob()
    private val scope = CoroutineScope(serviceJob + Dispatchers.IO)
    private lateinit var client: MirageBluetoothClient
    private lateinit var notifications: NotificationManager
    private var monitorJob: Job? = null
    private val bluetoothMutex = Mutex()
    private var lastBattery: BatteryLevels? = null
    private var currentAnc: AncMode? = null

    override fun onCreate() {
        super.onCreate()
        client = MirageBluetoothClient(applicationContext)
        notifications = getSystemService(NotificationManager::class.java)
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val initialBattery = batteryFrom(intent)
        if (initialBattery != null) lastBattery = initialBattery
        ancFrom(intent)?.let { currentAnc = it }
        // Android requires startForeground promptly. The same notification is
        // subsequently replaced with real battery values.
        startForeground(NOTIFICATION_ID, notification(if (lastBattery == null) "正在读取电量…" else null))

        when (intent?.action) {
            ACTION_NOISE -> scope.launch { cycleNoiseMode() }
            ACTION_TRANSPARENCY -> scope.launch { setAnc(AncMode.TRANSPARENCY) }
            ACTION_OFF -> scope.launch { setAnc(AncMode.OFF) }
        }
        if (monitorJob?.isActive != true) {
            monitorJob = scope.launch {
                if (lastBattery != null) delay(REFRESH_INTERVAL_MS)
                while (isActive) {
                    updateState()
                    delay(REFRESH_INTERVAL_MS)
                }
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        serviceJob.cancel()
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private suspend fun updateState() {
        // Re-post first as some customized systems allow an ongoing foreground
        // notification to be dismissed by the user.
        notifications.notify(NOTIFICATION_ID, notification())
        try {
            val (battery, anc) = bluetoothMutex.withLock { client.readBatteryAndAnc() }
            lastBattery = battery
            currentAnc = anc
            notifications.notify(NOTIFICATION_ID, notification())
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            // Keep the last known connection notification and retry at the next
            // interval; do not spin or hold a failed RFCOMM connection.
            notifications.notify(NOTIFICATION_ID, notification("电量读取失败，稍后重试"))
        }
    }

    private suspend fun setAnc(mode: AncMode) {
        try {
            bluetoothMutex.withLock { client.setAnc(mode) }
            currentAnc = mode
            notifications.notify(NOTIFICATION_ID, notification())
        } catch (error: CancellationException) {
            throw error
        } catch (_: Throwable) {
            notifications.notify(NOTIFICATION_ID, notification("ANC 切换失败"))
        }
    }

    private suspend fun cycleNoiseMode() {
        try {
            currentAnc = bluetoothMutex.withLock { client.cycleNoiseMode() }
            notifications.notify(NOTIFICATION_ID, notification())
        } catch (error: CancellationException) {
            throw error
        } catch (_: Throwable) {
            notifications.notify(NOTIFICATION_ID, notification("ANC 切换失败"))
        }
    }

    private fun notification(message: String? = null): Notification {
        val openApp = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(Intent.ACTION_MAIN).setPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(
            this, 0, openApp,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL_ID) else Notification.Builder(this)
        return builder
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentTitle("MOONDROP MIRAGE")
            .setContentText(message ?: lastBattery?.let(::batteryText) ?: "正在读取电量…")
            .setSubText(currentAnc?.let { "当前：${it.title}" } ?: "已连接")
            .setContentIntent(pendingIntent)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_STATUS)
            .addAction(notificationAction("降噪", ACTION_NOISE, 1))
            .addAction(notificationAction("通透", ACTION_TRANSPARENCY, 2))
            .addAction(notificationAction("关闭", ACTION_OFF, 3))
            .build()
    }

    private fun notificationAction(title: String, action: String, requestCode: Int): Notification.Action {
        val intent = Intent(this, MirageMonitorService::class.java).setAction(action)
        val pendingIntent = if (Build.VERSION.SDK_INT >= 26) {
            PendingIntent.getForegroundService(this, requestCode, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        } else {
            PendingIntent.getService(this, requestCode, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }
        return Notification.Action.Builder(0, title, pendingIntent).build()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        val channel = NotificationChannel(CHANNEL_ID, "耳机电量", NotificationManager.IMPORTANCE_LOW).apply {
            description = "MOONDROP MIRAGE 连接期间显示电量"
            setShowBadge(false)
            enableVibration(false)
            setSound(null, null)
        }
        notifications.createNotificationChannel(channel)
    }

    private fun stopSelfAndRemoveNotification() {
        monitorJob?.cancel()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun percent(value: Int?) = value?.let { "$it%" } ?: "—"
    private fun batteryText(battery: BatteryLevels) =
        "左 ${percent(battery.left)}  ·  右 ${percent(battery.right)}  ·  盒 ${percent(battery.chargingCase)}"

    private fun batteryFrom(intent: Intent?): BatteryLevels? {
        if (intent?.hasExtra(EXTRA_LEFT) != true) return null
        fun value(key: String) = intent.getIntExtra(key, -1).takeIf { it in 0..100 }
        return BatteryLevels(value(EXTRA_LEFT), value(EXTRA_RIGHT), value(EXTRA_CASE))
    }

    private fun ancFrom(intent: Intent?): AncMode? =
        intent?.getIntExtra(EXTRA_ANC, -1)?.takeIf { it >= 0 }?.let(AncMode::fromRaw)

    companion object {
        private const val ACTION_START = "com.cgluwxh.miragecontroller.START_MONITOR"
        private const val ACTION_NOISE = "com.cgluwxh.miragecontroller.ANC_NOISE"
        private const val ACTION_TRANSPARENCY = "com.cgluwxh.miragecontroller.ANC_TRANSPARENCY"
        private const val ACTION_OFF = "com.cgluwxh.miragecontroller.ANC_OFF"
        private const val CHANNEL_ID = "mirage_battery"
        private const val NOTIFICATION_ID = 1001
        private const val REFRESH_INTERVAL_MS = 10 * 60 * 1000L
        private const val EXTRA_LEFT = "left"
        private const val EXTRA_RIGHT = "right"
        private const val EXTRA_CASE = "case"
        private const val EXTRA_ANC = "anc"

        fun start(context: Context, battery: BatteryLevels? = null, anc: AncMode? = null) {
            val intent = Intent(context, MirageMonitorService::class.java).setAction(ACTION_START).apply {
                battery?.left?.let { putExtra(EXTRA_LEFT, it) }
                battery?.right?.let { putExtra(EXTRA_RIGHT, it) }
                battery?.chargingCase?.let { putExtra(EXTRA_CASE, it) }
                anc?.let { putExtra(EXTRA_ANC, it.raw) }
            }
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, MirageMonitorService::class.java))
        }
    }
}
