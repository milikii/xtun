import copy
import hashlib
import io
import json
import os
from pathlib import Path
import socket
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import check_handshake as handshake
from generate import generate, write_bundle
from rules import ConfigError


def request(transport='raw', security='tls'):
    value = {'version': 'v26.3.27', 'server': {'address': 'proxy.example.com', 'port': 443},
             'transport': {'type': transport}, 'security': {'type': security}}
    if security == 'tls':
        value['security'].update(server_name='proxy.example.com', certificate_file='prod.pem', key_file='prod.key')
    elif security == 'reality':
        value['security'].update(server_name='target.example.com', target='target.example.com:443',
                                 private_key='A' * 43, password='B' * 43, short_id='aabb')
    return value


def configs(transport='raw', security='tls'):
    return generate(request(transport, security))[0]


class HandshakeTests(unittest.TestCase):
    def test_adaptation_preserves_protocol_identities_and_original(self):
        data = configs()
        original = copy.deepcopy(data)
        adapted = handshake.adapt_configs(data, 12001, 12002, 12003, 12004, '/private/ca.pem', '/private/ca.key')
        self.assertEqual(data, original)
        server = adapted['server.json']
        client = adapted['client.json']
        self.assertEqual(server['inbounds'][0]['settings'], original['server.json']['inbounds'][0]['settings'])
        endpoint = client['outbounds'][0]['settings']['vnext'][0]
        self.assertEqual(endpoint['users'], original['client.json']['outbounds'][0]['settings']['vnext'][0]['users'])
        self.assertEqual(endpoint['address'], '127.0.0.1')
        self.assertEqual(endpoint['port'], 12001)
        self.assertEqual(server['outbounds'][0]['settings'], {'redirect': '127.0.0.1:12004'})
        tls = client['outbounds'][0]['streamSettings']['tlsSettings']
        self.assertNotIn('allowInsecure', tls)
        self.assertEqual(tls['serverName'], 'proxy.example.com')
        self.assertEqual(tls['certificates'], [{'certificateFile': '/private/ca.pem', 'usage': 'verify'}])

    def test_reality_target_is_local_without_changing_credentials(self):
        data = configs(security='reality')
        original = copy.deepcopy(data)
        adapted = handshake.adapt_configs(data, 12001, 12002, 12003, 12004, 'ca', 'key')
        before = original['server.json']['inbounds'][0]['streamSettings']['realitySettings']
        after = adapted['server.json']['inbounds'][0]['streamSettings']['realitySettings']
        self.assertEqual(after['target'], '127.0.0.1:12003')
        for field in ('privateKey', 'serverNames', 'shortIds'):
            self.assertEqual(after[field], before[field])
        self.assertEqual(adapted['client.json']['outbounds'][0]['streamSettings']['realitySettings'],
                         original['client.json']['outbounds'][0]['streamSettings']['realitySettings'])

    def test_download_address_uses_same_listener(self):
        data = configs('xhttp')
        stream = data['client.json']['outbounds'][0]['streamSettings']
        download = copy.deepcopy(stream)
        download.update(address='other.example.com', port=444)
        stream['xhttpSettings']['downloadSettings'] = download
        adapted = handshake.adapt_configs(data, 12001, 12002, 12003, 12004, 'ca', 'key')
        down = adapted['client.json']['outbounds'][0]['streamSettings']['xhttpSettings']['downloadSettings']
        self.assertEqual((down['address'], down['port']), ('127.0.0.1', 12001))
        self.assertEqual(down['tlsSettings']['certificates'][0]['usage'], 'verify')
        self.assertEqual(download['address'], 'other.example.com')

    def test_scope_refuses_external_features(self):
        for feature in ('ech', 'xdrive', 'masque', 'finalmask'):
            data = configs()
            stream = data['client.json']['outbounds'][0]['streamSettings']
            if feature == 'ech':
                stream['tlsSettings']['echConfigList'] = 'https://external.example/'
            elif feature == 'finalmask':
                stream['finalmask'] = {'dns': 'external'}
            else:
                stream['network'] = feature
            self.assertIsNotNone(handshake.scope_reason(data))
        self.assertIsNone(handshake.scope_reason(configs()))

    def test_sni_sanitization_and_ip_san(self):
        data = configs()
        self.assertEqual(handshake.certificate_names(data), ['DNS:proxy.example.com'])
        stream = data['client.json']['outbounds'][0]['streamSettings']['tlsSettings']
        stream['serverName'] = '::1'
        self.assertEqual(handshake.certificate_names(data), ['IP:::1'])
        for name in ('bad,IP:8.8.8.8', '/CN=inject', '', 'bad\nname', '*.example.com'):
            stream['serverName'] = name
            with self.assertRaises(handshake.HandshakeError):
                handshake.certificate_names(data)

    def test_wrong_uuid_changes_only_identity(self):
        client = configs()['client.json']
        original = copy.deepcopy(client)
        occupied = {client['outbounds'][0]['settings']['vnext'][0]['users'][0]['id']}
        changed = handshake.wrong_uuid(client, occupied)
        self.assertEqual(client, original)
        new_id = changed['outbounds'][0]['settings']['vnext'][0]['users'][0]['id']
        self.assertNotIn(new_id, occupied)
        changed['outbounds'][0]['settings']['vnext'][0]['users'][0]['id'] = next(iter(occupied))
        self.assertEqual(changed, original)

    def test_private_config_write_never_overwrites(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'private.json'
            handshake.write_private(path, b'{}')
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            with self.assertRaises(FileExistsError):
                handshake.write_private(path, b'other')
            self.assertEqual(path.read_bytes(), b'{}')

    def test_process_stop_terminates_then_kills_after_timeout(self):
        process = Mock()
        process.poll.return_value = None
        process.wait.side_effect = [subprocess.TimeoutExpired('private', 3), 0]
        handshake.Processes.stop(process)
        process.terminate.assert_called_once()
        process.kill.assert_called_once()
        self.assertEqual(process.wait.call_count, 2)
        process = Mock()
        process.poll.return_value = 0
        handshake.Processes.stop(process)
        process.terminate.assert_not_called()

    def test_process_collection_closes_in_reverse_order(self):
        with tempfile.TemporaryDirectory() as temp:
            processes = handshake.Processes(temp)
            first, second = Mock(), Mock()
            processes.items = [first, second]
            with patch.object(processes, 'stop') as stop:
                processes.close()
            self.assertEqual([call.args[0] for call in stop.call_args_list], [second, first])

    def test_process_logs_private_and_environment_sanitized(self):
        with tempfile.TemporaryDirectory() as temp:
            processes = handshake.Processes(temp)
            with patch.dict(os.environ, {'SSLKEYLOGFILE': '/outside', 'HTTPS_PROXY': 'secret'}), \
                    patch.object(handshake.subprocess, 'Popen') as popen:
                processes.start('client', '/fake/xray', {'log': {}})
                environment = popen.call_args.kwargs['env']
                self.assertNotIn('SSLKEYLOGFILE', environment)
                self.assertNotIn('HTTPS_PROXY', environment)
                self.assertEqual(environment['TMPDIR'], temp)
                self.assertFalse((Path(temp) / 'client.log').exists())
                self.assertEqual(popen.call_args.kwargs['stdout'], subprocess.DEVNULL)
                self.assertEqual(popen.call_args.kwargs['stderr'], subprocess.DEVNULL)
                self.assertEqual(stat.S_IMODE((Path(temp) / 'client.json').stat().st_mode), 0o600)

    def test_dead_process_is_not_a_negative_success(self):
        alive, dead = Mock(), Mock()
        alive.poll.return_value = None
        dead.poll.return_value = 1
        fixture = Mock()
        with patch.object(handshake, 'http_request') as request_mock:
            with self.assertRaises(handshake.HandshakeError):
                handshake.negative_probe(1, fixture, 1, alive, dead)
            request_mock.assert_not_called()

    def test_negative_rejects_any_response_or_destination_hit(self):
        process = Mock()
        process.poll.return_value = None
        fixture = Mock()
        fixture.requested.return_value = False
        with patch.object(handshake, 'http_request', return_value=(403, b'forbidden')):
            with self.assertRaises(handshake.HandshakeError):
                handshake.negative_probe(1, fixture, 1, process, process)
        fixture.requested.return_value = True
        with patch.object(handshake, 'http_request', side_effect=ConnectionError()):
            with self.assertRaises(handshake.HandshakeError):
                handshake.negative_probe(1, fixture, 1, process, process)
        fixture.requested.return_value = False
        with patch.object(handshake, 'http_request', side_effect=ConnectionError()):
            handshake.negative_probe(1, fixture, 1, process, process)

    def test_positive_probe_checks_download_and_upload_hashes(self):
        fixture = Mock(port=12001, payload=b'hello', sha256=hashlib.sha256(b'hello').hexdigest())
        uploaded = json.dumps({'bytes': 5, 'sha256': fixture.sha256}).encode()
        with patch.object(handshake, 'http_request', side_effect=[(200, b'hello'), (200, uploaded)]):
            self.assertEqual(handshake.positive_probe(1, fixture, 1)['status'], 'passed')
        for response in ((200, b'wrong'), (404, b'hello')):
            with patch.object(handshake, 'http_request', return_value=response):
                with self.assertRaises(handshake.HandshakeError):
                    handshake.positive_probe(1, fixture, 1)

    def test_real_http_fixture_is_loopback_and_closes(self):
        fixture = handshake.HTTPFixture(4096)
        self.assertEqual(fixture.server.server_address[0], '127.0.0.1')
        port = fixture.port
        fixture.start()
        try:
            import http.client
            connection = http.client.HTTPConnection('127.0.0.1', port, timeout=2)
            connection.request('GET', '/local')
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            self.assertEqual(response.read(), fixture.payload)
            connection.close()
            self.assertTrue(fixture.requested('/local'))
        finally:
            fixture.close()
        self.assertFalse(fixture.thread.is_alive())
        with self.assertRaises(OSError):
            socket.create_connection(('127.0.0.1', port), timeout=0.2)

    def test_bounds_checked_before_bundle_or_binary(self):
        for size, timeout in ((True, 1), (0, 1), (4096, 0), (4096, True), (4096, float('nan'))):
            with patch.object(handshake, 'load_bundle') as load:
                with self.assertRaises(handshake.HandshakeError):
                    handshake.validate_handshake('/no', '/none', '/none', size, timeout)
                load.assert_not_called()

    def test_skip_happens_before_identify_or_process_start(self):
        generated, _, manifest = generate(request())
        generated['client.json']['outbounds'][0]['streamSettings']['tlsSettings']['echConfigList'] = 'external'
        with patch.object(handshake, 'load_bundle', return_value=(Path('/bundle'), manifest, generated)), \
                patch.object(handshake, 'identify') as identify:
            report = handshake.validate_handshake('/bundle', '/xray', '/xray')
        identify.assert_not_called()
        self.assertEqual(report['handshake']['status'], 'skipped')
        self.assertEqual(report['external']['status'], 'not_verified')

    def test_target_fixture_cannot_forward_to_public_network(self):
        target = handshake.reality_target('ca', 'key', 12001, 12002)
        self.assertEqual(target['inbounds'][0]['listen'], '127.0.0.1')
        self.assertEqual(target['inbounds'][0]['settings']['address'], '127.0.0.1')
        self.assertEqual(target['outbounds'][0]['settings']['redirect'], '127.0.0.1:12002')
        self.assertEqual(target['inbounds'][0]['streamSettings']['tlsSettings']['minVersion'], '1.3')

    def test_cli_skip_is_nonzero_and_errors_do_not_echo_input(self):
        report = {'handshake': {'status': 'skipped', 'reason': 'Not supported', 'clients': {}}}
        with patch.object(handshake, 'validate_handshake', return_value=report), patch('sys.stdout', new_callable=io.StringIO):
            self.assertEqual(handshake.main(['--bundle', '/a', '--server-binary', '/b', '--client-binary', '/c']), 3)
        with patch.object(handshake, 'validate_handshake', side_effect=KeyError('private')), \
                patch('sys.stderr', new_callable=io.StringIO) as stderr:
            self.assertEqual(handshake.main(['--bundle', '/a', '--server-binary', '/b', '--client-binary', '/c']), 2)
            self.assertNotIn("'private'", stderr.getvalue())

    def test_cleanup_on_certificate_failure(self):
        generated, _, manifest = generate(request())
        with patch.object(handshake, 'load_bundle', return_value=(Path('/bundle'), manifest, generated)), \
                patch.object(handshake, 'identify', return_value=(Path('/fake'), {})), \
                patch.object(handshake, 'make_certificate', side_effect=handshake.HandshakeError('test fixture failed')), \
                patch.object(handshake, 'HTTPFixture') as fixture_class, \
                patch.object(handshake.Processes, 'close') as close:
            report = handshake.validate_handshake('/bundle', '/fake', '/fake')
        self.assertEqual(report['handshake']['status'], 'failed')
        fixture_class.return_value.close.assert_called_once()
        close.assert_called_once()

    def test_cleanup_continues_after_one_process_cannot_be_reaped(self):
        with tempfile.TemporaryDirectory() as temp:
            processes = handshake.Processes(temp)
            first, second = Mock(), Mock()
            processes.items = [first, second]
            with patch.object(processes, 'stop', side_effect=[OSError(), None]) as stop:
                with self.assertRaises(handshake.HandshakeError):
                    processes.close()
            self.assertEqual([call.args[0] for call in stop.call_args_list], [second, first])

    def test_socks_framing_and_error_cleanup(self):
        sock = Mock()
        replies = [b'\x05\x00', b'\x05\x00\x00\x01', b'\x7f\x00\x00\x01', b'\x12\x34']
        sock.recv.side_effect = replies
        with patch.object(handshake.socket, 'create_connection', return_value=sock) as connect:
            self.assertIs(handshake.socks_socket(12001, 12002, 2), sock)
        self.assertEqual(connect.call_args.args[0], ('127.0.0.1', 12001))
        self.assertEqual(sock.sendall.call_args_list[0].args[0], b'\x05\x01\x00')
        self.assertEqual(sock.sendall.call_args_list[1].args[0][4:8], socket.inet_aton('127.0.0.1'))
        sock.recv.side_effect = [b'\x05\xff']
        with patch.object(handshake.socket, 'create_connection', return_value=sock):
            with self.assertRaises(ConnectionError):
                handshake.socks_socket(12001, 12002, 2)
        sock.close.assert_called_once()

    def test_response_bound_always_closes_connection(self):
        connection = Mock()
        connection.getresponse.return_value.read.return_value = b'x' * (8 * 1024 * 1024 + 1)
        with patch.object(handshake.http.client, 'HTTPConnection', return_value=connection), \
                patch.object(handshake, 'socks_socket'):
            with self.assertRaises(handshake.HandshakeError):
                handshake.http_request(12001, 12002, '/local', 2)
        connection.close.assert_called_once()

    def test_positive_after_negative_is_required_by_orchestration(self):
        generated, _, manifest = generate(request())
        alive = Mock()
        alive.poll.return_value = None
        events = []
        def positive(*args):
            events.append('positive')
            if len(events) == 3:
                raise handshake.HandshakeError('Post-negative positive failed')
            return {'status': 'passed'}
        def negative(*args):
            events.append('negative')
        with patch.object(handshake, 'load_bundle', return_value=(Path('/bundle'), manifest, generated)), \
                patch.object(handshake, 'identify', return_value=(Path('/fake'), {})), \
                patch.object(handshake, 'make_certificate', return_value=(Path('/ca'), Path('/key'))), \
                patch.object(handshake, 'HTTPFixture') as fixture_class, \
                patch.object(handshake, 'native_test', return_value={'status': 'passed'}), \
                patch.object(handshake.Processes, 'start', return_value=alive), \
                patch.object(handshake.Processes, 'stop'), \
                patch.object(handshake, 'wait_listener'), \
                patch.object(handshake, 'positive_probe', side_effect=positive), \
                patch.object(handshake, 'negative_probe', side_effect=negative):
            fixture_class.return_value.port = 12004
            report = handshake.validate_handshake('/bundle', '/fake', '/fake')
        self.assertEqual(events, ['positive', 'negative', 'positive'])
        self.assertEqual(report['handshake']['status'], 'failed')
        fixture_class.return_value.close.assert_called_once()


if __name__ == '__main__':
    unittest.main()
