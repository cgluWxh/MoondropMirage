import AppKit
import IOBluetooth
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let controller = DeviceController()
    private let popover = NSPopover()
    private let content = PopoverViewController()
    private var statusItem: NSStatusItem!
    private var eventMonitor: Any?
    private var disconnectWorkItem: DispatchWorkItem?
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotification: IOBluetoothUserNotification?
    private var batteryTimer: Timer?
    private var suppressConnectEventsUntil = Date.distantPast
    private var pendingConnectionRead: DispatchWorkItem?
    private var temporaryVisibilityWorkItem: DispatchWorkItem?
    private var showBatteryInMenuBar = true
    private let menuBarBatteryDefaultsKey = "showBatteryInMenuBar"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let defaults = UserDefaults.standard
        showBatteryInMenuBar = defaults.object(forKey: menuBarBatteryDefaultsKey) == nil
            ? true
            : defaults.bool(forKey: menuBarBatteryDefaultsKey)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "headphones", accessibilityDescription: "MOONDROP MIRAGE")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.title = showBatteryInMenuBar ? " —" : ""
            button.target = self
            button.action = #selector(togglePopover)
        }
        let initiallyConnected = targetDeviceIsConnected()
        updateConnectionAppearance(connected: initiallyConnected)
        statusItem.isVisible = initiallyConnected
        if !initiallyConnected { showTemporaryStatusItem() }

        popover.contentViewController = content
        popover.behavior = .transient
        popover.delegate = self

        content.onRefresh = { [weak self] in self?.refresh() }
        content.onSetANC = { [weak self] mode in
            self?.perform { completion in self?.controller.setANC(mode, completion: completion) }
        }
        content.onSetMultipoint = { [weak self] enabled in
            self?.perform { completion in self?.controller.setMultipoint(enabled, completion: completion) }
        }
        content.onSetTimeout = { [weak self] timeout in
            self?.perform { completion in self?.controller.setTimeout(timeout, completion: completion) }
        }
        content.onDisconnectDevice = { [weak self] device in self?.confirmDisconnect(device) }
        content.onSetMenuBarBattery = { [weak self] enabled in self?.setMenuBarBattery(enabled) }
        content.onQuit = { NSApp.terminate(nil) }
        content.setMenuBarBatteryEnabled(showBatteryInMenuBar)

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if self?.popover.isShown == true { self?.popover.performClose(nil) }
        }
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(bluetoothDeviceConnected(_:device:))
        )
        registerDisconnectNotification()
        requestNotificationPermission()
        startBatteryTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        disconnectWorkItem?.cancel()
        pendingConnectionRead?.cancel()
        temporaryVisibilityWorkItem?.cancel()
        batteryTimer?.invalidate()
        connectNotification?.unregister()
        disconnectNotification?.unregister()
        controller.close()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }

    func popoverDidClose(_ notification: Notification) {
        scheduleDisconnect()
        scheduleVisibilityUpdateAfterPopover()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !targetDeviceIsConnected() { showTemporaryStatusItem() }
        return true
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            temporaryVisibilityWorkItem?.cancel()
            temporaryVisibilityWorkItem = nil
            statusItem.isVisible = true
            disconnectWorkItem?.cancel()
            disconnectWorkItem = nil
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            refresh()
        }
    }

    private func refresh() {
        markAppInitiatedBluetoothWork()
        content.showLoading()
        controller.refresh { [weak self] result in
            switch result {
            case .success(let snapshot):
                self?.content.show(snapshot: snapshot)
                self?.updateStatusBattery(snapshot.battery)
                self?.updateConnectionAppearance(connected: true)
            case .failure(let error):
                self?.content.show(error: error)
                self?.statusItem.button?.title = self?.showBatteryInMenuBar == true ? " !" : ""
            }
        }
    }

    private func perform(_ action: (@escaping (Result<Void, Error>) -> Void) -> Void) {
        markAppInitiatedBluetoothWork()
        content.showLoading("正在发送设置…")
        action { [weak self] result in
            switch result {
            case .success:
                self?.content.showActionCompleted()
                self?.refresh()
            case .failure(let error): self?.content.show(error: error)
            }
        }
    }

    private func confirmDisconnect(_ device: MultipointDevice) {
        let alert = NSAlert()
        alert.messageText = "断开 \(device.name)？"
        alert.informativeText = device.address
        alert.alertStyle = .warning
        alert.addButton(withTitle: "断开")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform { [weak self] completion in
            self?.controller.disconnectDevice(device, completion: completion)
        }
    }

    private func updateStatusBattery(_ battery: BatteryLevels) {
        guard showBatteryInMenuBar else {
            statusItem.button?.title = ""
            return
        }
        let available = [battery.left, battery.right].compactMap { $0 }
        statusItem.button?.title = available.min().map { " \($0)%" } ?? " —"
    }

    private func scheduleDisconnect() {
        disconnectWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.controller.close()
            self?.disconnectWorkItem = nil
        }
        disconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: workItem)
    }

    @objc private func bluetoothDeviceConnected(
        _ notification: IOBluetoothUserNotification,
        device: IOBluetoothDevice
    ) {
        guard (device.name ?? "").caseInsensitiveCompare("MOONDROP MIRAGE") == .orderedSame else { return }
        temporaryVisibilityWorkItem?.cancel()
        temporaryVisibilityWorkItem = nil
        statusItem.isVisible = true
        updateConnectionAppearance(connected: true)
        registerDisconnectNotification(for: device)
        guard showBatteryInMenuBar else { return }
        guard Date() >= suppressConnectEventsUntil else { return }

        // Let A2DP/HFP and the earbud's SPP service settle before opening GAIA.
        pendingConnectionRead?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.readBatteryAfterConnection()
        }
        pendingConnectionRead = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: workItem)
    }

    private func readBatteryAfterConnection() {
        markAppInitiatedBluetoothWork()
        controller.readBattery(disconnectAfter: !popover.isShown) { [weak self] result in
            guard let self else { return }
            if case .success(let battery) = result {
                updateStatusBattery(battery)
                sendBatteryNotification(battery)
                if popover.isShown { refresh() }
            }
        }
    }

    private func startBatteryTimer() {
        batteryTimer?.invalidate()
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: true) { [weak self] _ in
            self?.performPeriodicBatteryRead()
        }
        if let batteryTimer { RunLoop.main.add(batteryTimer, forMode: .common) }
    }

    private func performPeriodicBatteryRead() {
        guard showBatteryInMenuBar else { return }
        // Do not wake or reconnect earbuds that are not currently connected
        // to macOS; the periodic task only refreshes an active headset.
        guard targetDeviceIsConnected() else { return }
        markAppInitiatedBluetoothWork()
        controller.readBattery(disconnectAfter: !popover.isShown) { [weak self] result in
            guard let self else { return }
            if case .success(let battery) = result {
                updateStatusBattery(battery)
                if popover.isShown { refresh() }
            }
        }
    }

    private func markAppInitiatedBluetoothWork() {
        // Opening our own RFCOMM/baseband connection can itself produce an
        // IOBluetooth connect callback. Do not treat that as a headset event.
        suppressConnectEventsUntil = Date().addingTimeInterval(20)
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func sendBatteryNotification(_ battery: BatteryLevels) {
        let content = UNMutableNotificationContent()
        content.title = "MOONDROP MIRAGE 已连接"
        content.body = "左耳 \(batteryText(battery.left)) · 右耳 \(batteryText(battery.right)) · 充电盒 \(batteryText(battery.chargingCase))"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "mirage-connected-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func batteryText(_ value: UInt8?) -> String {
        value.map { "\($0)%" } ?? "不可用"
    }

    private func targetDeviceIsConnected() -> Bool {
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return devices.contains {
            ($0.name ?? "").caseInsensitiveCompare("MOONDROP MIRAGE") == .orderedSame && $0.isConnected()
        }
    }

    private func setMenuBarBattery(_ enabled: Bool) {
        showBatteryInMenuBar = enabled
        UserDefaults.standard.set(enabled, forKey: menuBarBatteryDefaultsKey)
        content.setMenuBarBatteryEnabled(enabled)
        if enabled {
            statusItem.button?.title = " —"
            if targetDeviceIsConnected() { performPeriodicBatteryRead() }
        } else {
            pendingConnectionRead?.cancel()
            pendingConnectionRead = nil
            statusItem.button?.title = ""
        }
    }

    private func registerDisconnectNotification() {
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        guard let device = devices.first(where: {
            ($0.name ?? "").caseInsensitiveCompare("MOONDROP MIRAGE") == .orderedSame
        }) else { return }
        registerDisconnectNotification(for: device)
    }

    private func registerDisconnectNotification(for device: IOBluetoothDevice) {
        disconnectNotification?.unregister()
        disconnectNotification = device.register(
            forDisconnectNotification: self,
            selector: #selector(bluetoothDeviceDisconnected(_:device:))
        )
    }

    @objc private func bluetoothDeviceDisconnected(
        _ notification: IOBluetoothUserNotification,
        device: IOBluetoothDevice
    ) {
        guard (device.name ?? "").caseInsensitiveCompare("MOONDROP MIRAGE") == .orderedSame else { return }
        pendingConnectionRead?.cancel()
        pendingConnectionRead = nil
        statusItem.button?.title = showBatteryInMenuBar ? " —" : ""
        updateConnectionAppearance(connected: false)
        statusItem.isVisible = popover.isShown
        if popover.isShown {
            content.show(error: MirageError.message("耳机已断开"))
        }
    }

    private func updateConnectionAppearance(connected: Bool) {
        guard let button = statusItem.button else { return }
        if connected {
            let image = NSImage(systemSymbolName: "headphones", accessibilityDescription: "MOONDROP MIRAGE 已连接")
            image?.isTemplate = true
            button.image = image
            // Let NSStatusBar choose the correct light/dark/highlight color.
            button.contentTintColor = nil
        } else {
            let inactiveColor = NSColor.secondaryLabelColor.withAlphaComponent(0.38)
            let configuration = NSImage.SymbolConfiguration(paletteColors: [inactiveColor])
            let image = NSImage(
                systemSymbolName: "headphones",
                accessibilityDescription: "MOONDROP MIRAGE 已断开"
            )?.withSymbolConfiguration(configuration)
            image?.isTemplate = false
            button.image = image
            button.contentTintColor = nil
        }
        button.toolTip = connected ? "MOONDROP MIRAGE 已连接" : "MOONDROP MIRAGE 已断开"
    }

    private func showTemporaryStatusItem() {
        temporaryVisibilityWorkItem?.cancel()
        statusItem.isVisible = true
        updateConnectionAppearance(connected: false)
        statusItem.button?.title = showBatteryInMenuBar ? " —" : ""

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !popover.isShown, !targetDeviceIsConnected() else { return }
            statusItem.isVisible = false
            temporaryVisibilityWorkItem = nil
        }
        temporaryVisibilityWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: workItem)
    }

    private func scheduleVisibilityUpdateAfterPopover() {
        temporaryVisibilityWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            statusItem.isVisible = targetDeviceIsConnected()
            temporaryVisibilityWorkItem = nil
        }
        temporaryVisibilityWorkItem = workItem
        // The RFCOMM grace period is 10 seconds; evaluate after it is closed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 11, execute: workItem)
    }
}
