import copy
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from check_configs import audit_pair, load_bundle, private_report, validate_bundle
from generate import generate, write_bundle
from rules import ConfigError, RULES_PATH, config_fields, read_json


def request(version='v26.3.27', transport='raw'):
    return {'version': version, 'server': {'address': 'proxy.example.com', 'port': 8443},
            'transport': {'type': transport}, 'security': {'type': 'tls', 'server_name': 'proxy.example.com',
            'certificate_file': 'server.pem', 'key_file': 'server.key'}}


class GenerationTests(unittest.TestCase):
    def test_all_reviewed_versions_basic_profiles(self):
        import yaml
        for version in yaml.safe_load(RULES_PATH.read_text())['versions']:
            for transport in ('raw', 'xhttp', 'ws', 'grpc', 'httpupgrade'):
                with self.subTest(version=version, transport=transport):
                    configs, links, meta = generate(request(version, transport))
                    audit_pair(configs['server.json'], configs['client.json'], version, version)
                    self.assertEqual(meta['validation']['handshake'], 'not_run')
                    self.assertEqual(len(links), 1)
                    self.assertEqual(configs['client.json']['outbounds'][0]['settings']['vnext'][0]['port'], 8443)

    def test_unknown_versions_and_latest_are_not_guessed(self):
        for version in ('latest', 'latest-stable', 'main', 'v26.1.1'):
            with self.assertRaises(ConfigError):
                generate(request(version))

    def test_unknown_fields_fail_at_each_request_level(self):
        for path in ((), ('server',), ('transport',), ('security',)):
            data = request()
            target = data
            for key in path:
                target = target[key]
            target['misspelled'] = True
            with self.subTest(path=path), self.assertRaises(ConfigError):
                generate(data)

    def test_unknown_native_fields_not_silently_ignored(self):
        data = request(transport='xhttp')
        data['transport']['settings'] = {'mdoe': 'auto'}
        with self.assertRaises(ConfigError):
            generate(data)
        data['transport']['settings'] = {'extra': {}}
        with self.assertRaises(ConfigError):
            generate(data)

    def test_type_and_port_checks(self):
        for value in (True, 0, 65536, '443'):
            data = request()
            data['server']['port'] = value
            with self.assertRaises(ConfigError):
                generate(data)
        data = request(transport='xhttp')
        data['transport']['settings'] = {'noSSEHeader': 'true'}
        with self.assertRaises(ConfigError):
            generate(data)

    def test_ipv6_unicode_and_multiuser(self):
        data = request()
        data['label'] = '节点 & / #'
        data['server']['address'] = '2001:db8::1'
        data['users'] = [{}, {}]
        configs, links, _ = generate(data)
        self.assertIn('client-2.json', configs)
        self.assertIn('@[2001:db8::1]:8443', links[0])
        self.assertIn('%23', links[0])
        self.assertNotEqual(links[0], links[1])

    def test_duplicate_ids_rejected(self):
        data = request()
        user = {'id': '01234567-89ab-4cde-8123-456789abcdef'}
        data['users'] = [user, user]
        with self.assertRaises(ConfigError):
            generate(data)

    def test_flow_and_security_combinations(self):
        data = request(transport='xhttp')
        data['flow'] = 'xtls-rprx-vision'
        with self.assertRaises(ConfigError):
            generate(data)
        data['transport']['type'] = 'raw'
        data['flow'] = 'xtls-rprx-vision-udp443'
        configs, _, _ = generate(data)
        audit_pair(configs['server.json'], configs['client.json'], data['version'], data['version'])
        for transport in ('http', 'h2', 'h3', 'quic'):
            data['transport']['type'] = transport
            with self.assertRaises(ConfigError):
                generate(data)

    def test_no_public_plaintext_or_fake_trust(self):
        data = request()
        data['security'] = {'type': 'none'}
        with self.assertRaises(ConfigError):
            generate(data)
        data['trusted_private_network'] = True
        for host in ('example.com', '8.8.8.8'):
            data['server']['address'] = host
            with self.assertRaises(ConfigError):
                generate(data)
        data['server']['address'] = '127.0.0.1'
        configs, _, _ = generate(data)
        self.assertEqual(configs['server.json']['inbounds'][0]['streamSettings']['security'], 'none')

    def test_reality_needs_keys_and_does_not_leak_to_client(self):
        data = request()
        data['security'] = {'type': 'reality', 'server_name': 'example.com', 'target': 'example.com:443'}
        with self.assertRaises(ConfigError):
            generate(data)
        # Synthetic structural fixtures only; not asserted to be a cryptographic pair.
        data['security'].update(private_key='A' * 43, password='B' * 43, short_id='aabb')
        configs, _, meta = generate(data)
        audit_pair(configs['server.json'], configs['client.json'], data['version'], data['version'])
        encoded = json.dumps(configs['client.json'])
        self.assertNotIn('privateKey', encoded)
        self.assertNotIn('target', encoded)
        self.assertNotIn('A' * 43, encoded)
        self.assertNotIn('B' * 43, json.dumps(meta))
        self.assertTrue(any('not been cryptographically' in w for w in meta['warnings']))
        data['transport']['type'] = 'ws'
        with self.assertRaises(ConfigError):
            generate(data)

    def test_encryption_requires_real_keys_not_placeholders(self):
        data = request()
        data['encryption'] = {'mode': 'generate'}
        with self.assertRaises(ConfigError):
            generate(data)
        data['encryption'] = {'mode': 'supplied', 'server': 'none', 'client': 'none'}
        with self.assertRaises(ConfigError):
            generate(data)

    def test_private_trust_not_exported_lossily(self):
        data = request()
        data['security']['client_trust_file'] = 'ca.pem'
        configs, links, meta = generate(data)
        self.assertFalse(links)
        self.assertEqual(meta['links_skipped'][0]['client'], 'client.json')
        self.assertIn('certificates', configs['client.json']['outbounds'][0]['streamSettings']['tlsSettings'])

    def test_xhttp_constraints_and_separate_download(self):
        data = request(transport='xhttp')
        for settings in ({'mode': 'bad'}, {'xmux': {'maxConcurrency': 1, 'maxConnections': 3}},
                         {'headers': {'hOsT': 'example.com'}}, {'xPaddingBytes': 0}):
            data['transport']['settings'] = settings
            with self.assertRaises(ConfigError):
                generate(data)
        data['transport']['settings'] = {'path': '/私有', 'mode': 'packet-up'}
        data['download'] = {'address': '2001:db8::1', 'port': 8443}
        configs, links, meta = generate(data)
        audit_pair(configs['server.json'], configs['client.json'], data['version'], data['version'])
        self.assertFalse(links)
        self.assertTrue(meta['links_skipped'])

    def test_mismatch_and_secret_injection_rejected(self):
        configs, _, _ = generate(request())
        for mutate in (lambda c: c['outbounds'][0]['settings']['vnext'][0]['users'][0].update(id='bad'),
                       lambda c: c['outbounds'][0]['streamSettings']['tlsSettings'].update(allowInsecure=True),
                       lambda c: c['outbounds'][0]['streamSettings']['tlsSettings'].update(echServerKeys='secret')):
            client = copy.deepcopy(configs['client.json'])
            mutate(client)
            with self.assertRaises(ConfigError):
                audit_pair(configs['server.json'], client, 'v26.3.27', 'v26.3.27')

    def test_bundle_permissions_no_overwrite_and_hashes(self):
        configs, links, meta = generate(request())
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / 'bundle'
            write_bundle(output, configs, links, meta)
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o700)
            for file in output.iterdir():
                self.assertEqual(stat.S_IMODE(file.stat().st_mode), 0o600)
            with self.assertRaises(ConfigError):
                write_bundle(output, configs, links, meta)
            _, loaded, _ = load_bundle(output)
            self.assertEqual(loaded, meta)
            report = validate_bundle(output)
            self.assertEqual(report['native_build']['server']['status'], 'skipped')
            self.assertEqual(report['handshake']['status'], 'not_run')
            with (output / 'client.json').open('a') as handle:
                handle.write(' ')
            with self.assertRaises(ConfigError):
                load_bundle(output)

    def test_manifest_path_traversal_and_symlinks_rejected(self):
        configs, links, meta = generate(request())
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / 'bundle'
            write_bundle(output, configs, links, meta)
            meta['files']['../private.json'] = 'x'
            (output / 'manifest.json').write_text(json.dumps(meta))
            with self.assertRaises(ConfigError):
                load_bundle(output)
            del meta['files']['../private.json']
            (output / 'manifest.json').write_text(json.dumps(meta))
            client = output / 'client.json'
            client.rename(output / 'elsewhere.json')
            client.symlink_to(output / 'elsewhere.json')
            with self.assertRaises(ConfigError):
                load_bundle(output)

    def test_duplicate_json_keys_and_nonfinite_numbers(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'data.json'
            for data in ('{"version":"a","version":"b"}', '{"port":NaN}'):
                path.write_text(data)
                with self.assertRaises(ConfigError):
                    read_json(path)

    def test_reports_never_overwrite_and_are_private(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'report.json'
            private_report(path, {'status': 'not_run'})
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            with self.assertRaises(FileExistsError):
                private_report(path, {})

    def test_official_fields_are_versioned(self):
        self.assertIn('mode', config_fields('v26.3.27', 'SplitHTTPConfig'))
        self.assertIn('mode', config_fields('v26.9.9', 'SplitHTTPConfig'))


if __name__ == '__main__':
    unittest.main()
