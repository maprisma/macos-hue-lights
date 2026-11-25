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
        self.assertIn('Window("Maprisma Lights", id: "main-window")', app)
        self.assertIn(".windowResizability(.contentMinSize)", app)
        self.assertIn("NSStatusBar.system.statusItem", app)
        self.assertIn('"lightbulb.fill" : "lightbulb"', app)
        content = read("Sources", "MaprismaHueLights", "ContentView.swift")
        self.assertIn("maxWidth: .infinity", content)
        self.assertIn("isMovableByWindowBackground = false", content)

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
        for needle in (
            "FloorplanDocument",
            "FloorplanTemplate",
            "FloorplanBackground",
            "FloorplanSpatial",
            "FloorplanSensorPlacement",
            "entertainmentPositions",
        ):
            self.assertIn(needle, floorplan)
        models = read("Sources", "HueCore", "Models.swift")
        for needle in (
            "HueMotionArea",
            "HueSensor",
            "motionAware",
            "motionActive",
            "BSB003",
            "motionAreaCandidates",
            "motion_area_candidates",
            "decodeIfPresent(Int.self, forKey: .motionAreaCandidates)",
        ):
            self.assertIn(needle, models)
        help_view = read("Sources", "MaprismaHueLights", "HelpView.swift")
        for needle in (
            "struct HelpView",
            "enum HelpFeature",
            "selectedFeature",
            "onTryFeature",
            "drawPreview",
            "height: 200",
            "All features",
            "Tap for step-by-step guide",
            "How to do it",
            "Quick Tip",
            "Try it now",
            "TimelineView",
            "MotionAware",
            "Canvas",
            "case lights, floorplan, rules, motionAware, schedules, synth, skins, askAI, mcpServer",
            "Ask AI (Optional)",
            "MCP Server for AI Agents",
            "drawAskAIPreview",
            "drawMCPPreview",
        ):
            self.assertIn(needle, help_view)
        rooms_view = read("Sources", "MaprismaHueLights", "RoomsView.swift")
        for needle in (
            "struct MotionAwareSetupHintBanner",
            "shouldShowMotionAwareSetupHint",
            "Bridge Pro MotionAware™ Ready",
            "1. Open the Philips Hue mobile app → Settings → MotionAware",
            "ellipsis.circle",
            "Brightness…",
            "Color & Warmth…",
            "Rename…",
            "Lamp icon…",
            "Wire rule on Map",
            "LampBrightnessSheet",
            "LampRenameSheet",
            "LampIconPickerSheet",
            "store.lampIcon(for: light)",
            "openMapInRulesMode",
        ):
            self.assertIn(needle, rooms_view)
        hue_store = read("Sources", "MaprismaHueLights", "HueStore.swift")
        for needle in (
            "shouldShowMotionAwareSetupHint",
            "motionAwareEligibleRooms",
            "motionAwareHintDismissed",
            "openMapInRulesMode",
            "func lampIcon(for light: HueLight)",
        ):
            self.assertIn(needle, hue_store)
        settings_store = read("Sources", "HueCore", "SettingsStore.swift")
        for needle in (
            "public var askAIEnabled: Bool = false",
            'public var askAIOllamaURL: String = AppSettings.defaultAskAIOllamaURL',
            'public var askAIModel: String = ""',
            "decodeIfPresent(Bool.self, forKey: .askAIEnabled) ?? false",
        ):
            self.assertIn(needle, settings_store)
        ai_mcp = read("Sources", "HueCore", "HueAIAndMCP.swift")
        for needle in (
            "struct HueAskAIEngine: Sendable",
            "class HueMCPServer",
            "validatedLocalOllamaEndpoint",
            "#if canImport(FoundationModels)",
            "hue://state",
            "hue_status",
            "hue_list_rooms",
            "hue_list_lights",
            "hue_list_sensors",
            "hue_list_themes",
            "hue_list_rules",
            "hue_list_schedules",
            "hue_get_floorplan",
            "hue_set_light",
            "hue_set_room",
            "hue_recall_scene",
            "hue_apply_theme",
            "hue_all_on",
            "hue_all_off",
            "hue_set_sensor",
            "hue_set_motion_area",
            "hue_create_rule",
            "hue_toggle_rule",
            "hue_delete_rule",
        ):
            self.assertIn(needle, ai_mcp)
        ask_view = read("Sources", "MaprismaHueLights", "AskAIView.swift")
        for needle in ("struct AskAIView", "Optional · Local-first · Turn off anytime in Settings", "runAskAIPrompt"):
            self.assertIn(needle, ask_view)
        content_view = read("Sources", "MaprismaHueLights", "ContentView.swift")
        self.assertIn("if store.askAIEnabled", content_view)
        self.assertIn('.keyboardShortcut("k", modifiers: .command)', content_view)
        self.assertIn("HelpView(onTryFeature:", content_view)
        self.assertIn("handleTryHelpFeature", content_view)
        settings_view = read("Sources", "MaprismaHueLights", "SettingsView.swift")
        self.assertIn("Enable Ask AI", settings_view)
        self.assertIn("if store.askAIEnabled", settings_view)
        app_entry = read("Sources", "MaprismaHueLights", "MaprismaHueLightsApp.swift")
        self.assertIn('CommandLine.arguments.contains("--mcp")', app_entry)
        self.assertIn("HueMCPServer.runStdio", app_entry)
        map_view = read("Sources", "MaprismaHueLights", "MapView.swift")
        for needle in (
            "MapView",
            "MapMode",
            "LampDialogSheet",
            "LampBrightnessSheet",
            "LampRenameSheet",
            "LampIconPickerSheet",
            "MapRuleDialogSheet",
            "QuickSceneScheduleSheet",
            "FloorplanSensorNodeView",
            "dot.radiowaves.left.and.right",
            "syncAllFloorplanToBridge",
            "MotionAwareSetupHintBanner",
            "consumePendingMapNavigation",
        ):
            self.assertIn(needle, map_view)
        # SwiftUI files must never reference unqualified BackgroundStyle (ambiguous with SwiftUI.BackgroundStyle)
        import re
        for name, text in self.swift_sources():
            if "import SwiftUI" in text:
                self.assertIsNone(re.search(r'(?<!HueCore\.)\bBackgroundStyle\b', text), name)
            # Ensure no macOS 14+ only SwiftUI APIs leak into macOS 13 target
            self.assertNotIn("@Observable", text, name)
            self.assertNotIn(".contentMargins(", text, name)
            self.assertNotIn(".symbolEffect(", text, name)

    def test_swift_delimiters_balanced(self):
        """Catch stray braces/brackets/parens in all Swift sources & tests before macOS CI builds."""
        def check_file(path):
            src = open(path, encoding="utf-8").read()
            stack = []
            pairs = {")": "(", "]": "[", "}": "{"}
            i, n = 0, len(src)
            while i < n:
                ch = src[i]
                nxt = src[i + 1] if i + 1 < n else ""
                # Line comment
                if ch == "/" and nxt == "/":
                    nl = src.find("\n", i)
                    i = n if nl == -1 else nl + 1
                    continue
                # Block comment (nested)
                if ch == "/" and nxt == "*":
                    depth = 1
                    i += 2
                    while i < n and depth > 0:
                        if src[i:i + 2] == "/*":
                            depth += 1
                            i += 2
                        elif src[i:i + 2] == "*/":
                            depth -= 1
                            i += 2
                        else:
                            i += 1
                    continue
                # Raw strings #"..."# or #"""..."""#
                if ch == "#":
                    hashes = 0
                    j = i
                    while j < n and src[j] == "#":
                        hashes += 1
                        j += 1
                    if j < n and src[j] == '"':
                        triple = src[j:j + 3] == '"""'
                        delim = ('"""' if triple else '"') + ("#" * hashes)
                        i = j + (3 if triple else 1)
                        while i < n:
                            if src.startswith(delim, i):
                                i += len(delim)
                                break
                            i += 1
                        continue
                # Normal or multiline string literal
                if ch == '"':
                    triple = src[i:i + 3] == '"""'
                    if triple:
                        i += 3
                        while i < n:
                            if src[i:i + 3] == '"""':
                                i += 3
                                break
                            if src[i] == "\\":
                                i += 2
                                continue
                            i += 1
                        continue
                    i += 1
                    while i < n:
                        if src[i] == "\\":
                            if i + 1 < n and src[i + 1] == "(":
                                # String interpolation: skip matching parens conservatively
                                i += 2
                                interp = 1
                                while i < n and interp > 0:
                                    if src[i] == "(":
                                        interp += 1
                                    elif src[i] == ")":
                                        interp -= 1
                                    elif src[i] == '"':
                                        i += 1
                                        while i < n and src[i] != '"':
                                            if src[i] == "\\":
                                                i += 2
                                                continue
                                            i += 1
                                    i += 1
                                continue
                            i += 2
                            continue
                        if src[i] == '"':
                            i += 1
                            break
                        i += 1
                    continue
                if ch in "([{":
                    stack.append((ch, i))
                elif ch in ")]}":
                    self.assertTrue(stack, f"Unmatched {ch} in {path}")
                    top, _ = stack.pop()
                    self.assertEqual(top, pairs[ch], f"Mismatched {top} vs {ch} in {path}")
                i += 1
            self.assertEqual(stack, [], f"Unclosed delimiters in {path}: {stack}")

        for folder in ("Sources", "Tests"):
            for base, _, files in os.walk(os.path.join(ROOT, folder)):
                for name in files:
                    if name.endswith(".swift"):
                        check_file(os.path.join(base, name))

    def test_motion_aware_setup_hint_contract(self):
        models = read("Sources", "HueCore", "Models.swift")
        native = read("Sources", "HueCore", "NativeHueBridgeClient.swift")
        demo = read("Sources", "HueCore", "DemoBridgeClient.swift")
        store = read("Sources", "MaprismaHueLights", "HueStore.swift")
        rooms = read("Sources", "MaprismaHueLights", "RoomsView.swift")
        map_view = read("Sources", "MaprismaHueLights", "MapView.swift")

        self.assertIn("public var motionAreaCandidates: Int = 0", models)
        self.assertIn("decodeIfPresent(Int.self, forKey: .motionAreaCandidates)", models)
        self.assertIn("motionAreaCandidates = model.motionAreaCandidates", native)
        self.assertIn("motionAreaCandidates: 3", demo)
        self.assertIn("snapshot.bridge?.isPro == true && snapshot.motionAreas.isEmpty && !motionAwareHintDismissed", store)
        self.assertIn("$0.kind == \"room\" && $0.lights.count >= 3", store)
        self.assertIn("MotionAwareSetupHintBanner()", rooms)
        self.assertIn("MotionAwareSetupHintBanner()", map_view)
        self.assertIn("Bridge Pro MotionAware™ Ready", rooms)

    def test_interactive_help_view_and_steps_contract(self):
        help_view = read("Sources", "MaprismaHueLights", "HelpView.swift")
        content = read("Sources", "MaprismaHueLights", "ContentView.swift")

        self.assertIn("enum HelpFeature: Int, CaseIterable, Identifiable", help_view)
        self.assertIn("@State private var selectedFeature: HelpFeature? = nil", help_view)
        self.assertIn("var onTryFeature: ((HelpFeature) -> Void)? = nil", help_view)
        self.assertIn(".frame(height: 200)", help_view)
        self.assertIn("private func drawPreview(", help_view)
        self.assertIn("private func steps(for feature: HelpFeature) -> [String]", help_view)
        self.assertIn("private func tip(for feature: HelpFeature) -> String", help_view)
        self.assertIn(".keyboardShortcut(.cancelAction)", help_view)
        self.assertIn("HelpView(onTryFeature:", content)
        for case_name in ("lights", "floorplan", "rules", "motionAware", "schedules", "synth", "skins", "askAI", "mcpServer"):
            self.assertIn(f"case .{case_name}:", help_view)

    def test_rooms_view_unified_light_submenu_contract(self):
        rooms = read("Sources", "MaprismaHueLights", "RoomsView.swift")
        map_view = read("Sources", "MaprismaHueLights", "MapView.swift")
        store = read("Sources", "MaprismaHueLights", "HueStore.swift")

        self.assertIn('Image(systemName: "ellipsis.circle")', rooms)
        self.assertIn("chosenIcon.sfSymbol(lit: light.on)", rooms)
        for action in ("Brightness…", "Color & Warmth…", "Rename…", "Lamp icon…", "Wire rule on Map", "Pin to Favorites", "Remove from Favorites"):
            self.assertIn(action, rooms)
        self.assertIn("struct LampBrightnessSheet: View", map_view)
        self.assertIn("struct LampRenameSheet: View", map_view)
        self.assertIn("struct LampIconPickerSheet: View", map_view)
        self.assertIn("func openMapInRulesMode(wiringLightID: String? = nil)", store)

    def test_pro_access_storekit2_and_paywall_contract(self):
        pro_access = read("Sources", "HueCore", "ProAccess.swift")
        for needle in (
            "public enum AppAccessMode: String, Codable, Sendable, Equatable",
            "public enum ProFeature: String, CaseIterable, Identifiable, Sendable",
            "case floorplan",
            "case rules",
            "case motionAware",
            "case audioSynth",
            "case skins",
            "case askAI",
            "public struct ProAccessPolicy: Sendable",
            'public static let proProductID = "com.maprisma.lights.pro"',
            "public static func mode(isProUnlocked: Bool, isDemoMode: Bool) -> AppAccessMode",
            "public static func isUnlocked(_ feature: ProFeature, isProUnlocked: Bool, isDemoMode: Bool) -> Bool",
            "public static func isSkinFree(_ skin: String) -> Bool",
        ):
            self.assertIn(needle, pro_access)
        # A6: MCP server is free and not listed as a Pro feature
        self.assertNotIn("case mcp", pro_access)

        pro_manager = read("Sources", "MaprismaHueLights", "ProStoreManager.swift")
        for needle in (
            "import StoreKit",
            "@MainActor",
            "final class ProStoreManager: ObservableObject",
            "Transaction.currentEntitlements",
            "Transaction.updates",
            "AppStore.sync()",
            "effectiveProUnlocked",
            "debugOverridePro",
            "formattedPrice",
            "isProductLoaded",
            "purchasePro()",
            "restorePurchases()",
            "ProAccessPolicy.proProductID",
            "revocationDate == nil",
        ):
            self.assertIn(needle, pro_manager)
        self.assertNotIn("@Observable", pro_manager)
        # A7: No hard-coded fallback price
        self.assertNotIn('"€9.99"', pro_manager)

        pro_view = read("Sources", "MaprismaHueLights", "ProUpgradeView.swift")
        for needle in (
            "struct ProUpgradeView: View",
            "struct ProLockedOverlay: View",
            "struct ProFeatureGateBanner: View",
            "Maprisma Lights Pro",
            "One-time purchase · No subscription",
            "Restore Purchases",
            "Try free in Demo Mode",
            "Try in Demo Mode",
            "Optional local-first Ask AI",
            "Loading price…",
        ):
            self.assertIn(needle, pro_view)
        self.assertNotIn("Maprisma Hue Lights Pro", pro_view)

        # A1 & A4: Entitlements and local networking ATS in both project.yml and build-mac.sh
        ent = read("MacAppStore", "MaprismaHueLights.entitlements")
        self.assertIn("com.apple.security.files.user-selected.read-only", ent)
        self.assertIn("com.apple.security.network.server", ent)
        proj = read("MacAppStore", "project.yml")
        self.assertIn("NSAllowsLocalNetworking: true", proj)
        bsh = read("build-mac.sh")
        self.assertIn("<key>NSAllowsLocalNetworking</key>", bsh)
        sk = read("MacAppStore", "MaprismaHueLights.storekit")
        self.assertIn("Maprisma Lights Pro", sk)
        self.assertNotIn("Maprisma Hue Lights Pro", sk)

        app = read("Sources", "MaprismaHueLights", "MaprismaHueLightsApp.swift")
        self.assertIn("@StateObject private var proStore = ProStoreManager()", app)
        self.assertIn(".environmentObject(proStore)", app)

        content = read("Sources", "MaprismaHueLights", "ContentView.swift")
        self.assertIn("ProUpgradeView()", content)
        self.assertIn("proStore.start()", content)
        self.assertIn("Connect Bridge", content)

        settings_view = read("Sources", "MaprismaHueLights", "SettingsView.swift")
        for needle in (
            "Pro / License",
            "Pro — Unlocked",
            "Demo Mode (All Pro features preview)",
            "Free — Rooms & Lights",
            "Unlock Pro…",
            "Restore Purchases",
            "StoreKit Live",
            "Simulate Free",
            "Simulate Pro",
            "isSkinUnlocked",
        ):
            self.assertIn(needle, settings_view)

        for view_name, feature_token in (
            ("MapView.swift", ".floorplan"),
            ("RulesView.swift", ".rules"),
            ("SynthView.swift", ".audioSynth"),
        ):
            view_src = read("Sources", "MaprismaHueLights", view_name)
            self.assertIn("ProLockedOverlay(", view_src, view_name)
            self.assertIn(feature_token, view_src, view_name)

        rooms_view = read("Sources", "MaprismaHueLights", "RoomsView.swift")
        self.assertIn("proStore.isUnlocked(.motionAware", rooms_view)
        self.assertIn("proStore.isUnlocked(.rules", rooms_view)

        storekit_raw = read("MacAppStore", "MaprismaHueLights.storekit")
        storekit = json.loads(storekit_raw)
        self.assertIn("products", storekit)
        self.assertEqual(len(storekit["products"]), 1)
        prod = storekit["products"][0]
        self.assertEqual(prod["productID"], "com.maprisma.lights.pro")
        self.assertEqual(prod["type"], "NonConsumable")
        self.assertEqual(prod["displayPrice"], "9.99")
        locales = {loc["locale"] for loc in prod["localizations"]}
        self.assertTrue({"en_US", "de_DE"}.issubset(locales))

        launch_kit = read("MacAppStore", "LAUNCH-KIT.md")
        self.assertIn("com.maprisma.lights.pro", launch_kit)
        self.assertIn("MaprismaHueLights.storekit", launch_kit)

    def test_build_and_install_scripts(self):
        for name in ("build-mac.sh", "install-mac.sh"):
            self.assertTrue(os.access(os.path.join(ROOT, name), os.X_OK), name)
            subprocess.run(["bash", "-n", os.path.join(ROOT, name)], check=True)
        build = read("build-mac.sh")
        for needle in ("swift build -c release", 'dist/$APP_NAME.app', "Contents/MacOS",
                       "Contents/Resources/PrivacyInfo.xcprivacy", "Contents/Resources/translations",
                       "ITSAppUsesNonExemptEncryption", "<key>LSUIElement</key>\n    <false/>",
                       'codesign --force --deep -s - "$APP"',
                       "NSLocalNetworkUsageDescription", "_hue._tcp"):
            self.assertIn(needle, build)
        self.assertNotIn("hue-lights.py", build)
        install = read("install-mac.sh")
        self.assertIn("./build-mac.sh", install)
        self.assertIn("$HOME/Applications", install)
        self.assertIn("-w /Applications", install)

    def test_multi_provider_architecture_contract(self):
        models = read("Sources", "HueCore", "MultiProviderModels.swift")
        clients = read("Sources", "HueCore", "MultiProviderClients.swift")
        coord = read("Sources", "HueCore", "MultiProviderCoordinator.swift")
        view = read("Sources", "MaprismaHueLights", "ProvidersView.swift")
        pairing = read("Sources", "MaprismaHueLights", "PairingView.swift")
        settings = read("Sources", "MaprismaHueLights", "SettingsView.swift")
        build = read("build-mac.sh")
        proj = read("MacAppStore", "project.yml")

        for kind in ("homeAssistant", "wled", "wiz", "lifx", "govee", "nanoleaf", "shelly", "dirigera"):
            self.assertIn(f"case {kind}", models)
        for parser in ("HomeAssistantParser", "WLEDParser", "WiZCodec", "LIFXCodec", "GoveeCodec", "NanoleafParser", "ShellyParser", "DirigeraParser"):
            self.assertIn(parser, clients)
        self.assertIn("class MultiProviderBridgeClient: HueBridgeControlling", coord)
        self.assertIn("struct AddProviderSheet: View", view)
        self.assertIn("struct ProviderBadge: View", view)
        self.assertIn("LightProviderKind.extraProviders", pairing)
        self.assertIn("extraProvidersSection", settings)
        for svc in ("_hue._tcp", "_home-assistant._tcp", "_wled._tcp", "_nanoleafapi._tcp", "_shelly._tcp", "_ihsp._tcp"):
            self.assertIn(svc, build)
            self.assertIn(svc, proj)

    def test_ci_workflow(self):
        ci = read(".github", "workflows", "macos-ci.yml")
        self.assertIn("runs-on: macos-latest", ci)
        self.assertIn("python3 -m unittest discover -s tests -v", ci)
        self.assertIn("./build-mac.sh", ci)
        self.assertIn("codesign --verify", ci)


if __name__ == "__main__":
    unittest.main()
