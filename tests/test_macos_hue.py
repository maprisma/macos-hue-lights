"""macOS port of the helper: stdlib-only discovery (mDNS, N-UPnP, subnet), the panel_open /
panel_closed commands, the private config file and the JSON line protocol the Swift app uses.
None of these tests talks to a real bridge or to the internet."""
import ast
import importlib.util
import json
import os
import shutil
import socket
import ssl
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "scripts", "hue-lights.py")
BRIDGE_ID = "001788FFFE5A3C21"


def load(name="hue_macos", platform=None):
    spec = importlib.util.spec_from_file_location(name, SCRIPT)
    module = importlib.util.module_from_spec(spec)
    if platform is None:
        spec.loader.exec_module(module)
    else:
        with mock.patch.object(sys, "platform", platform):
            spec.loader.exec_module(module)
    return module


hue = load()


def script_source():
    with open(SCRIPT, encoding="utf-8") as fh:
        return fh.read()


# --------------------------------------------------------------------------- DNS packet builders

def dns_name(name):
    out = b""
    for label in name.split("."):
        out += bytes([len(label)]) + label.encode()
    return out + b"\x00"


def rr(name_bytes, rtype, rdata, ttl=120):
    return name_bytes + rtype.to_bytes(2, "big") + b"\x80\x01" + ttl.to_bytes(4, "big") + \
        len(rdata).to_bytes(2, "big") + rdata


def hue_reply(ip="192.168.1.50", bridge_id="001788fffe5a3c21", instance="Hue Bridge - 5A3C21"):
    """A typical bridge answer: PTR in answers, SRV/TXT/A as additional records, with a
    compression pointer back to the service name in the PTR's rdata."""
    header = b"\x00\x00\x84\x00\x00\x00\x00\x01\x00\x00\x00\x03"
    service = dns_name("_hue._tcp.local")
    ptr_owner_offset = 12
    instance_name = bytes([len(instance)]) + instance.encode() + b"\xc0" + bytes([ptr_owner_offset])
    ptr = rr(service, 12, instance_name)
    inst = bytes([len(instance)]) + instance.encode() + dns_name("_hue._tcp.local")
    host = dns_name("001788fffe5a3c21.local")
    srv = rr(inst, 33, b"\x00\x00\x00\x00\x01\xbb" + host)
    txt_strings = [b"bridgeid=" + bridge_id.encode(), b"modelid=BSB002"]
    txt = rr(inst, 16, b"".join(bytes([len(s)]) + s for s in txt_strings))
    a = rr(host, 1, bytes(int(p) for p in ip.split(".")))
    return header + ptr + srv + txt + a


# --------------------------------------------------------------------------- tests

class PlatformTests(unittest.TestCase):
    def test_darwin_flags(self):
        mac = load("hue_darwin", platform="darwin")
        self.assertTrue(mac.IS_MACOS)
        self.assertEqual(mac.DEVICE_TYPE, "maprisma_hue_mac")
        self.assertLessEqual(len(mac.DEVICE_TYPE), 20)
        linux = load("hue_linux", platform="linux")
        self.assertFalse(linux.IS_MACOS)

    def test_config_path_follows_home_on_macos(self):
        with mock.patch.dict(os.environ, {"HOME": "/Users/someone"}, clear=False):
            os.environ.pop("XDG_CONFIG_HOME", None)
            mac = load("hue_darwin_home", platform="darwin")
        self.assertEqual(mac.CONFIG_PATH, "/Users/someone/.config/hue-lights/config.json")

    def test_stdlib_only(self):
        tree = ast.parse(script_source())
        imported = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                imported.update(a.name.split(".")[0] for a in node.names)
            elif isinstance(node, ast.ImportFrom) and node.module:
                imported.add(node.module.split(".")[0])
        stdlib = getattr(sys, "stdlib_module_names", None)
        if stdlib is None:   # Python 3.9 (/usr/bin/python3 on macOS)
            for name in imported:
                spec = importlib.util.find_spec(name)
                self.assertIsNotNone(spec, name)
                self.assertNotIn("site-packages", str(spec.origin), name)
        else:
            self.assertEqual(imported - set(stdlib), set())

    def test_parses_as_python_39(self):
        """macOS ships Python 3.9 as /usr/bin/python3: no newer syntax in the helper."""
        ast.parse(script_source(), feature_version=(3, 9))

    def test_no_setpriv_without_the_tool(self):
        with mock.patch.object(hue.shutil, "which", return_value=None):
            hue._SETPRIV = None
            self.assertEqual(hue._parent_death_prefix(), [])
        hue._SETPRIV = None


