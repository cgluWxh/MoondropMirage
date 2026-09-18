from __future__ import annotations

import asyncio
import logging
import queue
import sys
import threading
import tkinter as tk
from pathlib import Path
from tkinter import messagebox, ttk

import pystray
from PIL import Image, ImageDraw

from protocol import parse_battery, parse_multipoint_device
from winrt_transport import MirageTransport

APP_DIR = Path(__file__).resolve().parent
# LOG_FILE = APP_DIR / "windows-mirage.log"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    handlers=[
        # logging.FileHandler(LOG_FILE, encoding="utf-8"),
        logging.StreamHandler(),
    ],
)
LOG = logging.getLogger("mirage.app")

ANC_OPTIONS = [
    ("关闭", 0),
    ("自适应", 1),
    ("通透", 2),
    ("抗风噪", 3),
    ("降噪", 4),
]
TIMEOUT_OPTIONS = [("关闭", 0), ("5 分钟", 1), ("10 分钟", 2), ("30 分钟", 3), ("60 分钟", 4)]


class AsyncWorker:
    def __init__(self, ui_events: queue.Queue) -> None:
        self.ui_events = ui_events
        self.loop = asyncio.new_event_loop()
        self.thread = threading.Thread(target=self._run, name="MirageAsync", daemon=True)
        self.transport: MirageTransport | None = None
        self.thread.start()
        self.submit(self._initialize())

    def _run(self) -> None:
        asyncio.set_event_loop(self.loop)
        self.loop.run_forever()

    async def _initialize(self) -> None:
        try:
            self.transport = MirageTransport(self._connection_event)
            await self.transport.initialize()
        except Exception as exc:
            LOG.exception("初始化失败")
            self.ui_events.put(("error", f"初始化失败：{exc}"))

    def _connection_event(self, connected: bool, name: str) -> None:
        self.ui_events.put(("connection", connected, name))

    def submit(self, coroutine) -> None:
        future = asyncio.run_coroutine_threadsafe(coroutine, self.loop)

        def done(result) -> None:
            try:
                result.result()
            except Exception as exc:
                LOG.exception("后台操作失败")
                self.ui_events.put(("error", str(exc)))

        future.add_done_callback(done)

    async def refresh(self) -> None:
        if self.transport is None:
            raise RuntimeError("蓝牙监听尚未初始化")
        battery = parse_battery((await self.transport.request(0x0D, 0x01, b"\x01\x02")).payload)
        anc_packet = await self.transport.request(0x20, 0x03)
        state_packet = await self.transport.request(0x14, 0x01)
        timeout_packet = await self.transport.request(0x14, 0x03)
        devices = []
        for command, slot in ((0x05, "当前设备"), (0x06, "下一设备")):
            device = parse_multipoint_device(
                (await self.transport.request(0x14, command)).payload, slot
            )
            if device:
                devices.append(device)
        self.ui_events.put(("snapshot", {
            "battery": battery,
            "anc": anc_packet.payload[0] if anc_packet.payload else None,
            "multipoint": bool(state_packet.payload and state_packet.payload[0] == 1),
            "timeout": timeout_packet.payload[0] if timeout_packet.payload else 0,
            "devices": devices,
        }))

    async def set_and_refresh(self, feature: int, command: int, payload: bytes) -> None:
        if self.transport is None:
            raise RuntimeError("蓝牙监听尚未初始化")
        await self.transport.send(feature, command, payload)
        await asyncio.sleep(0.3)
        await self.refresh()

    def window_opened(self) -> None:
        if self.transport:
            self.loop.call_soon_threadsafe(self.transport.cancel_scheduled_disconnect)
        self.submit(self.refresh())

    def window_closed(self) -> None:
        if self.transport:
            self.loop.call_soon_threadsafe(self.transport.schedule_disconnect, 5.0)

    def shutdown(self) -> None:
        async def stop() -> None:
            if self.transport:
                await self.transport.close()
            self.loop.stop()

        asyncio.run_coroutine_threadsafe(stop(), self.loop)


