#!/usr/bin/env python3
"""Validate a generated bundle in distinct structural and native-build layers.

This never starts listeners. Use check_handshake.py explicitly for isolated
loopback tests. Historical example regressions live in check_examples.py.
"""

import argparse
from copy import deepcopy
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import uuid

from core import base64_key, identify, x25519
from rules import (ConfigError, RULES_PATH, digest, integer, json_bytes, load_rules,
                   object_keys, private_destination, read_json, text, validate_transport)


def stream_info(stream, version, side):
    rules, _ = load_rules(version)
    object_keys(stream, {'network', 'method', 'security', 'tlsSettings', 'realitySettings',
                         *(p['settings_key'] for p in rules['transports'].values())}, 'streamSettings')
    if 'network' in stream and 'method' in stream:
        raise ConfigError('Competing stream transport aliases')
    name = stream.get('network', stream.get('method', 'raw'))
    name = rules['aliases'].get(name, name)
    if name not in rules['transports']:
        raise ConfigError('No generation profile for transport')
    profile = rules['transports'][name]
    for entry in rules['transports'].values():
        if entry['settings_key'] in stream and entry['settings_key'] != profile['settings_key']:
            raise ConfigError('Inactive transport settings cannot be validated as effective configuration')
    security = stream.get('security', 'none')
    settings = deepcopy(stream.get(profile['settings_key'], {}))
    if not isinstance(settings, dict):
        raise ConfigError('Transport settings must be an object')
    download = settings.pop('downloadSettings', None)
    validate_transport(version, name, settings, security, encrypted=True)
    if security == 'none':
        if 'tlsSettings' in stream or 'realitySettings' in stream:
            raise ConfigError('Inactive security settings')
    elif security == 'tls':
        if 'realitySettings' in stream:
            raise ConfigError('Competing security layers')
        tls = stream.get('tlsSettings', {})
        object_keys(tls, {'serverName', 'fingerprint', 'alpn', 'certificates', 'echConfigList', 'echServerKeys'}, 'TLS')
        if side == 'server' and ('echConfigList' in tls or 'fingerprint' in tls):
            raise ConfigError('Client-only TLS options on server')
        if side == 'client' and 'echServerKeys' in tls:
            raise ConfigError('Server ECH secret on client')
        if tls.get('fingerprint') in ('unsafe', 'random'):
            raise ConfigError('Fingerprint is outside reviewed generator profiles')
        if 'certificates' in tls:
            if not isinstance(tls['certificates'], list) or not tls['certificates']:
                raise ConfigError('TLS certificates must be a nonempty list')
            for cert in tls['certificates']:
                allowed = {'certificateFile', 'keyFile'} if side == 'server' else {'certificateFile', 'usage'}
                object_keys(cert, allowed, 'TLS certificate', allowed)
                for item in cert.values():
                    text(item, 'certificate field')
                if side == 'client' and cert['usage'] != 'verify':
                    raise ConfigError('Client certificates must be an explicit verification trust anchor')
        elif side == 'server':
            raise ConfigError('TLS server requires certificate files')
    elif security == 'reality':
        if 'tlsSettings' in stream:
            raise ConfigError('Competing security layers')
        reality = stream.get('realitySettings', {})
        allowed = {'target', 'serverNames', 'privateKey', 'shortIds'} if side == 'server' else {'serverName', 'fingerprint', 'password', 'shortId'}
        object_keys(reality, allowed, 'REALITY', allowed)
        if not base64_key(reality['privateKey' if side == 'server' else 'password']):
            raise ConfigError('Invalid REALITY key encoding')
        if side == 'client' and reality['fingerprint'] in ('unsafe', 'random'):
            raise ConfigError('Invalid REALITY fingerprint')
        sids = reality['shortIds'] if side == 'server' else [reality['shortId']]
        if not isinstance(sids, list) or not sids or any(not isinstance(x, str) or len(x) % 2 or not re.fullmatch(r'[0-9a-fA-F]{0,16}', x) for x in sids):
            raise ConfigError('Invalid REALITY short ID')
    if download is not None:
        if side != 'client' or name != 'xhttp' or settings.get('mode') == 'stream-one':
            raise ConfigError('Invalid separate download configuration')
        if not isinstance(download, dict) or 'downloadSettings' in download.get('xhttpSettings', {}):
            raise ConfigError('Nested downloadSettings is unsupported')
        down = deepcopy(download)
        text(down.pop('address', None), 'download address')
        integer(down.pop('port', None), 'download port', 1)
        dname, dsecurity, dsettings = stream_info(down, version, side)
        expected = deepcopy(stream)
        expected['xhttpSettings'].pop('downloadSettings', None)
        if down != expected or dname != name or dsecurity != security or dsettings != settings:
            raise ConfigError('This generator only supports a second address for the same XHTTP listener; external termination needs additional rules')
    return name, security, settings


