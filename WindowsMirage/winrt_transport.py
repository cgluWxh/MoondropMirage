from __future__ import annotations

import asyncio
import logging
from time import perf_counter
from collections.abc import Callable
from contextlib import suppress

from protocol import GaiaFrameParser, GaiaPDU, make_pdu, wrap_v4

try:
    from winrt.windows.devices.bluetooth import (
        BluetoothCacheMode,
        BluetoothConnectionStatus,
        BluetoothDevice,
    )
    from winrt.windows.devices.bluetooth.rfcomm import RfcommServiceId
    from winrt.windows.devices.enumeration import DeviceInformation
    from winrt.windows.networking.sockets import StreamSocket
    from winrt.windows.storage.streams import DataReader, DataWriter, InputStreamOptions
except ImportError as exc:  # Gives a useful error when setup.bat was not run.
    raise RuntimeError("PyWinRT 未安装，请先运行 setup.bat") from exc

LOG = logging.getLogger("mirage.transport")
DEVICE_NAME = "MOONDROP MIRAGE"


class MirageTransport:
    def __init__(self, connection_callback: Callable[[bool, str], None]) -> None:
        self.connection_callback = connection_callback
        self.device = None
        self.connection_token = None
        self.socket = None
        self.reader = None
        self.writer = None
        self.parser = GaiaFrameParser()
        self.request_lock = asyncio.Lock()
        self.disconnect_task: asyncio.Task | None = None

    async def initialize(self, address: int | None = None) -> None:
        if self.device is not None:
            return
        started = perf_counter()
        if address is None:
            LOG.info("枚举已配对的蓝牙设备…")
            selector = BluetoothDevice.get_device_selector_from_pairing_state(True)
            devices = await DeviceInformation.find_all_async_aqs_filter(selector)
            matches = [device for device in devices if device.name == DEVICE_NAME]
            LOG.info("已配对设备枚举耗时 %.2f 秒", perf_counter() - started)
            if not matches:
                raise RuntimeError(f"找不到已配对设备 {DEVICE_NAME}，请先在 Windows 设置中配对")
            started = perf_counter()
            LOG.info("打开 BluetoothDevice…")
            self.device = await BluetoothDevice.from_id_async(matches[0].id)
        else:
            LOG.info("按地址 %012X 打开 BluetoothDevice（跳过枚举）…", address)
            self.device = await BluetoothDevice.from_bluetooth_address_async(address)
        LOG.info("打开 BluetoothDevice 耗时 %.2f 秒", perf_counter() - started)
        if self.device is None:
            raise RuntimeError("Windows 无法打开该 BluetoothDevice")
        self.connection_token = self.device.add_connection_status_changed(
            self._on_connection_status_changed
        )
        self._publish_connection_status()
        LOG.info("监听设备：%s，地址=%012X", self.device.name, self.device.bluetooth_address)

    def _on_connection_status_changed(self, sender, _args) -> None:
        # WinRT calls this handler on a non-Python UI thread.
        connected = sender.connection_status == BluetoothConnectionStatus.CONNECTED
        self.connection_callback(connected, sender.name)
        LOG.info("系统蓝牙事件：%s", "已连接" if connected else "已断开")

    def _publish_connection_status(self) -> None:
        connected = (
            self.device is not None
            and self.device.connection_status == BluetoothConnectionStatus.CONNECTED
        )
        self.connection_callback(connected, self.device.name if self.device else DEVICE_NAME)

    async def connect_rfcomm(self) -> None:
        self.cancel_scheduled_disconnect()
        if self.socket is not None:
            return
        if self.device is None:
            await self.initialize()

        if self.device is None:
            raise RuntimeError("蓝牙设备尚未初始化")
        started = perf_counter()
        LOG.info("查询缓存的 Serial Port/SPP 服务…")
        result = await self.device.get_rfcomm_services_for_id_with_cache_mode_async(
            RfcommServiceId.serial_port, BluetoothCacheMode.CACHED
        )
        services = list(result.services)
        LOG.info("SPP 缓存查询耗时 %.2f 秒", perf_counter() - started)
        if not services:
            started = perf_counter()
            LOG.info("缓存未命中，重新发现 SPP 服务…")
            result = await self.device.get_rfcomm_services_for_id_with_cache_mode_async(
                RfcommServiceId.serial_port, BluetoothCacheMode.UNCACHED
            )
            services = list(result.services)
            LOG.info("SPP 服务发现耗时 %.2f 秒", perf_counter() - started)
        if not services:
            raise RuntimeError("设备没有返回标准 SPP/RFCOMM 服务")

        service = services[0]
        socket = StreamSocket()
        started = perf_counter()
        LOG.info("建立 RFCOMM 连接…")
        try:
            await socket.connect_async(
                service.connection_host_name,
                service.connection_service_name,
            )
        except BaseException:
            # Also release local WinRT resources when a CLI timeout cancels connect.
            socket.close()
            service.close()
            raise

        self.socket = socket
        self.reader = DataReader(socket.input_stream)
        self.reader.input_stream_options = InputStreamOptions.PARTIAL
        self.writer = DataWriter(socket.output_stream)
        self.parser.clear()
        service.close()
        LOG.info("RFCOMM 已连接，耗时 %.2f 秒", perf_counter() - started)

    async def request(
        self,
        feature: int,
        command: int,
        payload: bytes = b"",
        timeout: float = 3.0,
    ) -> GaiaPDU:
        async with self.request_lock:
            await self.connect_rfcomm()
            if self.writer is None or self.reader is None:
                raise ConnectionError("RFCOMM 数据流尚未建立")
            frame = wrap_v4(make_pdu(feature, command, payload))
            LOG.info("TX %s", frame.hex(" ").upper())
            self.writer.write_bytes(frame)
            await self.writer.store_async()

            loop = asyncio.get_running_loop()
            deadline = loop.time() + timeout
            while True:
                remaining = deadline - loop.time()
                if remaining <= 0:
                    raise TimeoutError(
                        f"等待回包超时 feature=0x{feature:02X} cmd=0x{command:02X}"
                    )
                count = await asyncio.wait_for(self.reader.load_async(512), remaining)
                if count == 0:
                    await self.disconnect_rfcomm()
                    raise ConnectionError("RFCOMM 被设备关闭")
                data = bytearray(count)
                self.reader.read_bytes(data)
                LOG.info("RX %s", bytes(data).hex(" ").upper())
                for packet in self.parser.feed(bytes(data)):
                    LOG.info(
                        "GAIA feature=0x%02X type=%d cmd=0x%02X payload=%s",
                        packet.feature,
                        packet.packet_type,
                        packet.command,
                        packet.payload.hex(" ").upper(),
                    )
                    if packet.feature == feature and packet.command == command:
                        return packet

    async def send(self, feature: int, command: int, payload: bytes) -> None:
        async with self.request_lock:
            await self.connect_rfcomm()
            if self.writer is None:
                raise ConnectionError("RFCOMM 输出流尚未建立")
            frame = wrap_v4(make_pdu(feature, command, payload))
            LOG.info("TX %s", frame.hex(" ").upper())
            self.writer.write_bytes(frame)
            await self.writer.store_async()

    def cancel_scheduled_disconnect(self) -> None:
        if self.disconnect_task is not None:
            self.disconnect_task.cancel()
            self.disconnect_task = None

    def schedule_disconnect(self, delay: float = 5.0) -> None:
        self.cancel_scheduled_disconnect()

        async def delayed() -> None:
            try:
                await asyncio.sleep(delay)
                await self.disconnect_rfcomm()
            except asyncio.CancelledError:
                pass

        self.disconnect_task = asyncio.create_task(delayed())
        LOG.info("浮窗已关闭，%.0f 秒后释放 RFCOMM", delay)

    async def disconnect_rfcomm(self) -> None:
        current_task = asyncio.current_task()
        if self.disconnect_task is not current_task:
            self.cancel_scheduled_disconnect()
        else:
            self.disconnect_task = None
        if self.writer is not None:
            with suppress(Exception):
                self.writer.detach_stream()
            self.writer.close()
        if self.reader is not None:
            with suppress(Exception):
                self.reader.detach_stream()
            self.reader.close()
        if self.socket is not None:
            self.socket.close()
        self.writer = self.reader = self.socket = None
        self.parser.clear()
        LOG.info("RFCOMM 已释放")

    async def close(self) -> None:
        await self.disconnect_rfcomm()
        if self.device is not None and self.connection_token is not None:
            self.device.remove_connection_status_changed(self.connection_token)
        if self.device is not None:
            self.device.close()
        self.connection_token = None
        self.device = None
