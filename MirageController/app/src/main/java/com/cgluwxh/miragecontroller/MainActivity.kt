package com.cgluwxh.miragecontroller

import android.Manifest
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.lifecycleScope
import com.cgluwxh.miragecontroller.ui.theme.MirageControllerTheme
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private lateinit var client: MirageBluetoothClient
    private var uiState by mutableStateOf(ScreenState())
    private val permissionLauncher = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { results ->
        val bluetoothGranted = Build.VERSION.SDK_INT < 31 || results[Manifest.permission.BLUETOOTH_CONNECT] == true ||
            checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == android.content.pm.PackageManager.PERMISSION_GRANTED
        if (bluetoothGranted) refresh() else uiState = uiState.copy(error = "需要附近设备权限才能连接耳机")
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        client = MirageBluetoothClient(this)
        val excludeFromRecents = preferences().getBoolean(PREF_EXCLUDE_RECENTS, false)
        setExcludedFromRecents(excludeFromRecents, persist = false)
        uiState = uiState.copy(
            ignoringBatteryOptimizations = isIgnoringBatteryOptimizations(),
            excludeFromRecents = excludeFromRecents,
        )
        enableEdgeToEdge()
        setContent {
            MirageControllerTheme {
                Scaffold(Modifier.fillMaxSize()) { padding ->
                    MirageScreen(uiState, ::ensureBluetoothAndRefresh,
                        { action { client.setAnc(it) } },
                        { action { client.setMultipoint(it) } },
                        { action { client.setTimeout(it) } },
                        { action { client.disconnectDevice(it) } },
                        ::setBatteryOptimizationIgnored,
                        { setExcludedFromRecents(it) },
                        Modifier.padding(padding))
                }
            }
        }
        requestInitialPermissionsAndRefresh()
    }

    override fun onResume() {
        super.onResume()
        uiState = uiState.copy(ignoringBatteryOptimizations = isIgnoringBatteryOptimizations())
    }

    private fun requestInitialPermissionsAndRefresh() {
        val missing = buildList {
            if (Build.VERSION.SDK_INT >= 31 && checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != android.content.pm.PackageManager.PERMISSION_GRANTED)
                add(Manifest.permission.BLUETOOTH_CONNECT)
            if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED)
                add(Manifest.permission.POST_NOTIFICATIONS)
        }
        if (missing.isEmpty()) refresh() else permissionLauncher.launch(missing.toTypedArray())
    }

    private fun ensureBluetoothAndRefresh() {
        if (Build.VERSION.SDK_INT >= 31 && checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != android.content.pm.PackageManager.PERMISSION_GRANTED)
            permissionLauncher.launch(arrayOf(Manifest.permission.BLUETOOTH_CONNECT))
        else refresh()
    }

    private fun refresh() {
        uiState = uiState.copy(loading = true, error = null)
        lifecycleScope.launch {
            runCatching { client.refresh() }
                .onSuccess {
                    uiState = uiState.copy(loading = false, snapshot = it, error = null)
                    // Also covers installing/opening the app while the headset
                    // was already connected, so no fresh ACL broadcast occurred.
                    runCatching { MirageMonitorService.start(this@MainActivity, it.battery, it.anc) }
                }
                .onFailure { uiState = uiState.copy(loading = false, error = it.message ?: "连接失败") }
        }
    }

    private fun action(block: suspend () -> Unit) {
        uiState = uiState.copy(loading = true, error = null)
        lifecycleScope.launch {
            runCatching { block() }
                .onSuccess {
                    // Give the headset a moment to release the just-closed RFCOMM
                    // channel before the verification refresh reconnects.
                    delay(350)
                    refresh()
                }
                .onFailure { uiState = uiState.copy(loading = false, error = it.message ?: "设置失败") }
        }
    }

    private fun isIgnoringBatteryOptimizations(): Boolean =
        (getSystemService(Context.POWER_SERVICE) as PowerManager).isIgnoringBatteryOptimizations(packageName)

    private fun setBatteryOptimizationIgnored(enabled: Boolean) {
        val action = if (enabled) Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
        else Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS
        val intent = Intent(action).apply {
            if (enabled) data = Uri.parse("package:$packageName")
        }
        runCatching { startActivity(intent) }
            .onFailure { startActivity(Intent(Settings.ACTION_SETTINGS)) }
    }

    private fun setExcludedFromRecents(excluded: Boolean, persist: Boolean = true) {
        if (persist) preferences().edit().putBoolean(PREF_EXCLUDE_RECENTS, excluded).apply()
        (getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).appTasks.forEach {
            it.setExcludeFromRecents(excluded)
        }
        uiState = uiState.copy(excludeFromRecents = excluded)
    }

    private fun preferences() = getSharedPreferences("mirage_settings", Context.MODE_PRIVATE)

    private companion object { const val PREF_EXCLUDE_RECENTS = "exclude_from_recents" }
}

