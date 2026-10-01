"""Offline contract tests for the deliberately limited VLESS sharing codec."""

from copy import deepcopy
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from urllib.parse import quote


SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
SPEC = importlib.util.spec_from_file_location("xray_skill_links", SCRIPTS / "links.py")
links = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(links)
ID = "7b78551a-c296-4578-b146-0b66c0c1b246"


def node(transport="raw", security="tls"):
    result = {
        "tag": "proxy", "protocol": "vless",
        "settings": {"vnext": [{"address": "example.test", "port": 8443,
                                  "users": [{"id": ID, "encryption": "none"}]}]},
        "streamSettings": {"network": transport, "security": security},
    }
    if security == "tls":
        result["streamSettings"]["tlsSettings"] = {
            "serverName": "sni.example.test", "alpn": ["h2", "http/1.1"],
            "fingerprint": "chrome",
        }
    elif security == "reality":
        result["streamSettings"]["realitySettings"] = {
            "serverName": "sni.example.test", "fingerprint": "chrome",
            "password": "reference-client-credential", "shortId": "0123456789abcdef",
        }
    names = {"xhttp": "xhttpSettings", "ws": "wsSettings", "grpc": "grpcSettings",
             "httpupgrade": "httpupgradeSettings"}
    if transport in names:
        settings = {"serviceName": "example"} if transport == "grpc" else {
            "host": "host.example.test", "path": "/node/path",
        }
        if transport == "xhttp":
            settings["mode"] = "auto"
        result["streamSettings"][names[transport]] = settings
    return result


def minimal_uri(query="encryption=none&security=none&type=tcp", authority=None):
    return f"vless://{ID}@{authority or 'example.test:443'}?{query}#example"


