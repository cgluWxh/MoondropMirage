import asyncio
import unittest

from mirage_cli import apply_settings, build_parser


class FakeTransport:
    def __init__(self, callback):
        self.sent = []
        self.closed = False
        self.fail = False
        self.stall = False

    async def initialize(self, address=None):
        self.address = address
        if self.stall:
            await asyncio.sleep(60)
        if self.fail:
            raise RuntimeError("connection failed")

    async def send(self, feature, command, payload):
        self.sent.append((feature, command, payload))

    async def close(self):
        self.closed = True


class CliTests(unittest.TestCase):
    def run_settings(self, flags, transport):
        args = build_parser().parse_args(flags)
        asyncio.run(apply_settings(args, lambda callback: transport))

    def test_anc_modes(self):
        for mode, value in (("off", 0), ("adaptive", 1), ("transparency", 2), ("wind-reduction", 3), ("noise-cancelling", 4)):
            with self.subTest(mode=mode):
                transport = FakeTransport(None)
                self.run_settings(["--anc", mode], transport)
                self.assertEqual(transport.sent, [(0x20, 0x04, bytes((value,)))])
                self.assertTrue(transport.closed)

    def test_multipoint_and_combined(self):
        for mode, value in (("on", 1), ("off", 0)):
            transport = FakeTransport(None)
            self.run_settings(["--anc", "off", "--multipoint", mode], transport)
            self.assertEqual(transport.sent, [(0x20, 0x04, b"\x00"), (0x14, 0x02, bytes((value,)))])
            self.assertTrue(transport.closed)

    def test_multipoint_only(self):
        transport = FakeTransport(None)
        self.run_settings(["--multipoint", "on"], transport)
        self.assertEqual(transport.sent, [(0x14, 0x02, b"\x01")])
        self.assertTrue(transport.closed)

    def test_initialization_failure_closes(self):
        transport = FakeTransport(None)
        transport.fail = True
        with self.assertRaises(RuntimeError):
            self.run_settings(["--anc", "off"], transport)
        self.assertTrue(transport.closed)

    def test_address_forwarded(self):
        transport = FakeTransport(None)
        self.run_settings(["--anc", "off", "--address", "AA:BB:CC:DD:EE:FF"], transport)
        self.assertEqual(transport.address, 0xAABBCCDDEEFF)
        self.assertTrue(transport.closed)

    def test_timeout_closes(self):
        transport = FakeTransport(None)
        transport.stall = True
        with self.assertRaises(TimeoutError):
            self.run_settings(["--anc", "off", "--timeout", "0.01"], transport)
        self.assertTrue(transport.closed)


if __name__ == "__main__":
    unittest.main()
