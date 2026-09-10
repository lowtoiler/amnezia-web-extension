import argparse
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]
PARSER = argparse.ArgumentParser()
PARSER.add_argument("--shell", choices=["bash", "pwsh", "powershell"], default="bash")
ARGS, REMAINING = PARSER.parse_known_args()
KEY = base64.b64encode(bytes(range(32))).decode()
PUBLIC = base64.b64encode(bytes(range(32, 64))).decode()
BASE = f"""[Interface]
PrivateKey = {KEY}
Address = 10.7.0.2/32
DNS = 1.1.1.1
[Peer]
PublicKey = {PUBLIC}
Endpoint = vpn.example.test:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
"""

class ConfigTests(unittest.TestCase):
    def convert(self, text=BASE, valid=True):
        with tempfile.TemporaryDirectory(prefix="amnezia-config-test-") as directory:
            folder = Path(directory)
            source, output, secret = [folder / name for name in ("input.conf", "output.yaml", "secret")]
            source.write_bytes(text.encode("utf-8"))
            secret.write_text("a" * 64 + "\n")
            if ARGS.shell == "bash":
                command = ["bash", str(ROOT / "scripts/config.sh"), str(source), str(output), str(secret)]
            else:
                command = [ARGS.shell, "-NoProfile", "-NonInteractive", "-File", str(ROOT / "scripts/config.ps1"),
                           "-InputFile", str(source), "-OutputFile", str(output), "-SecretFile", str(secret)]
            result = subprocess.run(command, capture_output=True, text=True, timeout=20)
            if not valid:
                self.assertNotEqual(result.returncode, 0, "Malformed configuration was accepted")
                return
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            data = yaml.safe_load(output.read_text(encoding="utf-8-sig"))
            self.assertEqual(data["secret"], "a" * 64)
            self.assertEqual(data["mixed-port"], 1080)
            self.assertEqual(data["external-controller"], "127.0.0.1:9090")
            self.assertIs(data["allow-lan"], False)
            self.assertEqual(data["rules"], ["MATCH,AMNEZIA"])
            self.assertIs(data["proxies"][0]["remote-dns-resolve"], True)
            if ARGS.shell != "bash":
                self.assertEqual(data["proxies"][0]["ip-stack"], {"mode": "mips", "congestion-controller": "bbr"})
            return data["proxies"][0]

    def test_plain(self):
        proxy = self.convert()
        self.assertEqual(proxy["ip"], "10.7.0.2")
        self.assertEqual(proxy["server"], "vpn.example.test")
        self.assertEqual(proxy["port"], 51820)
        self.assertEqual(proxy["persistent-keepalive"], 25)
        self.assertNotIn("amnezia-wg-option", proxy)

    def test_bom_crlf_comments_case_and_repeated_lists(self):
        text = BASE.replace("[Interface]", "[interface] # header").replace("PrivateKey", "privatekey")
        text = text.replace("Address = 10.7.0.2/32", "Address = 10.7.0.2/32\nAddress = fd00::2/128")
        text = text.replace("DNS = 1.1.1.1", "DNS = 1.1.1.1\nDNS = 9.9.9.9")
        text = text.replace(":51820", ":51820 # server").replace("AllowedIPs = 0.0.0.0/0", "AllowedIPs = 0.0.0.0/0\nAllowedIPs = ::/0")
        proxy = self.convert("\ufeff" + text.replace("\n", "\r\n"))
        self.assertEqual(proxy["ipv6"], "fd00::2")
        self.assertEqual(proxy["dns"], ["1.1.1.1", "9.9.9.9"])
        self.assertEqual(proxy["allowed-ips"], ["0.0.0.0/0", "::/0"])

    def test_awg_values_and_types(self):
        text = BASE.replace("[Peer]", "Jc = 004\nJmin = 40\nJmax = 70\nS1 = 0\nH1 = 123-456\nI1 = <b 0xdeadbeef>\nRandomTrailers = on\nDisableCookies = off\n[Peer]")
        awg = self.convert(text)["amnezia-wg-option"]
        self.assertEqual(awg["version"], 3)
        self.assertEqual(awg["jc"], 4)
        self.assertEqual(awg["s1"], 0)
        self.assertEqual(awg["h1"], "123-456")
        self.assertEqual(awg["i1"], "<b 0xdeadbeef>")
        self.assertIs(awg["random-trailers"], True)
        self.assertIs(awg["disable-cookies"], False)

    def test_ipv6_endpoint(self):
        proxy = self.convert(BASE.replace("vpn.example.test:51820", "[2001:db8::1]:05182"))
        self.assertEqual(proxy["server"], "2001:db8::1")
        self.assertEqual(proxy["port"], 5182)

    def test_keepalive_off_and_leading_zeroes(self):
        self.assertEqual(self.convert(BASE.replace("= 25", "= off"))["persistent-keepalive"], 0)
        self.assertEqual(self.convert(BASE.replace("= 25", "= 00025"))["persistent-keepalive"], 25)

    def test_reject_invalid_values(self):
        for text in [
            BASE.replace(KEY, "not-a-key"),
            BASE.replace(":51820", ":65536"),
            BASE.replace(":51820", ":0"),
            BASE.replace("= 25", "= nonsense"),
            BASE.replace("= 25", "= 65536"),
            BASE.replace("[Peer]", "MTU = 20\n[Peer]"),
            BASE.replace("[Peer]", "Jc = invalid\n[Peer]"),
            BASE.replace("[Peer]", "RandomTrailers = perhaps\n[Peer]"),
        ]:
            with self.subTest(text=text): self.convert(text, valid=False)

    def test_reject_duplicate_scalars_sections_and_hooks(self):
        for text in [
            BASE.replace("[Peer]", f"PrivateKey = {PUBLIC}\n[Peer]"),
            BASE + "\n[Peer]\nEndpoint = another.test:443\n",
            BASE + "\n[Other]\nValue = 1\n",
            BASE.replace("[Peer]", "PostUp = run-something\n[Peer]"),
            BASE.replace("[Peer]", "UnknownField = 1\n[Peer]"),
            "Address = 10.0.0.1\n" + BASE,
        ]:
            with self.subTest(text=text): self.convert(text, valid=False)

    def test_reject_lossy_addresses_malformed_endpoint_and_integer_overflow(self):
        for text in [
            BASE.replace("[Peer]", "Address = 10.8.0.2/32\\n[Peer]"),
            BASE.replace("[Peer]", "Address = fd00::2/128, fd00::3/128\\n[Peer]"),
            BASE.replace("vpn.example.test:51820", "https://vpn.example.test:51820"),
            BASE.replace("vpn.example.test:51820", "fd00::1:51820"),
            BASE.replace("[Peer]", "Jc = 18446744073709551616\\n[Peer]"),
        ]:
            with self.subTest(text=text): self.convert(text, valid=False)

    def test_yaml_string_injection_is_quoted(self):
        proxy = self.convert(BASE.replace("[Peer]", "H1 = 1' : [x]\n[Peer]"))
        self.assertEqual(proxy["amnezia-wg-option"]["h1"], "1' : [x]")

if __name__ == "__main__":
    if not shutil.which(ARGS.shell):
        raise SystemExit(f"Required test runtime is unavailable: {ARGS.shell}")
    unittest.main(argv=[__file__, *REMAINING])