class LinksTests(unittest.TestCase):
    def assert_roundtrip(self, outbound, label="example"):
        before = deepcopy(outbound)
        uri = links.encode_uri(outbound, label)
        self.assertEqual(links.decode_uri(uri), {"outbound": outbound, "label": label})
        self.assertEqual(outbound, before, "encoding must not mutate the source configuration")
        return uri

    def test_supported_transports_and_security_roundtrip(self):
        for transport in ("raw", "xhttp", "ws", "grpc", "httpupgrade"):
            for security in ("none", "tls", "reality"):
                with self.subTest(transport=transport, security=security):
                    # The codec tests mapping, not whether the target core accepts a combination.
                    self.assert_roundtrip(node(transport, security))

    def test_unicode_and_reserved_characters_are_percent_encoded(self):
        outbound = node("xhttp")
        outbound["streamSettings"]["xhttpSettings"]["path"] = "/路径/?a=1&b=空 格+%#"
        uri = self.assert_roundtrip(outbound, "节点 🐉 / &?#%+ space")
        self.assertNotIn("空", uri)
        self.assertNotIn(" ", uri)
        self.assertIn("%26", uri)
        self.assertIn("%2B", uri)
        self.assertIn("%23", uri)

    def test_ipv6_has_brackets(self):
        outbound = node("raw", "reality")
        outbound["settings"]["vnext"][0]["address"] = "2001:db8::1"
        uri = self.assert_roundtrip(outbound)
        self.assertIn("@[2001:db8::1]:8443?", uri)

    def test_ipv4_localhost_and_hostname_case(self):
        for address in ("127.0.0.1", "localhost", "EXAMPLE.test."):
            outbound = node()
            outbound["settings"]["vnext"][0]["address"] = address
            self.assert_roundtrip(outbound)

    def test_opaque_encryption_and_flow_roundtrip(self):
        outbound = node("raw", "reality")
        user = outbound["settings"]["vnext"][0]["users"][0]
        user["encryption"] = "mlkem768x25519plus.native.0rtt.reference+test/credential="
        user["flow"] = "xtls-rprx-vision-udp443"
        uri = self.assert_roundtrip(outbound)
        self.assertIn("%2B", uri)
        self.assertIn("flow=xtls-rprx-vision-udp443", uri)

    def test_empty_but_meaningful_values_survive(self):
        outbound = node("xhttp", "tls")
        outbound["streamSettings"]["xhttpSettings"] = {"host": "", "path": "", "mode": ""}
        outbound["streamSettings"]["tlsSettings"]["alpn"] = []
        outbound["settings"]["vnext"][0]["users"][0]["flow"] = ""
        self.assert_roundtrip(outbound, "")
        outbound = node("raw", "reality")
        outbound["streamSettings"]["realitySettings"]["shortId"] = ""
        self.assert_roundtrip(outbound)

    def test_native_aliases_have_documented_canonical_form(self):
        for alias, canonical in (("tcp", "raw"), ("splithttp", "xhttp"), ("websocket", "ws")):
            outbound = node(canonical)
            expected = deepcopy(outbound)
            outbound["streamSettings"]["method"] = alias
            del outbound["streamSettings"]["network"]
            self.assertEqual(links.decode_uri(links.encode_uri(outbound, "alias"))["outbound"], expected)
        outbound = node("raw", "reality")
        expected = deepcopy(outbound)
        reality = outbound["streamSettings"]["realitySettings"]
        reality["publicKey"] = reality.pop("password")
        self.assertEqual(links.decode_uri(links.encode_uri(outbound, "alias"))["outbound"], expected)
        outbound = node("ws")
        expected = deepcopy(outbound)
        ws = outbound["streamSettings"]["wsSettings"]
        ws["headers"] = {"HoSt": ws.pop("host")}
        self.assertEqual(links.decode_uri(links.encode_uri(outbound, "alias"))["outbound"], expected)

    def test_competing_native_aliases_rejected_even_when_equal(self):
        outbound = node()
        outbound["streamSettings"]["method"] = "raw"
        with self.assertRaises(links.LinkUnsupported):
            links.encode_uri(outbound, "")
        outbound = node("raw", "reality")
        reality = outbound["streamSettings"]["realitySettings"]
        reality["publicKey"] = reality["password"]
        with self.assertRaises(links.LinkUnsupported):
            links.encode_uri(outbound, "")
        outbound = node("xhttp")
        outbound["streamSettings"]["splithttpSettings"] = outbound["streamSettings"]["xhttpSettings"]
        with self.assertRaises(links.LinkUnsupported):
            links.encode_uri(outbound, "")

    def test_complex_xhttp_and_ech_require_json(self):
        for key, value in (("extra", {}), ("downloadSettings", {"address": "example.test"}),
                           ("xmux", {"maxConnections": 3}), ("xPaddingObfsMode", True)):
            outbound = node("xhttp")
            outbound["streamSettings"]["xhttpSettings"][key] = value
            with self.subTest(field=key), self.assertRaises(links.LinkUnsupported):
                links.encode_uri(outbound, "")
        outbound = node()
        outbound["streamSettings"]["tlsSettings"]["echConfigList"] = "test-ech"
        with self.assertRaises(links.LinkUnsupported):
            links.encode_uri(outbound, "")

    def test_unknown_fields_at_every_level_are_not_dropped(self):
        for location in ("outbound", "settings", "endpoint", "user", "stream", "tls", "transport"):
            outbound = node("xhttp")
            endpoint = outbound["settings"]["vnext"][0]
            levels = {
                "outbound": outbound, "settings": outbound["settings"], "endpoint": endpoint,
                "user": endpoint["users"][0], "stream": outbound["streamSettings"],
                "tls": outbound["streamSettings"]["tlsSettings"],
                "transport": outbound["streamSettings"]["xhttpSettings"],
            }
            levels[location]["unmappedSetting"] = "must-not-be-lost"
            with self.subTest(location=location), self.assertRaises(links.LinkUnsupported):
                links.encode_uri(outbound, "")

    def test_server_secrets_and_custom_tags_require_json(self):
        for key in ("privateKey", "decryption", "mldsa65Seed"):
            outbound = node("raw", "reality")
            outbound["streamSettings"]["realitySettings"][key] = "do-not-log-this-secret"
            with self.subTest(key=key), self.assertRaises(links.LinkUnsupported) as caught:
                links.encode_uri(outbound, "")
            self.assertNotIn("do-not-log-this-secret", str(caught.exception))
        outbound = node()
        outbound["tag"] = "routing-relevant-custom-tag"
        with self.assertRaises(links.LinkUnsupported):
            links.encode_uri(outbound, "")

    def test_multiple_users_endpoints_and_non_vless_rejected(self):
        for case in ("users", "endpoints", "protocol"):
            outbound = node()
            if case == "users":
                endpoint = outbound["settings"]["vnext"][0]
                endpoint["users"].append(deepcopy(endpoint["users"][0]))
            elif case == "endpoints":
                outbound["settings"]["vnext"].append(deepcopy(outbound["settings"]["vnext"][0]))
            else:
                outbound["protocol"] = "trojan"
            with self.subTest(case=case), self.assertRaises(links.LinkUnsupported):
                links.encode_uri(outbound, "")

    def test_private_tls_trust_and_insecure_fields_are_not_lost(self):
        for key, value in (("certificates", []), ("allowInsecure", False), ("allowInsecure", True)):
            outbound = node()
            outbound["streamSettings"]["tlsSettings"][key] = value
            with self.subTest(key=key, value=value), self.assertRaises(links.LinkUnsupported):
                links.encode_uri(outbound, "")

    def test_ports_must_be_real_valid_integers(self):
        for value in (0, -1, 65536, True, 443.0, "443", None):
            outbound = node()
            outbound["settings"]["vnext"][0]["port"] = value
            with self.subTest(value=value), self.assertRaises(links.LinkUnsupported):
                links.encode_uri(outbound, "")
        for port in (1, 65535):
            outbound = node()
            outbound["settings"]["vnext"][0]["port"] = port
            self.assert_roundtrip(outbound)

    def test_addresses_reject_url_injection_and_scoped_ipv6(self):
        for address in ("example.test@evil.test", "example.test/path", "bad host", "bad\nname",
                        "[::1]", "fe80::1%eth0", "999.999.999.999", "例子.test", "a..test", "-bad.test"):
            outbound = node()
            outbound["settings"]["vnext"][0]["address"] = address
            with self.subTest(address=address), self.assertRaises(links.LinkUnsupported):
                links.encode_uri(outbound, "")

    def test_wrong_value_types_and_controls_are_rejected_without_leaks(self):
        for field, value in (("encryption", 3), ("encryption", "secret\nvalue"), ("flow", []), ("id", "not-a-uuid")):
            outbound = node()
            outbound["settings"]["vnext"][0]["users"][0][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(links.LinkUnsupported) as caught:
                links.encode_uri(outbound, "")
            self.assertNotIn("secret", str(caught.exception))
        for alpn in ("h2", [""], ["h2,h3"], [None], ["secret\nvalue"]):
            outbound = node()
            outbound["streamSettings"]["tlsSettings"]["alpn"] = alpn
            with self.subTest(alpn=alpn), self.assertRaises(links.LinkUnsupported):
                links.encode_uri(outbound, "")
        with self.assertRaises(links.LinkUnsupported):
            links.encode_uri(node(), "\ud800")

    def test_short_id_validation(self):
        for value in ("a", "xyz", "01" * 9, 12):
            outbound = node("raw", "reality")
            outbound["streamSettings"]["realitySettings"]["shortId"] = value
            with self.subTest(value=value), self.assertRaises(links.LinkUnsupported):
                links.encode_uri(outbound, "")

    def test_defaults_and_raw_no_header_form(self):
        decoded = links.decode_uri(minimal_uri("headerType=none"))
        self.assertEqual(decoded["outbound"]["streamSettings"], {"network": "raw", "security": "none"})
        self.assertEqual(decoded["outbound"]["settings"]["vnext"][0]["users"][0]["encryption"], "none")
        outbound = node("raw", "none")
        del outbound["tag"]
        del outbound["streamSettings"]
        del outbound["settings"]["vnext"][0]["users"][0]["encryption"]
        self.assertEqual(links.decode_uri(links.encode_uri(outbound, "example"))["outbound"], node("raw", "none"))

    def test_fingerprint_uri_alias_is_canonicalized(self):
        decoded = links.decode_uri(minimal_uri("security=tls&type=tcp&fingerprint=chrome"))
        self.assertEqual(decoded["outbound"]["streamSettings"]["tlsSettings"], {"fingerprint": "chrome"})

    def test_unknown_query_and_duplicates_fail(self):
        for query in ("security=tls&security=tls", "security=tls&fp=chrome&fingerprint=chrome",
                      "security=tls&%66p=chrome&fp=firefox", "security=tls&allowInsecure=0",
                      "security=tls&extra=%7B%7D", "security=tls&ech=abc", "security=none&sni=example.test",
                      "type=grpc&mode=multi", "type=ws&serviceName=wrong-transport", "type=tcp&headerType=http",
                      "type=quic", "security=xtls", "unknown=must-not-disappear", "=value", "key", "security=tls&",
                      "security=tls&encryption=unescaped+key", "encryption=", "type=xhttp&mode=invalid"):
            with self.subTest(query=query), self.assertRaises(links.LinkUnsupported):
                links.decode_uri(minimal_uri(query))

    def test_invalid_uri_encoding_and_authorities_fail(self):
        values = ["https://example.test", " " + minimal_uri(), minimal_uri().replace("vless", "VLESS", 1),
                  minimal_uri().replace("example.test:443", "example.test"), minimal_uri(authority="example.test:0"),
                  minimal_uri(authority="example.test:65536"), minimal_uri(authority="example.test:-1"),
                  minimal_uri(authority="example.test:443.0"), minimal_uri(authority="2001:db8::1:443"),
                  minimal_uri(authority="[example.test]:443"), minimal_uri(authority="[::1:443"),
                  minimal_uri(authority="[fe80::1%25eth0]:443"), minimal_uri(authority="evil@example.test:443"),
                  minimal_uri().replace(ID, ID + ":password"), minimal_uri().replace("?", "/?", 1),
                  minimal_uri("security=tls&sni=%ZZ"), minimal_uri("security=tls&sni=%FF"),
                  minimal_uri("security=tls&sni=%0A"), minimal_uri() + "%", minimal_uri() + "%00",
                  minimal_uri().replace("example.test", "example\n.test")]
        for value in values:
            with self.subTest(uri=value), self.assertRaises(links.LinkUnsupported):
                links.decode_uri(value)

    def test_errors_do_not_echo_uri_credentials(self):
        value = minimal_uri("security=reality&pbk=" + quote("private-client-credential", safe="") + "&secret-field=value")
        with self.assertRaises(links.LinkUnsupported) as caught:
            links.decode_uri(value)
        self.assertNotIn("private-client-credential", str(caught.exception))
        self.assertNotIn(ID, str(caught.exception))

    def test_cli_encode_decode_and_sanitized_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "outbound.json"
            path.write_text(__import__("json").dumps(node("xhttp")))
            encoded = subprocess.run([sys.executable, str(SCRIPTS / "links.py"), "encode", str(path), "--label", "测试"],
                                     capture_output=True, text=True, check=True)
            decoded = subprocess.run([sys.executable, str(SCRIPTS / "links.py"), "decode"], input=encoded.stdout,
                                     capture_output=True, text=True, check=True)
            self.assertEqual(__import__("json").loads(decoded.stdout), {"outbound": node("xhttp"), "label": "测试"})
            invalid = subprocess.run([sys.executable, str(SCRIPTS / "links.py"), "decode"],
                                     input=minimal_uri("security=tls&privateKey=never-log"), capture_output=True, text=True)
            self.assertEqual(invalid.returncode, 2)
            self.assertEqual(invalid.stdout, "")
            self.assertNotIn("never-log", invalid.stderr)


if __name__ == "__main__":
    unittest.main()
