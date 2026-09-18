import AppKit

final class PopoverViewController: NSViewController {
    var onRefresh: (() -> Void)?
    var onSetANC: ((AncMode) -> Void)?
    var onSetMultipoint: ((Bool) -> Void)?
    var onSetTimeout: ((UInt8) -> Void)?
    var onDisconnectDevice: ((MultipointDevice) -> Void)?
    var onSetMenuBarBattery: ((Bool) -> Void)?
    var onQuit: (() -> Void)?

    private let statusLabel = NSTextField(labelWithString: "准备就绪")
    private let batteryLabel = NSTextField(labelWithString: "左耳 —   右耳 —   充电盒 —")
    private let ancPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let multipointSwitch = NSSwitch()
    private let timeoutPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let menuBarBatterySwitch = NSSwitch()
    private let devicesStack = NSStackView()
    private let refreshButton = NSButton(title: "刷新", target: nil, action: nil)
    private var displayedDevices: [MultipointDevice] = []
    private var updatingControls = false

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.widthAnchor.constraint(equalToConstant: 340).isActive = true

        let title = NSTextField(labelWithString: "MOONDROP MIRAGE")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let quitButton = NSButton(title: "退出", target: self, action: #selector(quitPressed))
        quitButton.bezelStyle = .inline
        let header = NSStackView(views: [title, NSView(), quitButton])
        header.orientation = .horizontal
        header.alignment = .centerY

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail

        batteryLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)

        AncMode.allCases.forEach { ancPopup.addItem(withTitle: $0.title) }
        ancPopup.target = self
        ancPopup.action = #selector(ancChanged)

        multipointSwitch.target = self
        multipointSwitch.action = #selector(multipointChanged)

        ["关闭", "5 分钟", "10 分钟", "30 分钟", "60 分钟"].forEach(timeoutPopup.addItem)
        timeoutPopup.target = self
        timeoutPopup.action = #selector(timeoutChanged)

        menuBarBatterySwitch.target = self
        menuBarBatterySwitch.action = #selector(menuBarBatteryChanged)

        devicesStack.orientation = .vertical
        devicesStack.alignment = .leading
        devicesStack.spacing = 8

        refreshButton.target = self
        refreshButton.action = #selector(refreshPressed)
        refreshButton.bezelStyle = .rounded

        let content = NSStackView(views: [
            header,
            statusLabel,
            separator(),
            sectionTitle("电量"),
            batteryLabel,
            separator(),
            formRow("ANC", ancPopup),
            separator(),
            formRow("双设备连接", multipointSwitch),
            formRow("自动关闭", timeoutPopup),
            sectionTitle("已连接设备"),
            devicesStack,
            separator(),
            formRow("菜单栏显示电量", menuBarBatterySwitch),
            separator(),
            refreshButton,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            refreshButton.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
        view = root
    }

    func showLoading(_ text: String = "正在连接耳机…") {
        statusLabel.stringValue = text
        refreshButton.isEnabled = false
    }

    func show(snapshot: DeviceSnapshot) {
        updatingControls = true
        defer { updatingControls = false }
        statusLabel.stringValue = "已连接"
        statusLabel.textColor = .secondaryLabelColor
        refreshButton.isEnabled = true
        batteryLabel.stringValue = "左耳 \(percent(snapshot.battery.left))   右耳 \(percent(snapshot.battery.right))   充电盒 \(percent(snapshot.battery.chargingCase))"
        if let anc = snapshot.anc, let index = AncMode.allCases.firstIndex(of: anc) {
            ancPopup.selectItem(at: index)
        }
        multipointSwitch.state = snapshot.multipointEnabled ? .on : .off
        timeoutPopup.selectItem(at: min(Int(snapshot.timeout), timeoutPopup.numberOfItems - 1))
        renderDevices(snapshot.devices)
    }

    func show(error: Error) {
        statusLabel.stringValue = error.localizedDescription
        statusLabel.textColor = .systemRed
        refreshButton.isEnabled = true
    }

    func showActionCompleted() {
        statusLabel.stringValue = "设置已发送，正在刷新…"
        statusLabel.textColor = .secondaryLabelColor
    }

    func setMenuBarBatteryEnabled(_ enabled: Bool) {
        updatingControls = true
        menuBarBatterySwitch.state = enabled ? .on : .off
        updatingControls = false
    }

    @objc private func refreshPressed() { onRefresh?() }
    @objc private func quitPressed() { onQuit?() }

    @objc private func ancChanged() {
        guard !updatingControls, ancPopup.indexOfSelectedItem >= 0 else { return }
        onSetANC?(AncMode.allCases[ancPopup.indexOfSelectedItem])
    }

    @objc private func multipointChanged() {
        guard !updatingControls else { return }
        onSetMultipoint?(multipointSwitch.state == .on)
    }

    @objc private func timeoutChanged() {
        guard !updatingControls, timeoutPopup.indexOfSelectedItem >= 0 else { return }
        onSetTimeout?(UInt8(timeoutPopup.indexOfSelectedItem))
    }

    @objc private func menuBarBatteryChanged() {
        guard !updatingControls else { return }
        onSetMenuBarBattery?(menuBarBatterySwitch.state == .on)
    }

    @objc private func disconnectPressed(_ sender: NSButton) {
        guard displayedDevices.indices.contains(sender.tag) else { return }
        onDisconnectDevice?(displayedDevices[sender.tag])
    }

    private func renderDevices(_ devices: [MultipointDevice]) {
        displayedDevices = devices
        devicesStack.arrangedSubviews.forEach { view in
            devicesStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard !devices.isEmpty else {
            let empty = NSTextField(labelWithString: "未返回设备")
            empty.textColor = .secondaryLabelColor
            devicesStack.addArrangedSubview(empty)
            return
        }
        for (index, device) in devices.enumerated() {
            let name = NSTextField(labelWithString: device.name)
            name.lineBreakMode = .byTruncatingTail
            name.toolTip = "\(device.slot) · \(device.address)"
            let button = NSButton(title: "断开", target: self, action: #selector(disconnectPressed(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            let row = NSStackView(views: [name, NSView(), button])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.widthAnchor.constraint(equalToConstant: 308).isActive = true
            devicesStack.addArrangedSubview(row)
        }
    }

    private func formRow(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        let row = NSStackView(views: [label, NSView(), control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.widthAnchor.constraint(equalToConstant: 308).isActive = true
        return row
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        return label
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 308).isActive = true
        return box
    }

    private func percent(_ value: UInt8?) -> String { value.map { "\($0)%" } ?? "—" }
}