class MdnsTests(unittest.TestCase):
    def test_query_packet(self):
        q = hue.mdns_query()
        self.assertEqual(q[:12], b"\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00")
        self.assertEqual(q[12:], dns_name("_hue._tcp.local") + b"\x00\x0c\x00\x01")

    def test_bridge_reply(self):
        found = hue.parse_mdns_hue([(hue_reply(), "192.168.1.50")])
        self.assertEqual(found, [{"ip": "192.168.1.50", "bridge_id": BRIDGE_ID, "name": "Hue Bridge - 5A3C21"}])

    def test_source_address_when_no_a_record(self):
        packet = hue_reply()
        # Cut the A record (last record): additional count 2.
        a_len = len(dns_name("001788fffe5a3c21.local")) + 10 + 4
        packet = packet[:10] + b"\x00\x02" + packet[12:-a_len]
        found = hue.parse_mdns_hue([(packet, "192.168.1.77")])
        self.assertEqual(found[0]["ip"], "192.168.1.77")

    def test_public_or_loopback_addresses_ignored(self):
        self.assertEqual(hue.parse_mdns_hue([(hue_reply(ip="8.8.8.8"), "8.8.8.8")]), [])
        self.assertEqual(hue.parse_mdns_hue([(hue_reply(ip="127.0.0.1"), "127.0.0.1")]), [])

    def test_garbage_and_pointer_loops(self):
        loop = b"\x00\x00\x84\x00\x00\x00\x00\x01\x00\x00\x00\x00" + b"\xc0\x0c"
        for packet in (b"", b"\x00" * 5, os.urandom(300), loop):
            hue.parse_mdns_hue([(packet, "192.168.1.50")])   # no exception
        with self.assertRaises(ValueError):
            hue._dns_name(loop, 12)

    def test_markup_in_instance_name_removed(self):
        found = hue.parse_mdns_hue([(hue_reply(instance="<b>Evil</b>"), "192.168.1.50")])
        self.assertNotIn("<", found[0]["name"])

    def test_mdns_discover_uses_an_ephemeral_port(self):
        """Never binds 5353 (mDNSResponder owns it on macOS) and returns quickly."""
        bound = []
        real_socket = socket.socket

        class Spy(real_socket):
            def bind(self, addr):
                bound.append(addr)
                return super().bind(addr)

            def sendto(self, *a):
                return 0
        with mock.patch.object(hue.socket, "socket", Spy):
            start = time.monotonic()
            self.assertEqual(hue.mdns_discover(timeout=0.3), [])
        self.assertLess(time.monotonic() - start, 2)
        self.assertEqual(bound, [("", 0)])


class NupnpAndSubnetTests(unittest.TestCase):
    def test_parse_nupnp(self):
        data = [{"id": "001788fffe5a3c21", "internalipaddress": "192.168.1.50", "port": 443},
                {"id": "x", "internalipaddress": "8.8.8.8"}, "junk",
                {"id": "nope", "internalipaddress": "10.0.0.2"}]
        self.assertEqual(hue.parse_nupnp(data), [
            {"ip": "10.0.0.2", "bridge_id": "", "name": "Hue Bridge"},
            {"ip": "192.168.1.50", "bridge_id": BRIDGE_ID, "name": "Hue Bridge"}])
        self.assertEqual(hue.parse_nupnp({"error": 1}), [])

    def test_nupnp_failure_is_empty(self):
        with mock.patch.object(hue.http.client, "HTTPSConnection", side_effect=OSError("offline")):
            self.assertEqual(hue.nupnp_discover(), [])

    def test_subnet_hosts(self):
        hosts = hue.subnet_hosts("192.168.1.20")
        self.assertEqual(len(hosts), 253)
        self.assertNotIn("192.168.1.20", hosts)
        self.assertIn("192.168.1.1", hosts)
        self.assertEqual(hue.subnet_hosts("8.8.8.8"), [])
        self.assertEqual(hue.subnet_hosts(""), [])

    def test_subnet_discover_collects_probes(self):
        with mock.patch.object(hue, "local_ipv4", return_value="192.168.1.20"), \
                mock.patch.object(hue, "probe_bridge",
                                  side_effect=lambda ip: {"ip": ip, "bridge_id": BRIDGE_ID, "name": "Hue"}
                                  if ip == "192.168.1.50" else None):
            self.assertEqual(hue.subnet_discover(), [{"ip": "192.168.1.50", "bridge_id": BRIDGE_ID, "name": "Hue"}])
        with mock.patch.object(hue, "local_ipv4", return_value=""):
            self.assertEqual(hue.subnet_discover(), [])


