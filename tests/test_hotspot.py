from contextlib import redirect_stdout
import io
import unittest
from unittest.mock import patch

from test_investigate import ph

WIFI = """Dump of ActiveModeWarden
NumActiveModeManagers: 2
STA + STA Concurrency Supported: true
Dump of SoftApManager id=2
current StateMachine mode: StartedState
mApInterfaceName: swlan0
mIfaceIsUp: true
getConnectedClientList().size(): 2
"""
TETHER = """Current upstream interface(s): [rmnet_data0]
  swlan0 - TetheredState - lastError = 0
  TetheredClient {hwAddr aa:bb:cc:dd:ee:ff, addresses [AddressInfo {192.168.43.22/24, hostname DemoPhone}], tetheringType 0}
  TetheredClient {hwAddr 00:00:00:00:00:01, addresses [AddressInfo {192.168.43.99/24, hostname USB}], tetheringType 1}
  TetheredClient {hwAddr 00:00:00:00:00:04, addresses [AddressInfo {192.168.43.98/24, hostname NCM}], tetheringType 4}
"""
ADDRESSES = "4: swlan0    inet 192.168.43.1/24 brd 192.168.43.255 scope global swlan0\n"
CACHE = """192.168.43.22 dev swlan0 lladdr aa:bb:cc:dd:ee:ff REACHABLE
192.168.43.77 dev swlan0 lladdr 00:03:04:05:06:07 STALE
192.168.43.1 dev swlan0 lladdr 00:03:04:05:06:07 STALE
192.168.43.55 dev wlan0 lladdr aa:bb:cc:dd:ee:ff REACHABLE
192.168.43.66 dev swlan0 FAILED
192.168.99.66 dev swlan0 lladdr aa:bb:cc:dd:ee:ff REACHABLE
"""


class Hotspot(unittest.TestCase):
    def test_snapshot_scopes_clients_and_reads_names(self):
        def fake(argv, root):
            cmd = tuple(argv[1:])
            return {("-t", "4", "tethering", "--short"): TETHER, ("-o", "address", "show"): ADDRESSES,
                    ("neigh", "show", "dev", "swlan0"): CACHE, ("gsm.operator.alpha",): "Carrier A,Carrier B"}[cmd]
        with patch.object(ph, "ap_status", return_value=ph.parse_softap(WIFI)), patch.object(ph, "ap_probe", side_effect=fake):
            snapshot = ph.ap_snapshot(True)
        self.assertEqual(snapshot["active"], {"swlan0": 2})
        self.assertEqual([c["ip"] for c in snapshot["clients"]], ["192.168.43.22", "192.168.43.77"])
        self.assertEqual(snapshot["clients"][0]["name"], "DemoPhone")
        self.assertIn("Carrier A, Carrier B", snapshot["upstream"])
        self.assertIn("не оператор SIM клиента", "\n".join(ph.ap_card(snapshot["clients"][0], snapshot["upstream"])))

    def test_mobile_upstream_does_not_come_from_other_hotspot(self):
        with patch.object(ph, "ap_status", return_value=("on", {"swlan0": 0})), \
             patch.object(ph, "ap_probe", side_effect=lambda argv, root: TETHER.replace("swlan0 - Tethered", "usb0 - Tethered")
                                                     if "tethering" in argv else ""):
            self.assertEqual(ph.ap_snapshot(True)["upstream"], "")

    def test_dhcp_matches_mac_and_ignores_expired_and_usb(self):
        leases = "100 00:00:00:00:00:09 192.168.43.22 stale *\n999 00:03:04:05:06:07 192.168.43.77 Other *"
        names = ph.ap_names(TETHER, leases, 100)
        self.assertEqual(len(names), 2)
        networks = ph.ap_interfaces(ADDRESSES, ["swlan0"])["swlan0"]
        rows = ph.ap_neighbours(CACHE, "swlan0", networks, names, 2)
        self.assertEqual([r["name"] for r in rows], ["DemoPhone", "Other"])
        self.assertEqual(ph.ap_neighbours(CACHE, "swlan0", networks, names, 0), [])

    def test_start_requires_state_and_secure_android_command(self):
        with patch.object(ph, "ap_status", return_value=("unknown", {})), patch.object(ph, "system_probe") as command:
            with self.assertRaises(ph.UserError):
                ph.ap_start()
            command.assert_not_called()
        with patch.object(ph, "ap_status", side_effect=[("off", {}), ("on", {"ap0": 0})]), \
             patch.object(ph, "ap_probe", return_value="  start-lohs <ssid> ..."), \
             patch.object(ph, "system_probe", return_value="") as start:
            ssid, password = ph.ap_start()
        start.assert_called_once_with(["/system/bin/cmd", "wifi", "start-lohs", ssid, "wpa2", password, "-b", "2"], True)
        self.assertRegex(ssid, r"^Shark-[0-9A-F]{4}$")
        self.assertGreaterEqual(len(password), 8)

    def test_selects_a_client_card_from_the_panel(self):
        networks = ph.ap_interfaces(ADDRESSES, ["swlan0"])["swlan0"]
        rows = ph.ap_neighbours(CACHE, "swlan0", networks, ph.ap_names(TETHER, "", 0), 2)
        snap = {"state":"on", "active":{"swlan0":2}, "upstream":"Carrier A", "clients":rows}
        panel = ph.SharkConsole(root_network=True)
        panel.full = False
        with patch.object(ph, "ap_snapshot", return_value=snap), patch.object(
                ph.sys, "stdin", io.StringIO("1\n0\n")), patch.object(panel, "result") as card, redirect_stdout(io.StringIO()):
            panel.hotspot()
        card.assert_called_once()
        self.assertIn("IP · 192.168.43.22", card.call_args.args[1])


if __name__ == "__main__":
    unittest.main()
