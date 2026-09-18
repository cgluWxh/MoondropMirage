from __future__ import annotations

from dataclasses import dataclass

GAIA_VENDOR = 0x001D


@dataclass(frozen=True)
class GaiaPDU:
    vendor: int
    feature: int
    packet_type: int
    command: int
    payload: bytes


def make_pdu(feature: int, command: int, payload: bytes = b"") -> bytes:
    value = (feature << 9) | (command & 0x7F)
    return bytes((
        (GAIA_VENDOR >> 8) & 0xFF,
        GAIA_VENDOR & 0xFF,
        (value >> 8) & 0xFF,
        value & 0xFF,
    )) + payload


def wrap_v4(pdu: bytes) -> bytes:
    payload_length = max(0, len(pdu) - 4)
    if payload_length <= 0xFF:
        return bytes((0xFF, 0x04, 0x00, payload_length)) + pdu
    return bytes((
        0xFF, 0x04, 0x02,
        (payload_length >> 8) & 0xFF,
        payload_length & 0xFF,
    )) + pdu


def parse_pdu(data: bytes) -> GaiaPDU | None:
    if len(data) < 4:
        return None
    vendor = int.from_bytes(data[0:2], "big")
    value = int.from_bytes(data[2:4], "big")
    return GaiaPDU(
        vendor=vendor,
        feature=(value >> 9) & 0x7F,
        packet_type=(value >> 7) & 0x03,
        command=value & 0x7F,
        payload=data[4:],
    )


class GaiaFrameParser:
    def __init__(self) -> None:
        self.buffer = bytearray()

    def clear(self) -> None:
        self.buffer.clear()

    def feed(self, chunk: bytes) -> list[GaiaPDU]:
        packets: list[GaiaPDU] = []

        # A few firmwares may emit a bare PDU. A normal V4 frame starts at FF.
        if len(chunk) >= 4 and chunk[:2] == b"\x00\x1d":
            boundary = chunk.find(b"\xff", 4)
            bare = chunk if boundary < 0 else chunk[:boundary]
            pdu = parse_pdu(bare)
            if pdu and pdu.vendor == GAIA_VENDOR:
                packets.append(pdu)
            if boundary < 0:
                return packets
            chunk = chunk[boundary:]

        self.buffer.extend(chunk)
        while True:
            while self.buffer and self.buffer[0] != 0xFF:
                del self.buffer[0]
            if len(self.buffer) < 4:
                break

            version = self.buffer[1]
            flags = self.buffer[2]
            extended = version >= 4 and bool(flags & 0x02)
            header_length = 5 if extended else 4
            if len(self.buffer) < header_length:
                break
            payload_length = (
                (self.buffer[3] << 8) | self.buffer[4]
                if extended else self.buffer[3]
            )
            checksum_length = 1 if flags & 0x01 else 0
            pdu_length = payload_length + 4
            total_length = header_length + pdu_length + checksum_length
            if len(self.buffer) < total_length:
                break
            raw_pdu = bytes(self.buffer[header_length:header_length + pdu_length])
            del self.buffer[:total_length]
            pdu = parse_pdu(raw_pdu)
            if pdu and pdu.vendor == GAIA_VENDOR:
                packets.append(pdu)
        return packets


def parse_battery(payload: bytes) -> dict[int, int | None]:
    result: dict[int, int | None] = {}
    for index in range(0, len(payload) - 1, 2):
        value = payload[index + 1]
        result[payload[index]] = value if value <= 100 else None
    return result


def parse_multipoint_device(payload: bytes, slot: str) -> dict | None:
    if len(payload) < 7:
        return None
    address_bytes = payload[1:7]
    if address_bytes == b"\xff" * 6:
        return None
    return {
        "slot": slot,
        "status": payload[0],
        "address_bytes": address_bytes,
        "address": ":".join(f"{value:02X}" for value in address_bytes),
        "name": payload[7:].decode("utf-8", errors="replace") or "未知设备",
    }
