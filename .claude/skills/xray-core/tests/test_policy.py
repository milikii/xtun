"""Regressions for generator policy and recently added transport profiles."""
from copy import deepcopy
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from generate import generate, write_bundle
from check_configs import load_bundle
from rules import ConfigError, json_bytes, private_destination, validate_transport


class PolicyTests(unittest.TestCase):
    def request(self):
        return {'version': 'v26.9.30', 'server': {'address': '10.1.2.3', 'port': 8443},
                'transport': {'type': 'raw'}, 'security': {'type': 'none'}, 'trusted_private_network': True}

    def test_private_ranges_not_reserved(self):
        for value in ('10.1.2.3', '172.16.0.1', '192.168.0.1', '127.0.0.1', 'fd00::1', '::1'):
            self.assertTrue(private_destination(value), value)
        for value in ('192.0.2.1', '198.51.100.1', '203.0.113.1', '2001:db8::1', '0.0.0.0', '::', '169.254.1.1', 'example.com'):
            self.assertFalse(private_destination(value), value)
            request = self.request()
            request['server']['address'] = value
            with self.assertRaises(ConfigError):
                generate(request)

    def test_many_users_and_explicit_trust(self):
        request = self.request()
        request['users'] = [{} for _ in range(12)]
        configs, links, manifest = generate(request)
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / 'bundle'
            write_bundle(output, configs, links, manifest)
            self.assertEqual(len(load_bundle(output)[2]), 13)
            manifest.pop('trusted_private_network')
            (output / 'manifest.json').write_bytes(json_bytes(manifest))
            with self.assertRaises(ConfigError):
                load_bundle(output)

    def test_masque_and_xdrive_scope(self):
        validate_transport('v26.9.30', 'masque', {'path': '/test/{target}{?ipproto,target}'}, 'tls')
        for version, name, settings, security in (
            ('v26.3.27', 'masque', {}, 'tls'),
            ('v26.9.30', 'masque', {}, 'none'),
            ('v26.9.30', 'xdrive', {}, 'none'),
            ('v26.9.30', 'masque', {'headers': {'Host': 'example.test'}}, 'tls'),
            ('v26.9.30', 'masque', {'headers': {'Authorization': 'test'}, 'user': 'test'}, 'tls'),
            ('v26.9.30', 'masque', {'user': 'x:y'}, 'tls'),
            ('v26.9.30', 'masque', {'path': '/{unknown}'}, 'tls'),
        ):
            with self.subTest(version=version, name=name, settings=settings):
                with self.assertRaises(ConfigError):
                    validate_transport(version, name, settings, security)


if __name__ == '__main__':
    unittest.main()
