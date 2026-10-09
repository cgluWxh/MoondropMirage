"""Exercise connection routing with mocked Windows APIs on any platform."""
import asyncio
import importlib.util
import sys
import unittest
from types import ModuleType, SimpleNamespace
from unittest.mock import AsyncMock, Mock, patch


def load_transport():
    exports = {
        "winrt.windows.devices.bluetooth": ("BluetoothCacheMode", "BluetoothConnectionStatus", "BluetoothDevice"),
        "winrt.windows.devices.bluetooth.rfcomm": ("RfcommServiceId",),
        "winrt.windows.devices.enumeration": ("DeviceInformation",),
        "winrt.windows.networking.sockets": ("StreamSocket",),
        "winrt.windows.storage.streams": ("DataReader", "DataWriter", "InputStreamOptions"),
    }
    modules = {}
    for name, attributes in exports.items():
        module = ModuleType(name)
        for attribute in attributes:
            setattr(module, attribute, Mock())
        modules[name] = module
    spec = importlib.util.spec_from_file_location("transport_under_test", "winrt_transport.py")
    if spec is None or spec.loader is None:
        raise RuntimeError("Cannot load transport")
    module = importlib.util.module_from_spec(spec)
    with patch.dict(sys.modules, modules):
        spec.loader.exec_module(module)
    return module


class TransportTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.module = load_transport()
        self.transport = self.module.MirageTransport(lambda *_: None)

    async def test_address_skips_enumeration(self):
        device = Mock()
        self.module.BluetoothDevice.from_bluetooth_address_async = AsyncMock(return_value=device)
        await self.transport.initialize(0xAABBCCDDEEFF)
        self.module.DeviceInformation.find_all_async_aqs_filter.assert_not_called()
        self.module.BluetoothDevice.from_bluetooth_address_async.assert_awaited_once_with(0xAABBCCDDEEFF)

    async def test_paired_device_selection(self):
        self.module.DeviceInformation.find_all_async_aqs_filter = AsyncMock(return_value=[
            SimpleNamespace(name="Other", id="other"),
            SimpleNamespace(name="MOONDROP MIRAGE", id="mirage"),
        ])
        self.module.BluetoothDevice.from_id_async = AsyncMock(return_value=Mock())
        await self.transport.initialize()
        self.module.BluetoothDevice.get_device_selector_from_pairing_state.assert_called_once_with(True)
        self.module.BluetoothDevice.from_id_async.assert_awaited_once_with("mirage")

    async def test_cached_service_and_fallback(self):
        for cache_hit in (True, False):
            with self.subTest(cache_hit=cache_hit):
                service = Mock()
                lookup = AsyncMock(side_effect=[SimpleNamespace(services=[service])] if cache_hit else [
                    SimpleNamespace(services=[]), SimpleNamespace(services=[service])])
                self.transport.device = SimpleNamespace(get_rfcomm_services_for_id_with_cache_mode_async=lookup)
                socket = Mock()
                socket.connect_async = AsyncMock()
                self.module.StreamSocket.return_value = socket
                await self.transport.connect_rfcomm()
                self.assertEqual(lookup.await_args_list[0].args[1], self.module.BluetoothCacheMode.CACHED)
                self.assertEqual(lookup.await_count, 1 if cache_hit else 2)
                if not cache_hit:
                    self.assertEqual(lookup.await_args_list[1].args[1], self.module.BluetoothCacheMode.UNCACHED)
                await self.transport.disconnect_rfcomm()

    async def test_cancelled_connect_releases_local_resources(self):
        service = Mock()
        self.transport.device = SimpleNamespace(get_rfcomm_services_for_id_with_cache_mode_async=AsyncMock(
            return_value=SimpleNamespace(services=[service])))
        socket = Mock()
        socket.connect_async = AsyncMock(side_effect=asyncio.CancelledError())
        self.module.StreamSocket.return_value = socket
        with self.assertRaises(asyncio.CancelledError):
            await self.transport.connect_rfcomm()
        socket.close.assert_called_once()
        service.close.assert_called_once()


if __name__ == "__main__":
    unittest.main()