class DiscoveryOrderTests(unittest.TestCase):
    def make(self, module):
        h = module.Hue.__new__(module.Hue)
        h.last_deep_scan = 0.0
        return h

    def test_macos_never_runs_avahi(self):
        mac = load("hue_darwin_order", platform="darwin")
        h = self.make(mac)
        with mock.patch.object(mac, "run_bounded") as run, \
                mock.patch.object(mac, "mdns_discover", return_value=[{"ip": "192.168.1.50", "bridge_id": "", "name": "Hue"}]), \
                mock.patch.object(mac.shutil, "which", return_value="/usr/bin/avahi-browse"):
            self.assertEqual(h.discover_now()[0]["ip"], "192.168.1.50")
        run.assert_not_called()

    def test_fallbacks_and_their_throttle(self):
        mac = load("hue_darwin_fallback", platform="darwin")
        h = self.make(mac)
        cand = [{"ip": "192.168.1.9", "bridge_id": BRIDGE_ID, "name": "Hue"}]
        with mock.patch.object(mac, "mdns_discover", return_value=[]), \
                mock.patch.object(mac, "nupnp_discover", return_value=[]) as nupnp, \
                mock.patch.object(mac, "subnet_discover", return_value=cand) as scan:
            self.assertEqual(h.discover_now(), cand)
            self.assertEqual(h.discover_now(), [])          # within a minute: only the cheap way
            self.assertEqual((nupnp.call_count, scan.call_count), (1, 1))
            with mock.patch.object(h, "start_discovery"):
                mac.Hue.handle(h, {"cmd": "discover"})       # "Search again" lifts the throttle
            self.assertEqual(h.discover_now(), cand)
            self.assertEqual(scan.call_count, 2)


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.real = hue.load_config
        hue.load_config = lambda: {}

    def tearDown(self):
        hue.load_config = self.real

    def test_panel_open_and_closed_aliases(self):
        h = hue.Hue()
        h.handle({"cmd": "panel_open"})
        self.assertTrue(h.panel_open)
        h.handle({"cmd": "panel_closed"})
        self.assertFalse(h.panel_open)
        h.handle({"cmd": "open"})
        self.assertTrue(h.panel_open)

    def test_snapshot_keys_the_swift_app_reads(self):
        snap = hue.Hue().snapshot()
        for key in ("phase", "error", "error_code", "error_args", "bridge", "rooms", "light_count",
                    "on_count", "candidates", "discovering", "pair_ip", "pair_remaining"):
            self.assertIn(key, snap)
        self.assertEqual(snap["phase"], "unpaired")

    def test_helper_process_speaks_json_lines_and_exits_on_eof(self):
        home = tempfile.mkdtemp()
        try:
            env = dict(os.environ, XDG_CONFIG_HOME=home, HOME=home,
                       PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
            proc = subprocess.Popen([sys.executable, "-I", SCRIPT], stdin=subprocess.PIPE,
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
            line = proc.stdout.readline()
            snap = json.loads(line)
            self.assertEqual(snap["phase"], "unpaired")
            proc.stdin.write(b'{"cmd":"panel_closed"}\nnot json\n' + b"x" * 9000 + b"\n")
            proc.stdin.close()
            self.assertEqual(proc.wait(timeout=10), 0)
            proc.stdout.close()
        finally:
            shutil.rmtree(home)


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.real = (hue.CONFIG_DIR, hue.CONFIG_PATH)
        self.dir = tempfile.mkdtemp()
        hue.CONFIG_DIR = os.path.join(self.dir, "hue-lights")
        hue.CONFIG_PATH = os.path.join(hue.CONFIG_DIR, "config.json")

    def tearDown(self):
        hue.CONFIG_DIR, hue.CONFIG_PATH = self.real
        shutil.rmtree(self.dir)

    def test_private_modes_and_round_trip(self):
        config = {"ip": "192.168.1.50", "bridge_id": BRIDGE_ID, "fingerprint": "a" * 64,
                  "app_key": "abcDEF-123_x", "name": "Hue", "model": "BSB002"}
        hue.save_config(config)
        self.assertEqual(stat.S_IMODE(os.stat(hue.CONFIG_PATH).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(hue.CONFIG_DIR).st_mode), 0o700)
        self.assertEqual(hue.load_config(), config)
        self.assertTrue(hue.remove_config())
        self.assertEqual(hue.load_config(), {})

    def test_ui_settings_file_beside_it_is_left_alone(self):
        """The Swift app keeps its language in settings.json in the same folder."""
        os.makedirs(hue.CONFIG_DIR, mode=0o700)
        settings = os.path.join(hue.CONFIG_DIR, "settings.json")
        with open(settings, "w") as fh:
            json.dump({"language": "de"}, fh)
        hue.save_config({"ip": "192.168.1.50", "bridge_id": BRIDGE_ID, "fingerprint": "a" * 64,
                         "app_key": "k" * 40})
        hue.remove_config()
        with open(settings) as fh:
            self.assertEqual(json.load(fh), {"language": "de"})


def make_cert(directory):
    cert, key = os.path.join(directory, "c.pem"), os.path.join(directory, "k.pem")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                    "-subj", "/CN=" + BRIDGE_ID, "-keyout", key, "-out", cert],
                   check=True, capture_output=True)
    return cert, key


