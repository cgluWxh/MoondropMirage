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