def audit_pair(server, client, server_version, client_version):
    for config in (server, client):
        object_keys(config, {'log', 'inbounds', 'outbounds'}, 'configuration', ('inbounds', 'outbounds'))
        object_keys(config.get('log', {}), {'loglevel'}, 'log')
        if not isinstance(config['inbounds'], list) or len(config['inbounds']) != 1:
            raise ConfigError('Expected exactly one generated inbound')
        if not isinstance(config['outbounds'], list) or len(config['outbounds']) != 1:
            raise ConfigError('Expected exactly one generated outbound')
    inbound, outbound = server['inbounds'][0], client['outbounds'][0]
    object_keys(inbound, {'tag', 'listen', 'port', 'protocol', 'settings', 'streamSettings'}, 'server inbound')
    object_keys(outbound, {'tag', 'protocol', 'settings', 'streamSettings'}, 'client outbound')
    if inbound.get('protocol') != 'vless' or outbound.get('protocol') != 'vless':
        raise ConfigError('Expected VLESS at both ends')
    integer(inbound.get('port'), 'server port', 1)
    settings = inbound.get('settings', {})
    object_keys(settings, {'users', 'clients', 'decryption'}, 'VLESS server settings', ('decryption',))
    if ('users' in settings) == ('clients' in settings):
        raise ConfigError('Exactly one VLESS user-list name is required')
    users = settings.get('users', settings.get('clients'))
    if not isinstance(users, list) or not users:
        raise ConfigError('Server has no users')
    seen = set()
    for user in users:
        object_keys(user, {'id', 'flow', 'email'}, 'server user', ('id',))
        try:
            user_id = str(uuid.UUID(user['id']))
        except (ValueError, TypeError, AttributeError) as error:
            raise ConfigError('Invalid server UUID') from error
        if user_id in seen:
            raise ConfigError('Duplicate server UUID')
        seen.add(user_id)
    object_keys(outbound.get('settings', {}), {'vnext'}, 'client settings', ('vnext',))
    endpoints = outbound['settings']['vnext']
    if not isinstance(endpoints, list) or len(endpoints) != 1:
        raise ConfigError('Expected one client endpoint')
    endpoint = endpoints[0]
    object_keys(endpoint, {'address', 'port', 'users'}, 'endpoint', ('address', 'port', 'users'))
    text(endpoint['address'], 'endpoint address')
    integer(endpoint['port'], 'endpoint port', 1)
    if not isinstance(endpoint['users'], list) or len(endpoint['users']) != 1:
        raise ConfigError('Expected one client user')
    user = endpoint['users'][0]
    object_keys(user, {'id', 'encryption', 'flow'}, 'client user', ('id', 'encryption'))
    matches = [x for x in users if x['id'] == user['id']]
    if len(matches) != 1:
        raise ConfigError('Client UUID is not present on the server')
    if matches[0].get('flow', '') != user.get('flow', '').removesuffix('-udp443'):
        raise ConfigError('Server/client flows do not match')
    decryption, encryption = settings['decryption'], user['encryption']
    if not all(isinstance(x, str) and x for x in (decryption, encryption)):
        raise ConfigError('Encryption/decryption must be explicit strings')
    if (decryption == 'none') != (encryption == 'none'):
        raise ConfigError('VLESS Encryption is only enabled on one end')
    encrypted = decryption != 'none'
    if encrypted and (decryption == encryption or decryption.split('.')[:2] != encryption.split('.')[:2] or not encryption.startswith('mlkem768x25519plus.')):
        raise ConfigError('VLESS Encryption roles or handshake parameters do not match')
    sn, sk, ss = stream_info(inbound.get('streamSettings', {}), server_version, 'server')
    cn, ck, cs = stream_info(outbound.get('streamSettings', {}), client_version, 'client')
    if not encrypted and sk == 'none' and not private_destination(endpoint['address']):
        raise ConfigError('Unencrypted VLESS destination must be an RFC1918, ULA or loopback IP')
    if (sn, sk) != (cn, ck):
        raise ConfigError('Server/client transport or security mismatch')
    for key in ('host', 'path', 'serviceName', 'auth', 'user', 'pass'):
        if ss.get(key, '') != cs.get(key, ''):
            raise ConfigError('Server/client transport pairing mismatch')
    if sn == 'xhttp' and ss.get('mode', 'auto') != 'auto' and ss['mode'] != cs.get('mode', 'auto'):
        raise ConfigError('Explicit XHTTP modes do not match')
    validate_transport(server_version, sn, ss, sk, matches[0].get('flow', ''), encrypted)
    validate_transport(client_version, cn, cs, ck, user.get('flow', ''), encrypted)
    if sk == 'reality':
        sr = inbound['streamSettings']['realitySettings']
        cr = outbound['streamSettings']['realitySettings']
        if cr['serverName'] not in sr['serverNames'] or cr['shortId'] not in sr['shortIds']:
            raise ConfigError('REALITY SNI/shortId is not allowed by the server')
    socks = client['inbounds'][0]
    object_keys(socks, {'tag', 'listen', 'port', 'protocol', 'settings'}, 'client SOCKS inbound')
    if socks.get('protocol') != 'socks' or socks.get('listen') not in ('127.0.0.1', '::1'):
        raise ConfigError('Generated SOCKS inbound must be loopback-only')
    integer(socks.get('port'), 'SOCKS port', 1)
    object_keys(socks.get('settings', {}), {'udp'}, 'SOCKS settings')
    direct = server['outbounds'][0]
    object_keys(direct, {'tag', 'protocol'}, 'server outbound')
    if direct.get('protocol') != 'freedom':
        raise ConfigError('Unexpected generated server outbound')