data class ScreenState(
    val loading: Boolean = false,
    val snapshot: DeviceSnapshot? = null,
    val error: String? = null,
    val ignoringBatteryOptimizations: Boolean = false,
    val excludeFromRecents: Boolean = false,
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MirageScreen(
    state: ScreenState,
    onRefresh: () -> Unit,
    onSetAnc: (AncMode) -> Unit,
    onSetMultipoint: (Boolean) -> Unit,
    onSetTimeout: (Int) -> Unit,
    onDisconnect: (MultipointDevice) -> Unit,
    onIgnoreBatteryOptimizations: (Boolean) -> Unit,
    onExcludeFromRecents: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    val snapshot = state.snapshot
    Column(modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text("MOONDROP MIRAGE", style = MaterialTheme.typography.headlineSmall)
        when {
            state.loading -> Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.size(20.dp)); Spacer(Modifier.width(10.dp)); Text("正在连接耳机…")
            }
            state.error != null -> Text(state.error, color = MaterialTheme.colorScheme.error)
            snapshot != null -> Text("读取完成，RFCOMM 已断开", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("电量", style = MaterialTheme.typography.titleMedium)
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Battery("左耳", snapshot?.battery?.left); Battery("右耳", snapshot?.battery?.right); Battery("充电盒", snapshot?.battery?.chargingCase)
                }
            }
        }
        SelectionField("ANC", AncMode.entries, snapshot?.anc, { it.title }, onSetAnc, !state.loading)
        Card(Modifier.fillMaxWidth()) {
            Row(Modifier.padding(16.dp).fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("双设备连接", Modifier.weight(1f), style = MaterialTheme.typography.titleMedium)
                Switch(snapshot?.multipointEnabled == true, onSetMultipoint, enabled = snapshot != null && !state.loading)
            }
        }
        val timeoutLabels = listOf("关闭", "5 分钟", "10 分钟", "30 分钟", "60 分钟")
        SelectionField("自动关闭双设备连接", timeoutLabels.indices.toList(), snapshot?.timeout?.coerceIn(timeoutLabels.indices), { timeoutLabels[it] }, onSetTimeout, !state.loading)
        Text("已连接设备", style = MaterialTheme.typography.titleMedium)
        if (snapshot?.devices.isNullOrEmpty()) Text("未返回设备", color = MaterialTheme.colorScheme.onSurfaceVariant)
        else snapshot!!.devices.forEach { device ->
            Card(Modifier.fillMaxWidth()) {
                Row(Modifier.padding(14.dp).fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(device.name)
                        Text("${device.slot} · ${device.address}", style = MaterialTheme.typography.bodySmall)
                    }
                    OutlinedButton({ onDisconnect(device) }, enabled = !state.loading) { Text("断开") }
                }
            }
        }
        Text("应用设置", style = MaterialTheme.typography.titleMedium)
        SettingSwitch(
            "忽略电池优化",
            "保证蓝牙连接广播能够启动电量通知",
            state.ignoringBatteryOptimizations,
            onIgnoreBatteryOptimizations,
        )
        SettingSwitch(
            "不在最近任务显示",
            "隐藏后仍可从桌面图标重新打开",
            state.excludeFromRecents,
            onExcludeFromRecents,
        )
        Button(onRefresh, enabled = !state.loading, modifier = Modifier.fillMaxWidth()) { Text("刷新") }
        Spacer(Modifier.height(8.dp))
    }
}

@Composable
private fun SettingSwitch(title: String, description: String, checked: Boolean, onCheckedChange: (Boolean) -> Unit) {
    Card(Modifier.fillMaxWidth()) {
        Row(Modifier.padding(16.dp).fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.titleMedium)
                Text(description, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Spacer(Modifier.width(12.dp))
            Switch(checked, onCheckedChange)
        }
    }
}

@Composable
private fun Battery(name: String, value: Int?) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(value?.let { "$it%" } ?: "—", style = MaterialTheme.typography.headlineSmall)
        Text(name, style = MaterialTheme.typography.bodySmall)
    }
}

@Composable
private fun <T> SelectionField(label: String, options: List<T>, selected: T?, title: (T) -> String, onSelected: (T) -> Unit, enabled: Boolean) {
    var expanded by remember { mutableStateOf(false) }
    Box(Modifier.fillMaxWidth()) {
        OutlinedButton(
            onClick = { expanded = true },
            enabled = enabled,
            modifier = Modifier.fillMaxWidth(),
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
        ) {
            Column(Modifier.weight(1f), horizontalAlignment = Alignment.Start) {
                Text(label, style = MaterialTheme.typography.labelSmall)
                Text(selected?.let(title) ?: "—", style = MaterialTheme.typography.bodyLarge)
            }
            Text(if (expanded) "▲" else "▼", style = MaterialTheme.typography.labelSmall)
        }
        DropdownMenu(expanded, { expanded = false }, modifier = Modifier.fillMaxWidth(0.9f)) {
            options.forEach { option -> DropdownMenuItem({ Text(title(option)) }, { expanded = false; onSelected(option) }) }
        }
    }
}
