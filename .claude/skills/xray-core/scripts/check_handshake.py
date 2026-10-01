#!/usr/bin/env python3
"""Exercise generated VLESS pairs against a private loopback HTTP fixture.

No services, system CA store or deployment files are modified. Every destination
is adapted to loopback, including REALITY's target and the server's freedom
outbound. Certificate/endpoint adaptations are recorded; identities, flow and
VLESS Encryption are preserved. A pass is not a public-network/CDN/GUI verdict.
"""

import argparse
from copy import deepcopy
import hashlib
import http.client
import http.server
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import uuid

from check_configs import audit_pair, load_bundle, native_test, private_report
from core import identify
from rules import ConfigError, digest, json_bytes


SUPPORTED = {'raw', 'xhttp', 'ws', 'grpc', 'httpupgrade', 'kcp', 'hysteria'}
ALIASES = {'tcp': 'raw', 'splithttp': 'xhttp', 'websocket': 'ws', 'mkcp': 'kcp'}
ADAPTATIONS = [
    'All listener and endpoint addresses are replaced with 127.0.0.1 and temporary high ports.',
    'The server freedom outbound redirects every request to the local HTTP fixture.',
    'TLS certificate paths/trust are replaced by a private test CA certificate; verification stays enabled.',
    'REALITY target, when present, is replaced by a private TLS 1.3-capable fixture.',
    'Separate XHTTP download addresses are redirected to the same test listener/session store.',
    'Protocol user IDs, flow, Encryption/decryption, REALITY credentials, SNI, ALPN and transport options are preserved.',
]


class HandshakeError(ValueError):
    """Safe to display: never contains configuration values or child output."""


def transport(stream):
    name = stream.get('network', stream.get('method', 'raw'))
    return ALIASES.get(name, name)


def streams(config):
    for group in ('inbounds', 'outbounds'):
        for entry in config.get(group, []):
            stream = entry.get('streamSettings')
            if stream is not None:
                yield stream
                download = stream.get('xhttpSettings', {}).get('downloadSettings')
                if download is not None:
                    yield download


def scope_reason(configs):
    """Unsupported external integrations must be skipped before any process starts."""
    for config in configs.values():
        for stream in streams(config):
            if transport(stream) not in SUPPORTED:
                return 'No audited loopback adapter for this transport; external storage/MASQUE are not tested.'
            if stream.get('finalmask'):
                return 'Finalmask may have external dependencies; no loopback adapter is implemented.'
            tls = stream.get('tlsSettings', {})
            if any(key in tls for key in ('echConfigList', 'echServerKeys')):
                return 'ECH is not adapted here; no external ECH/DNS lookup was performed.'
    return None