def load_bundle(directory):
    directory = Path(directory).resolve()
    manifest = read_json(directory / 'manifest.json')
    if not isinstance(manifest, dict) or manifest.get('schema_version') != 1:
        raise ConfigError('Unsupported bundle manifest')
    for key in ('server_version', 'client_version'):
        _, selected = load_rules(manifest.get(key))
        commit_key = 'source_commit' if key == 'server_version' else 'client_source_commit'
        if manifest.get(commit_key) != selected['commit']:
            raise ConfigError('Bundle source identity differs from the pinned version')
    if manifest.get('rules_sha256') != digest(RULES_PATH.read_bytes()):
        raise ConfigError('Bundle was generated with different rules; regenerate before validating')
    files = manifest.get('files', {})
    if not isinstance(files, dict) or 'server.json' not in files or 'client.json' not in files:
        raise ConfigError('Bundle must contain server.json and client.json')
    configs = {}
    for name, expected in files.items():
        if not isinstance(name, str) or not re.fullmatch(r'(?:server|client(?:-(?:[2-9]|[1-9][0-9]+))?)\.json', name):
            raise ConfigError('Unexpected bundle configuration path')
        path = directory / name
        if path.is_symlink() or not path.is_file() or digest(path.read_bytes()) != expected:
            raise ConfigError('Bundle configuration hash differs or file is not a regular local file')
        configs[name] = read_json(path)
    for name, config in configs.items():
        if name != 'server.json':
            audit_pair(configs['server.json'], config, manifest['server_version'], manifest['client_version'])
    inbound = configs['server.json']['inbounds'][0]
    if (inbound['settings']['decryption'] == 'none' and
            inbound.get('streamSettings', {}).get('security', 'none') == 'none' and
            manifest.get('trusted_private_network') is not True):
        raise ConfigError('Unencrypted bundle requires an explicit private-network trust declaration')
    return directory, manifest, configs


def private_report(path, report):
    path = Path(path)
    import os
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'wb') as handle:
        handle.write(json_bytes(report))