class MirageWindow:
    def __init__(self) -> None:
        self.root = tk.Tk()
        self.root.title("MOONDROP MIRAGE")
        self.root.geometry("390x500")
        self.root.resizable(False, False)
        self.root.protocol("WM_DELETE_WINDOW", self.hide)
        self.events: queue.Queue = queue.Queue()
        self.worker = AsyncWorker(self.events)
        self.connected = False
        self.devices: list[dict] = []
        self.tray = pystray.Icon(
            "MoondropMirage",
            self._make_icon(),
            "MOONDROP MIRAGE",
            menu=pystray.Menu(
                pystray.MenuItem("打开控制面板", self._tray_show, default=True),
                pystray.MenuItem("刷新", self._tray_refresh),
                pystray.MenuItem("退出", self._tray_quit),
            ),
        )
        self._build_ui()
        self.root.withdraw()
        threading.Thread(target=self.tray.run, name="MirageTray", daemon=True).start()
        self.root.after(100, self._drain_events)

    def _build_ui(self) -> None:
        frame = ttk.Frame(self.root, padding=16)
        frame.pack(fill="both", expand=True)
        ttk.Label(frame, text="MOONDROP MIRAGE", font=("Segoe UI", 15, "bold")).pack(anchor="w")
        self.status = ttk.Label(frame, text="正在初始化连接监听…")
        self.status.pack(anchor="w", pady=(2, 14))

        ttk.Label(frame, text="电量", font=("Segoe UI", 10, "bold")).pack(anchor="w")
        self.battery = ttk.Label(frame, text="左耳 —    右耳 —    充电盒 —", font=("Consolas", 11))
        self.battery.pack(anchor="w", pady=(4, 14))

        anc_row = ttk.Frame(frame)
        anc_row.pack(fill="x", pady=5)
        ttk.Label(anc_row, text="ANC").pack(side="left")
        self.anc_var = tk.StringVar(value="—")
        self.anc = ttk.Combobox(anc_row, textvariable=self.anc_var, state="readonly", width=12)
        self.anc["values"] = [item[0] for item in ANC_OPTIONS]
        self.anc.pack(side="right")
        self.anc.bind("<<ComboboxSelected>>", self._set_anc)

        mp_row = ttk.Frame(frame)
        mp_row.pack(fill="x", pady=5)
        ttk.Label(mp_row, text="双设备连接").pack(side="left")
        self.mp_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(mp_row, variable=self.mp_var, command=self._set_multipoint).pack(side="right")

        timeout_row = ttk.Frame(frame)
        timeout_row.pack(fill="x", pady=5)
        ttk.Label(timeout_row, text="自动关闭").pack(side="left")
        self.timeout_var = tk.StringVar(value="—")
        self.timeout = ttk.Combobox(timeout_row, textvariable=self.timeout_var, state="readonly", width=12)
        self.timeout["values"] = [item[0] for item in TIMEOUT_OPTIONS]
        self.timeout.pack(side="right")
        self.timeout.bind("<<ComboboxSelected>>", self._set_timeout)

        ttk.Separator(frame).pack(fill="x", pady=12)
        ttk.Label(frame, text="已连接设备", font=("Segoe UI", 10, "bold")).pack(anchor="w")
        self.devices_frame = ttk.Frame(frame)
        self.devices_frame.pack(fill="x", pady=8)

        ttk.Button(frame, text="刷新", command=self.refresh).pack(fill="x", side="bottom")
        # ttk.Label(frame, text=f"日志：{LOG_FILE.name}", foreground="#666666").pack(anchor="w", side="bottom", pady=8)

    def show(self) -> None:
        self.root.deiconify()
        self.root.lift()
        self.root.attributes("-topmost", True)
        self.root.after(250, lambda: self.root.attributes("-topmost", False))
        self.worker.window_opened()
        self.status.configure(text="正在连接并刷新…")

    def hide(self) -> None:
        self.root.withdraw()
        self.worker.window_closed()

    def refresh(self) -> None:
        self.status.configure(text="正在刷新…")
        self.worker.submit(self.worker.refresh())

    def _set_anc(self, _event=None) -> None:
        value = ANC_OPTIONS[self.anc.current()][1]
        self.status.configure(text="正在设置 ANC…")
        self.worker.submit(self.worker.set_and_refresh(0x20, 0x04, bytes((value,))))

    def _set_multipoint(self) -> None:
        value = 1 if self.mp_var.get() else 0
        self.status.configure(text="正在设置双设备连接…")
        self.worker.submit(self.worker.set_and_refresh(0x14, 0x02, bytes((value,))))

    def _set_timeout(self, _event=None) -> None:
        value = TIMEOUT_OPTIONS[self.timeout.current()][1]
        self.status.configure(text="正在设置超时…")
        self.worker.submit(self.worker.set_and_refresh(0x14, 0x04, bytes((value,))))

    def _disconnect(self, index: int) -> None:
        device = self.devices[index]
        if not messagebox.askyesno("断开设备", f"确定断开 {device['name']}？\n{device['address']}"):
            return
        self.status.configure(text="正在断开设备…")
        self.worker.submit(
            self.worker.set_and_refresh(0x14, 0x07, device["address_bytes"])
        )

    def _show_snapshot(self, snapshot: dict) -> None:
        def percent(value) -> str:
            return "—" if value is None else f"{value}%"

        battery = snapshot["battery"]
        self.battery.configure(
            text=f"左耳 {percent(battery.get(1))}    右耳 {percent(battery.get(2))}    充电盒 {percent(battery.get(3))}"
        )
        anc_value = snapshot["anc"]
        if isinstance(anc_value, int) and 0 <= anc_value < len(ANC_OPTIONS):
            self.anc.current(anc_value)
        self.mp_var.set(snapshot["multipoint"])
        timeout = snapshot["timeout"]
        if isinstance(timeout, int) and 0 <= timeout < len(TIMEOUT_OPTIONS):
            self.timeout.current(timeout)
        self.devices = snapshot["devices"]
        for child in self.devices_frame.winfo_children():
            child.destroy()
        if not self.devices:
            ttk.Label(self.devices_frame, text="未返回设备").pack(anchor="w")
        for index, device in enumerate(self.devices):
            row = ttk.Frame(self.devices_frame)
            row.pack(fill="x", pady=3)
            ttk.Label(row, text=f"{device['name']}\n{device['address']}").pack(side="left")
            ttk.Button(row, text="断开", command=lambda i=index: self._disconnect(i)).pack(side="right")
        self.status.configure(text="已连接并刷新")
        values = [battery.get(1), battery.get(2)]
        values = [value for value in values if value is not None]
        self.tray.title = f"MOONDROP MIRAGE · {min(values)}%" if values else "MOONDROP MIRAGE"

    def _drain_events(self) -> None:
        try:
            while True:
                event = self.events.get_nowait()
                if event[0] == "connection":
                    self.connected = event[1]
                    self.status.configure(text="系统蓝牙已连接" if event[1] else "系统蓝牙未连接")
                    self.tray.title = f"MOONDROP MIRAGE · {'已连接' if event[1] else '未连接'}"
                elif event[0] == "snapshot":
                    self._show_snapshot(event[1])
                elif event[0] == "error":
                    self.status.configure(text=f"错误：{event[1]}")
                elif event[0] == "show":
                    self.show()
                elif event[0] == "refresh":
                    self.refresh()
                elif event[0] == "quit":
                    self.quit()
        except queue.Empty:
            pass
        self.root.after(100, self._drain_events)

    def _tray_show(self, _icon=None, _item=None) -> None:
        self.events.put(("show",))

    def _tray_refresh(self, _icon=None, _item=None) -> None:
        self.events.put(("refresh",))

    def _tray_quit(self, _icon=None, _item=None) -> None:
        self.events.put(("quit",))

    def quit(self) -> None:
        self.worker.shutdown()
        self.tray.stop()
        self.root.destroy()

    @staticmethod
    def _make_icon() -> Image.Image:
        image = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
        draw = ImageDraw.Draw(image)
        draw.arc((10, 8, 54, 52), 180, 360, fill="white", width=7)
        draw.rounded_rectangle((7, 28, 20, 55), 5, fill="white")
        draw.rounded_rectangle((44, 28, 57, 55), 5, fill="white")
        return image

    def run(self) -> None:
        self.root.mainloop()


def main() -> int:
    if sys.platform != "win32":
        print("此测试版只能在 Windows 10/11 上运行。")
        return 1
    MirageWindow().run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
