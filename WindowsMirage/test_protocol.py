import unittest

from protocol import GaiaFrameParser, make_pdu, parse_battery, parse_multipoint_device, wrap_v4


class ProtocolTests(unittest.TestCase):
    def test_battery_request(self):
        self.assertEqual(
            wrap_v4(make_pdu(0x0D, 0x01, b"\x01\x02")),
            bytes.fromhex("FF 04 00 02 00 1D 1A 01 01 02"),
        )

    def test_battery_response(self):
        parser = GaiaFrameParser()
        packets = parser.feed(bytes.fromhex("FF 04 00 06 00 1D 1B 01 01 64 02 56 03 FF"))
        self.assertEqual(len(packets), 1)
        self.assertEqual(parse_battery(packets[0].payload), {1: 100, 2: 86, 3: None})

    def test_fragmented_frame(self):
        parser = GaiaFrameParser()
        raw = bytes.fromhex("FF 04 00 01 00 1D 29 01 01")
        self.assertEqual(parser.feed(raw[:3]), [])
        packets = parser.feed(raw[3:])
        self.assertEqual(packets[0].feature, 0x14)
        self.assertEqual(packets[0].command, 1)

    def test_multipoint_device(self):
        payload = bytes.fromhex("01 54 74 E2 D8 A6 50") + b"cgluWxh-Laptop"
        device = parse_multipoint_device(payload, "current")
        self.assertEqual(device["address"], "54:74:E2:D8:A6:50")
        self.assertEqual(device["name"], "cgluWxh-Laptop")

    def test_empty_multipoint_slot(self):
        payload = bytes.fromhex("00 FF FF FF FF FF FF")
        self.assertIsNone(parse_multipoint_device(payload, "next"))


if __name__ == "__main__":
    unittest.main()