def native_test(binary, config, directory, bundle_dir):
    config = deepcopy(config)
    config['log'] = {'loglevel': 'warning'}
    for group in ('inbounds', 'outbounds'):
        for entry in config.get(group, []):
            tls = entry.get('streamSettings', {}).get('tlsSettings', {})
            for cert in tls.get('certificates', []):
                for key in ('certificateFile', 'keyFile'):
                    if key in cert and not Path(cert[key]).is_absolute():
                        cert[key] = str(bundle_dir / cert[key])
    path = Path(directory) / 'config.json'
    path.write_bytes(json_bytes(config))
    path.chmod(0o600)
    try:
        result = subprocess.run([str(binary), 'run', '-test', '-config', str(path)],
                                capture_output=True, text=True, timeout=20, cwd=directory)
        return {'status': 'passed' if result.returncode == 0 and 'Configuration OK' in result.stdout + result.stderr else 'failed',
                'exit_code': result.returncode, 'scope': 'Parsing/building only; private output withheld'}
    except (OSError, subprocess.TimeoutExpired):
        return {'status': 'failed', 'reason': 'Native check could not complete; private output withheld'}


def validate_bundle(directory, server_binary=None, client_binary=None):
    directory, manifest, configs = load_bundle(directory)
    report = {'schema_version': 1, 'versions': {side: manifest[f'{side}_version'] for side in ('server', 'client')},
              'config_sha256': manifest['files'], 'rules_sha256': manifest['rules_sha256'],
              'structure': {'status': 'passed'}, 'native_build': {},
              'handshake': {'status': 'not_run'}, 'external': {'status': 'not_verified'},
              'credential_pairing': {'status': 'not_verified', 'reason': 'Encryption key pairing requires an actual handshake'}}
    with tempfile.TemporaryDirectory(prefix='xray-config-test-') as temp:
        for side, supplied in [('server', server_binary), ('client', client_binary)]:
            names = ['server.json'] if side == 'server' else [n for n in configs if n != 'server.json']
            if supplied is None:
                report['native_build'][side] = {'status': 'skipped', 'reason': 'No binary provided'}
                continue
            try:
                binary, identity = identify(supplied, manifest[f'{side}_version'])
                checks = {name: native_test(binary, configs[name], temp, directory) for name in names}
                invalid = native_test(binary, {'inbounds': 'not-an-array'}, temp, directory)
                negative_ok = invalid['status'] == 'failed' and 'exit_code' in invalid and invalid['exit_code'] != 0
                status = 'passed' if negative_ok and all(c['status'] == 'passed' for c in checks.values()) else 'failed'
                report['native_build'][side] = {'status': status, 'identity': identity, 'checks': checks,
                                               'negative_control': 'passed' if negative_ok else 'failed'}
                if side == 'server' and configs['server.json']['inbounds'][0]['streamSettings']['security'] == 'reality':
                    reality = configs['server.json']['inbounds'][0]['streamSettings']['realitySettings']
                    password = x25519(binary, reality['privateKey'])[1]
                    paired = all(c['outbounds'][0]['streamSettings']['realitySettings']['password'] == password for n, c in configs.items() if n != 'server.json')
                    report['reality_key_pairing'] = {'status': 'passed' if paired else 'failed'}
            except ConfigError as error:
                report['native_build'][side] = {'status': 'failed', 'reason': str(error)}
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', required=True, type=Path)
    parser.add_argument('--server-binary')
    parser.add_argument('--client-binary')
    parser.add_argument('--report', type=Path)
    parser.add_argument('--require-build', action='store_true', help='Fail when either native-build layer is skipped')
    args = parser.parse_args()
    try:
        report = validate_bundle(args.bundle, args.server_binary, args.client_binary)
        if args.report:
            private_report(args.report, report)
        print('Structure: passed')
        for side, result in report['native_build'].items():
            print(f"{side} native build: {result['status']}")
        print('Handshake: not run. External deployment: not verified.')
        failed = any(x['status'] == 'failed' or (args.require_build and x['status'] != 'passed') for x in report['native_build'].values())
        failed |= report.get('reality_key_pairing', {}).get('status') == 'failed'
        return 1 if failed else 0
    except (ConfigError, OSError, KeyError, TypeError, AttributeError) as error:
        message = str(error) if isinstance(error, ConfigError) else 'Invalid bundle or report path; private data withheld'
        print(message, file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