@unittest.skipUnless(shutil.which("openssl"), "openssl CLI needed to make a test certificate")
class ProbeTests(unittest.TestCase):
    """A local TLS 'bridge': the pinned-certificate path works with the system Python's ssl
    (OpenSSL on Linux / Homebrew, LibreSSL-backed /usr/bin/python3 on macOS)."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        cert, key = make_cert(self.dir)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(cert, key)
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(8)
        self.port = self.sock.getsockname()[1]
        self.reply_id = BRIDGE_ID
        self.stop = threading.Event()

        def serve():
            self.sock.settimeout(0.2)
            while not self.stop.is_set():
                try:
                    conn, _ = self.sock.accept()
                except OSError:
                    continue
                try:
                    tls = ctx.wrap_socket(conn, server_side=True)
                    tls.recv(65536)
                    body = json.dumps({"bridgeid": self.reply_id, "name": "Hue Bridge"}).encode()
                    tls.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n"
                                b"Connection: close\r\n\r\n" % len(body) + body)
                    tls.close()
                except (OSError, ssl.SSLError):
                    conn.close()
        threading.Thread(target=serve, daemon=True).start()
        self.real_port = hue.BRIDGE_PORT
        hue.BRIDGE_PORT = self.port

    def tearDown(self):
        hue.BRIDGE_PORT = self.real_port
        self.stop.set()
        self.sock.close()
        shutil.rmtree(self.dir)

    def test_probe_accepts_matching_cn(self):
        self.assertEqual(hue.probe_bridge("127.0.0.1"),
                         {"ip": "127.0.0.1", "bridge_id": BRIDGE_ID, "name": "Hue Bridge"})

    def test_probe_rejects_mismatching_cn(self):
        self.reply_id = "001788FFFE000000"
        self.assertIsNone(hue.probe_bridge("127.0.0.1"))

    def test_probe_closed_port(self):
        hue.BRIDGE_PORT = 1
        self.assertIsNone(hue.probe_bridge("127.0.0.1"))


ROOT = os.path.abspath(os.path.join(HERE, ".."))


def read(*parts):
    with open(os.path.join(ROOT, *parts), encoding="utf-8") as fh:
        return fh.read()


class SwiftAppTests(unittest.TestCase):
    """Static checks of the macOS app sources and scripts (they build only on macOS)."""

    def swift_sources(self):
        for base, _, files in os.walk(os.path.join(ROOT, "Sources")):
            for name in files:
                if name.endswith(".swift"):
                    with open(os.path.join(base, name), encoding="utf-8") as fh:
                        yield name, fh.read()

    def test_every_swift_text_is_translated(self):
        import re
        keys = set()
        for _, text in self.swift_sources():
            keys.update(json.loads('"' + m + '"') for m in re.findall(r'\btrf?\(\s*"((?:[^"\\]|\\.)*)"', text))
        self.assertGreater(len(keys), 30)
        bundled = json.loads(read("translations", "bundled.json"))
        for code in ("en", "de", "fr", "es", "it", "pt", "nl", "pl"):
            missing = keys - bundled[code].keys()
            self.assertEqual(missing, set(), code)
            for key in keys:
                values = bundled[code][key] if isinstance(bundled[code][key], list) else [bundled[code][key]]
                for value in values:
                    self.assertEqual(set(re.findall(r"\{\d+\}", key)), set(re.findall(r"\{\d+\}", value)), (code, key))

    def test_menu_bar_extra_window_and_targets(self):
        package = read("Package.swift")
        self.assertIn(".macOS(.v13)", package)
        self.assertIn('path: "Sources/MaprismaHueLights"', package)
        app = read("Sources", "MaprismaHueLights", "MaprismaHueLightsApp.swift")
        self.assertIn("MenuBarExtra", app)
        self.assertIn(".menuBarExtraStyle(.window)", app)
        self.assertIn('Window("Maprisma Lights", id: "main-window")', app)
        self.assertIn('"lightbulb.fill" : "lightbulb"', app)
        content = read("Sources", "MaprismaHueLights", "ContentView.swift")
        self.assertIn(".frame(width: 440, height: 620)", content)

    def test_pure_swift_and_sandbox_contract(self):
        self.assertFalse(os.path.exists(os.path.join(ROOT, "Sources", "HueCore", "HelperSupervisor.swift")))
        native = read("Sources", "HueCore", "NativeHueBridgeClient.swift")
        self.assertIn("NWBrowser", native)
        self.assertIn("SecTrustCopyCertificateChain", native)
        self.assertIn("/eventstream/clip/v2", native)
        demo = read("Sources", "HueCore", "DemoBridgeClient.swift")
        self.assertIn("DemoBridgeClient", demo)
        rules = read("Sources", "HueCore", "RuleEngine.swift")
        self.assertIn("detectCycles", rules)
        loc = read("Sources", "HueCore", "ResourceLocator.swift")
        self.assertIn('"translations/bundled.json"', loc)
        debounce = read("Sources", "HueCore", "BrightnessDebouncer.swift")
        self.assertIn("interval: TimeInterval = 0.15", debounce)
        entitlements = read("MacAppStore", "MaprismaHueLights.entitlements")
        self.assertIn("com.apple.security.app-sandbox", entitlements)
        self.assertIn("com.apple.security.network.client", entitlements)
        self.assertIn("com.apple.security.device.audio-input", entitlements)
        privacy = read("MacAppStore", "PrivacyInfo.xcprivacy")
        self.assertIn("NSPrivacyTracking", privacy)
        self.assertIn("HueLightTheme", read("Sources", "HueCore", "LightThemes.swift"))
        self.assertIn("HueStreamPacket", read("Sources", "HueCore", "EntertainmentStreamer.swift"))
        self.assertIn("AudioAnalyzer", read("Sources", "HueCore", "AudioAnalyzer.swift"))
        self.assertIn("AppSkin", read("Sources", "HueCore", "AppSkin.swift"))
        self.assertIn("RegisterEventHotKey", read("Sources", "MaprismaHueLights", "GlobalHotKeyManager.swift"))
        self.assertIn("AppShortcutsProvider", read("Sources", "MaprismaHueLights", "HueAppIntents.swift"))
        self.assertIn("ScreenCaptureKit", read("Sources", "MaprismaHueLights", "AudioCaptureManager.swift"))
        floorplan = read("Sources", "HueCore", "Floorplan.swift")
        for needle in ("FloorplanDocument", "FloorplanTemplate", "FloorplanBackground", "FloorplanSpatial", "entertainmentPositions"):
            self.assertIn(needle, floorplan)
        map_view = read("Sources", "MaprismaHueLights", "MapView.swift")
        for needle in ("MapView", "QuickSceneScheduleSheet", "QuickWireRuleSheet", "syncAllFloorplanToBridge"):
            self.assertIn(needle, map_view)
        # SwiftUI files must never reference unqualified BackgroundStyle (ambiguous with SwiftUI.BackgroundStyle)
        import re
        for name, text in self.swift_sources():
            if "import SwiftUI" in text:
                self.assertIsNone(re.search(r'(?<!HueCore\.)\bBackgroundStyle\b', text), name)

    def test_build_and_install_scripts(self):
        for name in ("build-mac.sh", "install-mac.sh"):
            self.assertTrue(os.access(os.path.join(ROOT, name), os.X_OK), name)
            subprocess.run(["bash", "-n", os.path.join(ROOT, name)], check=True)
        build = read("build-mac.sh")
        for needle in ("swift build -c release", 'dist/$APP_NAME.app', "Contents/MacOS",
                       "Contents/Resources/PrivacyInfo.xcprivacy", "Contents/Resources/translations",
                       "ITSAppUsesNonExemptEncryption", "<key>LSUIElement</key>\n    <true/>",
                       'codesign --force --deep -s - "$APP"',
                       "NSLocalNetworkUsageDescription", "_hue._tcp"):
            self.assertIn(needle, build)
        self.assertNotIn("hue-lights.py", build)
        install = read("install-mac.sh")
        self.assertIn("./build-mac.sh", install)
        self.assertIn("$HOME/Applications", install)
        self.assertIn("-w /Applications", install)

    def test_ci_workflow(self):
        ci = read(".github", "workflows", "macos-ci.yml")
        self.assertIn("runs-on: macos-latest", ci)
        self.assertIn("python3 -m unittest discover -s tests -v", ci)
        self.assertIn("./build-mac.sh", ci)
        self.assertIn("codesign --verify", ci)


if __name__ == "__main__":
    unittest.main()