def unused_port(udp=False):
    """Reserve a loopback port briefly; process startup still detects races."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM if udp else socket.SOCK_STREAM) as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


class Processes:
    def __init__(self, directory):
        self.directory = Path(directory)
        self.items = []

    def start(self, name, binary, config):
        path = self.directory / (name + '.json')
        write_private(path, json_bytes(config))
        env = os.environ.copy()
        for key in ('SSLKEYLOGFILE', 'XRAY_LOCATION_CONFIG', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY',
                    'http_proxy', 'https_proxy', 'all_proxy'):
            env.pop(key, None)
        env.update(TMPDIR=str(self.directory), XRAY_LOCATION_ASSET=str(self.directory))
        # Core diagnostics can include credentials from rejected configurations.
        # Discard them rather than persisting even a private unredacted log.
        try:
            process = subprocess.Popen([str(binary), 'run', '-config', str(path)], stdout=subprocess.DEVNULL,
                                       stderr=subprocess.DEVNULL, cwd=self.directory, env=env)
        except OSError as error:
            raise HandshakeError('A test process could not start; private output withheld') from error
        self.items.append(process)
        return process

    @staticmethod
    def stop(process):
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)

    def close(self):
        failed = False
        for process in reversed(self.items):
            try:
                self.stop(process)
            except (OSError, subprocess.SubprocessError):
                failed = True
        if failed:
            raise HandshakeError('A local test process could not be reaped cleanly')


def write_private(path, data):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'wb') as output:
        output.write(data)


def require_alive(*processes):
    if any(process.poll() is not None for process in processes):
        raise HandshakeError('A test process exited; this is not an authentication-rejection result')


def wait_listener(port, process, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        require_alive(process)
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=0.1):
                return
        except OSError:
            time.sleep(0.04)
    raise HandshakeError('The local test listener did not become ready')


def certificate_names(configs):
    names = set()
    for name, config in configs.items():
        if name == 'server.json':
            continue
        for stream in streams(config):
            security = stream.get('security', 'none')
            if security not in ('tls', 'reality'):
                continue
            item = stream.get('tlsSettings' if security == 'tls' else 'realitySettings', {})
            value = item.get('serverName', '')
            if not isinstance(value, str) or not value:
                raise HandshakeError('A concrete SNI name is required for a private test certificate')
            try:
                ip = ipaddress.ip_address(value)
                names.add('IP:' + str(ip))
            except ValueError:
                if len(value) > 253 or not all(re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', part)
                                              for part in value.rstrip('.').split('.')):
                    raise HandshakeError('The SNI cannot safely be represented in a private test certificate')
                names.add('DNS:' + value)
    if len(names) > 64:
        raise HandshakeError('Too many certificate names for a bounded local test')
    return sorted(names)


def make_certificate(directory, names):
    openssl = shutil.which('openssl')
    if not openssl:
        raise HandshakeError('OpenSSL is required for private test certificates')
    cert, key = Path(directory) / 'test-ca.pem', Path(directory) / 'test-ca.key'
    args = [openssl, 'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256',
            '-nodes', '-days', '2', '-subj', '/CN=xray-local-test',
            '-addext', 'basicConstraints=critical,CA:TRUE',
            '-addext', 'subjectAltName=' + ','.join(names or ['DNS:localhost']),
            '-keyout', str(key), '-out', str(cert)]
    try:
        result = subprocess.run(args, capture_output=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise HandshakeError('Private test certificate generation did not complete') from error
    if result.returncode:
        raise HandshakeError('Private test certificate generation failed; private output withheld')
    for path in (cert, key):
        path.chmod(0o600)
    return cert, key


def adapt_configs(configs, server_port, socks_port, target_port, http_port, cert, key):
    """Copy and adapt environment only; original bundle bytes stay untouched."""
    result = deepcopy(configs)
    server = result['server.json']
    server['log'] = {'loglevel': 'warning'}
    inbound = server['inbounds'][0]
    inbound.update(listen='127.0.0.1', port=server_port)
    server['outbounds'][0]['settings'] = {'redirect': f'127.0.0.1:{http_port}'}
    server_stream = inbound['streamSettings']
    if server_stream.get('security') == 'tls':
        server_stream['tlsSettings']['certificates'] = [{'certificateFile': str(cert), 'keyFile': str(key)}]
    elif server_stream.get('security') == 'reality':
        server_stream['realitySettings']['target'] = f'127.0.0.1:{target_port}'
    for name, client in result.items():
        if name == 'server.json':
            continue
        client['log'] = {'loglevel': 'warning'}
        client['inbounds'][0].update(listen='127.0.0.1', port=socks_port)
        endpoint = client['outbounds'][0]['settings']['vnext'][0]
        endpoint.update(address='127.0.0.1', port=server_port)
        for stream in streams(client):
            if 'address' in stream:
                stream.update(address='127.0.0.1', port=server_port)
            if stream.get('security') == 'tls':
                stream['tlsSettings']['certificates'] = [{'certificateFile': str(cert), 'usage': 'verify'}]
    return result


def reality_target(cert, key, target_port, http_port):
    return {'log': {'loglevel': 'warning'}, 'inbounds': [{
        'listen': '127.0.0.1', 'port': target_port, 'protocol': 'dokodemo-door',
        'settings': {'address': '127.0.0.1', 'port': http_port, 'network': 'tcp'},
        'streamSettings': {'network': 'raw', 'security': 'tls', 'tlsSettings': {
            'minVersion': '1.3', 'alpn': ['h2'],
            'certificates': [{'certificateFile': str(cert), 'keyFile': str(key)}]}}
    }], 'outbounds': [{'protocol': 'freedom', 'settings': {'redirect': f'127.0.0.1:{http_port}'}}]}


class HTTPFixture:
    def __init__(self, size):
        self.payload = secrets.token_bytes(size)
        self.sha256 = digest(self.payload)
        self.seen = set()
        self.lock = threading.Lock()
        self.thread = None
        fixture = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'

            def setup(self):
                super().setup()
                self.connection.settimeout(10)

            def log_message(self, *_):
                pass

            def record(self):
                with fixture.lock:
                    fixture.seen.add(self.path)

            def answer(self, data):
                self.send_response(200)
                self.send_header('Content-Length', str(len(data)))
                self.send_header('Connection', 'close')
                self.end_headers()
                self.wfile.write(data)
                self.close_connection = True

            def do_GET(self):
                self.record()
                self.answer(fixture.payload)

            def do_POST(self):
                self.record()
                try:
                    size = int(self.headers.get('Content-Length', '-1'))
                    if not 0 <= size <= len(fixture.payload):
                        raise ValueError
                    data = self.rfile.read(size)
                    if len(data) != size:
                        raise ValueError
                    self.answer(json_bytes({'bytes': size, 'sha256': digest(data)}))
                except (ValueError, OSError):
                    self.close_connection = True

        class Server(http.server.ThreadingHTTPServer):
            daemon_threads = True

            def handle_error(self, *_):
                pass  # Private fixture exceptions must not write request data to stderr.

        self.server = Server(('127.0.0.1', 0), Handler)

    @property
    def port(self):
        return self.server.server_port

    def start(self):
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={'poll_interval': 0.05}, daemon=True)
        self.thread.start()

    def close(self):
        if self.thread is not None:
            self.server.shutdown()
            self.thread.join(timeout=3)
        self.server.server_close()

    def requested(self, path):
        with self.lock:
            return path in self.seen


def receive_exact(sock, size):
    data = b''
    while len(data) < size:
        piece = sock.recv(size - len(data))
        if not piece:
            raise ConnectionError('Local SOCKS stream closed')
        data += piece
    return data


def socks_socket(socks_port, target_port, timeout):
    sock = socket.create_connection(('127.0.0.1', socks_port), timeout=timeout)
    try:
        sock.settimeout(timeout)
        sock.sendall(b'\x05\x01\x00')
        if receive_exact(sock, 2) != b'\x05\x00':
            raise ConnectionError('Local SOCKS method was not accepted')
        sock.sendall(b'\x05\x01\x00\x01' + socket.inet_aton('127.0.0.1') + struct.pack('!H', target_port))
        reply = receive_exact(sock, 4)
        if reply[:3] != b'\x05\x00\x00':
            raise ConnectionError('Local SOCKS connect was not accepted')
        if reply[3] == 1:
            receive_exact(sock, 4)
        elif reply[3] == 4:
            receive_exact(sock, 16)
        elif reply[3] == 3:
            receive_exact(sock, receive_exact(sock, 1)[0])
        else:
            raise ConnectionError('Local SOCKS address type was invalid')
        receive_exact(sock, 2)
        return sock
    except BaseException:
        sock.close()
        raise


def http_request(socks_port, target_port, path, timeout, body=None):
    connection = http.client.HTTPConnection('127.0.0.1', target_port, timeout=timeout)
    try:
        connection.sock = socks_socket(socks_port, target_port, timeout)
        connection.request('POST' if body is not None else 'GET', path, body=body,
                           headers={'Connection': 'close'})
        response = connection.getresponse()
        # Response memory is bounded even if a failed local adapter sends garbage.
        data = response.read(8 * 1024 * 1024 + 1)
        if len(data) > 8 * 1024 * 1024:
            raise HandshakeError('Local response exceeded the fixture size limit')
        return response.status, data
    finally:
        connection.close()


def positive_probe(socks_port, fixture, timeout):
    marker = secrets.token_hex(8)
    status, data = http_request(socks_port, fixture.port, '/download/' + marker, timeout)
    if status != 200 or len(data) != len(fixture.payload) or digest(data) != fixture.sha256:
        raise HandshakeError('Authenticated local download did not match the expected payload')
    status, data = http_request(socks_port, fixture.port, '/upload/' + marker, timeout, fixture.payload)
    try:
        received = json.loads(data)
    except (ValueError, UnicodeError) as error:
        raise HandshakeError('Authenticated local upload returned an invalid result') from error
    if status != 200 or received != {'bytes': len(fixture.payload), 'sha256': fixture.sha256}:
        raise HandshakeError('Authenticated local upload did not match the expected payload')
    return {'status': 'passed', 'download_bytes': len(fixture.payload), 'upload_bytes': len(fixture.payload),
            'payload_sha256': fixture.sha256}


def wrong_uuid(config, occupied):
    result = deepcopy(config)
    value = str(uuid.uuid4())
    while value in occupied:
        value = str(uuid.uuid4())
    result['outbounds'][0]['settings']['vnext'][0]['users'][0]['id'] = value
    return result


def negative_probe(socks_port, fixture, timeout, server_process, client_process):
    require_alive(server_process, client_process)
    path = '/negative/' + secrets.token_hex(8)
    try:
        http_request(socks_port, fixture.port, path, timeout)
    except (OSError, ConnectionError, http.client.HTTPException):
        pass
    else:
        raise HandshakeError('Wrong-UUID client received an HTTP response instead of being rejected')
    require_alive(server_process, client_process)
    if fixture.requested(path):
        raise HandshakeError('Wrong-UUID traffic reached the local destination')


def validate_handshake(bundle, server_binary, client_binary, size=128 * 1024, timeout=10):
    if type(size) is not int or not 4096 <= size <= 4 * 1024 * 1024:
        raise HandshakeError('Payload size must be an integer from 4096 to 4194304 bytes')
    if not isinstance(timeout, (int, float)) or isinstance(timeout, bool) or not 1 <= timeout <= 60:
        raise HandshakeError('Timeout must be between 1 and 60 seconds')
    directory, manifest, original = load_bundle(bundle)
    report = {'schema_version': 1, 'structure': {'status': 'passed'},
              'versions': {side: manifest[f'{side}_version'] for side in ('server', 'client')},
              'source_config_sha256': manifest['files'], 'rules_sha256': manifest['rules_sha256'],
              'adaptations': ADAPTATIONS[:], 'handshake': {'status': 'not_run', 'clients': {}},
              'external': {'status': 'not_verified', 'scope': 'No public target, CDN, GUI import, production certificate, regional availability or performance test'},
              'scope': 'Loopback TCP application traffic through the selected transport; UDP application relay and Vision direct-copy optimization are not asserted'}
    reason = scope_reason(original)
    if reason:
        report['handshake'] = {'status': 'skipped', 'reason': reason, 'clients': {}}
        return report
    server_binary, server_identity = identify(server_binary, manifest['server_version'])
    client_binary, client_identity = identify(client_binary, manifest['client_version'])
    report['binaries'] = {'server': server_identity, 'client': client_identity}
    for name, client in original.items():
        if name != 'server.json':
            audit_pair(original['server.json'], client, manifest['server_version'], manifest['client_version'])
    names = certificate_names(original)
    with tempfile.TemporaryDirectory(prefix='xray-loopback-') as temporary:
        temp = Path(temporary)
        temp.chmod(0o700)
        processes = Processes(temp)
        fixture = HTTPFixture(size)
        try:
            fixture.start()
            cert, key = make_certificate(temp, names)
            stream = original['server.json']['inbounds'][0]['streamSettings']
            udp_only = transport(stream) in ('kcp', 'hysteria')
            server_port = unused_port(udp=udp_only)
            target_port = unused_port()
            socks_port = unused_port()
            adapted = adapt_configs(original, server_port, socks_port, target_port, fixture.port, cert, key)
            report['tested_config_sha256'] = {name: digest(json_bytes(config)) for name, config in adapted.items()}
            if stream.get('security') == 'reality':
                target = reality_target(cert, key, target_port, fixture.port)
                check = native_test(server_binary, target, temp, temp)
                if check['status'] != 'passed':
                    raise HandshakeError('The private REALITY target fixture failed its native build check')
                target_process = processes.start('reality-target', server_binary, target)
                wait_listener(target_port, target_process)
            server_check = native_test(server_binary, adapted['server.json'], temp, temp)
            report['native_build'] = {'server.json': server_check}
            if server_check['status'] != 'passed':
                raise HandshakeError('Adapted generated server configuration failed its native build check')
            server_process = processes.start('server', server_binary, adapted['server.json'])
            if udp_only:
                time.sleep(0.3)
                require_alive(server_process)
            else:
                wait_listener(server_port, server_process)
            users = original['server.json']['inbounds'][0]['settings']
            occupied = {user['id'] for user in users.get('users', users.get('clients', []))}
            for index, (name, config) in enumerate((x for x in adapted.items() if x[0] != 'server.json'), 1):
                client_process = bad_process = None
                result = {'status': 'not_run'}
                report['handshake']['clients'][name] = result
                try:
                    client_check = native_test(client_binary, config, temp, temp)
                    report['native_build'][name] = client_check
                    if client_check['status'] != 'passed':
                        raise HandshakeError('Adapted generated client configuration failed its native build check')
                    client_process = processes.start(f'client-{index}', client_binary, config)
                    wait_listener(socks_port, client_process)
                    result['positive'] = positive_probe(socks_port, fixture, timeout)
                    require_alive(server_process, client_process)
                    bad = wrong_uuid(config, occupied)
                    bad_port = unused_port()
                    bad['inbounds'][0]['port'] = bad_port
                    report['tested_config_sha256'][f'wrong-uuid-{index}.json'] = digest(json_bytes(bad))
                    if native_test(client_binary, bad, temp, temp)['status'] != 'passed':
                        raise HandshakeError('Wrong-UUID control did not pass native configuration construction')
                    bad_process = processes.start(f'wrong-uuid-{index}', client_binary, bad)
                    wait_listener(bad_port, bad_process)
                    negative_probe(bad_port, fixture, min(timeout, 5), server_process, bad_process)
                    result['negative'] = {'status': 'passed', 'scope': 'Wrong UUID did not reach destination while test processes stayed alive'}
                    # A transient transport outage is not mistaken for an authentication rejection.
                    result['positive_after_negative'] = positive_probe(socks_port, fixture, timeout)
                    require_alive(server_process, client_process)
                    result['status'] = 'passed'
                except (HandshakeError, OSError, ConnectionError, http.client.HTTPException) as error:
                    result.update(status='failed', reason=str(error) if isinstance(error, HandshakeError) else 'Local handshake/transfer failed; private output withheld')
                finally:
                    if bad_process is not None:
                        processes.stop(bad_process)
                    if client_process is not None:
                        processes.stop(client_process)
            checks = report['handshake']['clients'].values()
            report['handshake']['status'] = 'passed' if checks and all(item['status'] == 'passed' for item in checks) else 'failed'
        except (HandshakeError, OSError, subprocess.SubprocessError) as error:
            report['handshake'].update(status='failed', reason=str(error) if isinstance(error, HandshakeError) else 'Local fixture could not complete; private output withheld')
        finally:
            try:
                processes.close()
            except HandshakeError as error:
                report['handshake'].update(status='failed', reason=str(error))
            finally:
                fixture.close()
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', required=True, type=Path)
    parser.add_argument('--server-binary', required=True)
    parser.add_argument('--client-binary', required=True)
    parser.add_argument('--report', type=Path)
    parser.add_argument('--bytes', type=int, default=128 * 1024, dest='size')
    parser.add_argument('--timeout', type=float, default=10)
    args = parser.parse_args(argv)
    try:
        report = validate_handshake(args.bundle, args.server_binary, args.client_binary, args.size, args.timeout)
        if args.report:
            private_report(args.report, report)
        status = report['handshake']['status']
        print(f'Isolated loopback handshake: {status}. External deployment: not verified.')
        if 'reason' in report['handshake']:
            print(report['handshake']['reason'])
        for name, result in report['handshake'].get('clients', {}).items():
            print(f"{name}: {result['status']}")
        return 0 if status == 'passed' else 3 if status == 'skipped' else 1
    except (ConfigError, HandshakeError, OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        message = str(error) if isinstance(error, (ConfigError, HandshakeError)) else 'Invalid local test input or report path; private data withheld'
        print(message, file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
