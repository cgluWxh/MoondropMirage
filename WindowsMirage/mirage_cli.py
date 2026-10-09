"""One-shot MIRAGE controls without importing the GUI."""
from __future__ import annotations

import argparse
import asyncio
import logging
import math
import sys

ANC_MODES = {"off": 0, "adaptive": 1, "transparency": 2, "wind-reduction": 3, "noise-cancelling": 4}


def positive_timeout(value: str) -> float:
    try:
        timeout = float(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("超时必须是数字") from exc
    if not math.isfinite(timeout) or timeout <= 0:
        raise argparse.ArgumentTypeError("超时必须是有限的正数")
    return timeout


def bluetooth_address(value: str) -> int:
    normalized = value.replace(":", "").replace("-", "")
    if len(normalized) != 12 or any(char not in "0123456789abcdefABCDEF" for char in normalized):
        raise argparse.ArgumentTypeError("蓝牙地址必须是 12 位十六进制，如 AA:BB:CC:DD:EE:FF")
    try:
        return int(normalized, 16)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("无效蓝牙地址") from exc


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="临时连接 MIRAGE，调整设置后断开并退出。")
    parser.add_argument("--anc", choices=ANC_MODES, help="降噪模式：noise-cancelling（降噪）/ adaptive（自适应）/ transparency（通透）/ wind-reduction（抗风噪）/ off（关闭）")
    parser.add_argument("--multipoint", choices=("on", "off"), help="开启/关闭双设备连接")
    parser.add_argument("--address", type=bluetooth_address, help="耳机蓝牙地址；指定时跳过设备枚举")
    parser.add_argument("--timeout", type=positive_timeout, default=45.0, help="连接和设置的总超时秒数（默认 45）")
    parser.add_argument("--verbose", action="store_true", help="显示蓝牙和协议日志")
    return parser


async def apply_settings(args: argparse.Namespace, transport_factory=None) -> None:
    # Lazy import keeps --help usable without Windows/WinRT or GUI dependencies.
    if transport_factory is None:
        from winrt_transport import MirageTransport
        transport_factory = MirageTransport

    transport = transport_factory(lambda _connected, _name: None)

    async def configure() -> None:
        if args.address is None:
            await transport.initialize()
        else:
            await transport.initialize(address=args.address)
        if args.anc is not None:
            await transport.send(0x20, 0x04, bytes((ANC_MODES[args.anc],)))
            await asyncio.sleep(0.3)
        if args.multipoint is not None:
            await transport.send(0x14, 0x02, bytes((1 if args.multipoint == "on" else 0,)))
            await asyncio.sleep(0.3)

    try:
        await asyncio.wait_for(configure(), timeout=args.timeout)
    finally:
        await transport.close()


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.anc is None and args.multipoint is None:
        parser.error("至少指定 --anc 或 --multipoint")
    logging.basicConfig(
        level=logging.INFO if args.verbose else logging.WARNING,
        format="%(levelname)s %(name)s: %(message)s",
    )
    try:
        asyncio.run(apply_settings(args))
    except TimeoutError:
        print(f"操作超时（{args.timeout:g} 秒），已释放临时连接。", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("操作已取消。", file=sys.stderr)
        return 130
    except Exception as exc:
        print(f"设置失败：{exc}", file=sys.stderr)
        return 1
    print("设置指令已发送，临时连接已释放。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
