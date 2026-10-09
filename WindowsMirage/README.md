# MOONDROP MIRAGE Windows Python 测试版

这是独立测试项目，不修改 macOS CLI。目标系统为 Windows 10/11 x64，建议使用 **Python 3.12 x64**。

## 已包含

- Windows 系统蓝牙连接/断开事件监听，不靠轮询。
- 托盘图标和小型控制窗口。
- 电量读取。
- ANC 查询与五档切换。
- 双设备开关、自动关闭时间、两个设备槽位和按 MAC 断开。
- 打开窗口时才建立 SPP/RFCOMM；关闭窗口 5 秒后断开，期间重新打开会取消断开。
- 原始 GAIA TX/RX 日志写入 `windows-mirage.log`。

## 第一次运行

1. 在 Windows 设置中配对并连接名称严格为 `MOONDROP MIRAGE` 的耳机。
2. 从 python.org 安装 Python 3.12 x64，并勾选 Python Launcher。
3. 双击 `setup.bat` 安装隔离环境和依赖。
4. 双击 `start.bat`。
5. 程序启动后进入系统托盘；右键图标选择“打开控制面板”。

## 一次性 CLI（不启动托盘或 Tkinter）

在 Windows 中配对并连接耳机、安装依赖后，在此目录运行：

```bat
cli.bat --anc noise-cancelling
cli.bat --anc adaptive
cli.bat --anc wind-reduction
cli.bat --anc transparency
cli.bat --anc off
cli.bat --multipoint on
cli.bat --multipoint off
cli.bat --anc transparency --multipoint on
```

也可以直接使用 `python mirage_cli.py` 加相同参数。`--help` 查看帮助，`--timeout 60` 设置连接和操作（包括初始化）的总超时秒数（默认 45），`--verbose` 显示协议日志及各阶段耗时。

### Windows 连接速度优化

默认只枚举已配对设备；SPP 服务优先读取 Windows 缓存，缓存未命中才执行无缓存发现。首次发现或 Windows 蓝牙栈响应慢时仍可能需要较长时间，默认超时提高并不代表操作会固定等待 45 秒。

如果设备枚举较慢，可显式指定耳机蓝牙地址来跳过枚举（替换下面的示例地址）：

```bat
cli.bat --address AA:BB:CC:DD:EE:FF --anc transparency --verbose
```

先运行 `cli.bat --anc off --verbose`，日志会显示真实地址，以及设备枚举、打开 BluetoothDevice、SPP 查询和 RFCOMM 连接分别花了多少秒。指定地址只能跳过枚举；如果慢在 Windows 打开设备或建立连接，仍需要进一步排查蓝牙栈。

每次执行仅建立临时 RFCOMM 控制连接，发送指定设置后立即释放并退出，不启动后台常驻程序，不断开 Windows 的耳机音频连接。发送后保留与 GUI 一致的 0.3 秒处理时间；成功表示指令已发送，不代表已读取设备状态确认。至少需要指定一个设置；退出码：成功 `0`，操作失败 `1`，参数错误 `2`，取消 `130`。同时设置时先调整 ANC，再调整双设备开关，失败不会回滚已发送的设置。

建议先退出托盘控制器，避免两个程序同时占用 RFCOMM。蓝牙实际切换效果仍需 Windows 真机验证。

## 反馈测试结果

如果运行失败，请把以下内容发回来：

- 命令窗口里的完整错误。
- 同目录生成的 `windows-mirage.log`。
- Windows 版本和 Python 版本（运行 `py -3.12 --version`）。

## 当前风险

此代码已在 macOS 上完成 Python 语法和协议单元测试，但无法在本机加载 Windows WinRT DLL，因此以下部分需要你的 Windows 真机确认：

- PyWinRT 3.2.1 的 SPP 服务枚举及 `StreamSocket` 调用。
- MIRAGE 在 Windows 蓝牙栈下公开的 SPP 服务。
- WinRT `DataReader` 对 RFCOMM 分包的实际行为。

测试阶段暂不制作 PyInstaller 单文件；先保证 WinRT 和真机通信正确，再封装 EXE。
