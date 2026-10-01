#!/usr/bin/env python3
"""Generate private, version-pinned VLESS configuration bundles; never deploy them."""

import argparse
from copy import deepcopy
import ipaddress
import os
from pathlib import Path
import re
import secrets
import shutil
import sys
import tempfile
import uuid

from core import base64_key, encryption_pair, identify, x25519
from links import LinkUnsupported, encode_uri
from rules import (ConfigError, ROOT, RULES_PATH, check_fields, config_fields, digest,
                   integer, json_bytes, load_rules, object_keys, private_destination, read_json, text, validate_transport)


def address(value):
    value = text(value, 'address')
    if value.startswith('[') or any(c.isspace() for c in value) or any(c in value for c in '/@?#'):
        raise ConfigError('Use an unbracketed IP address or a hostname without a URL scheme')
    if ':' in value:
        try:
            if '%' in value:
                raise ValueError
            ipaddress.IPv6Address(value)
        except ValueError as error:
            raise ConfigError('Invalid unbracketed IPv6 address') from error
    elif not all(re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', part) for part in value.rstrip('.').split('.')):
        raise ConfigError('Use an IP address or an ASCII/IDNA hostname')
    return value


def security_pair(value, version, binary, warnings):
    object_keys(value, {'type', 'server_name', 'certificate_file', 'key_file', 'client_trust_file',
                        'fingerprint', 'alpn', 'target', 'private_key', 'password', 'short_id',
                        'ech_config_list', 'ech_server_keys'}, 'security', ('type',))
    kind = value['type']
    if kind == 'none':
        object_keys(value, {'type'}, 'security none')
        return {'security': 'none'}, {'security': 'none'}
    if kind not in ('tls', 'reality'):
        raise ConfigError('Security must be tls, reality or none')
    name = address(value.get('server_name'))
    fingerprint = text(value.get('fingerprint', 'chrome'), 'fingerprint')
    if fingerprint in ('unsafe', 'random'):
        raise ConfigError('This generator requires a concrete verified-client fingerprint, not unsafe/random')
    client = {'serverName': name, 'fingerprint': fingerprint}
    if kind == 'tls':
        if any(k in value for k in ('target', 'private_key', 'password', 'short_id')):
            raise ConfigError('REALITY-only fields cannot be used with TLS')
        cert = text(value.get('certificate_file'), 'certificate_file')
        key = text(value.get('key_file'), 'key_file')
        server = {'certificates': [{'certificateFile': cert, 'keyFile': key}]}
        if 'client_trust_file' in value:
            client['certificates'] = [{'certificateFile': text(value['client_trust_file'], 'client_trust_file'), 'usage': 'verify'}]
        if 'alpn' in value:
            alpn = value['alpn']
            if not isinstance(alpn, list) or not alpn or not all(isinstance(x, str) and x for x in alpn):
                raise ConfigError('ALPN must be a nonempty array of strings')
            server['alpn'] = client['alpn'] = alpn[:]
        if ('ech_config_list' in value) != ('ech_server_keys' in value):
            raise ConfigError('Direct TLS ECH needs both client config and server keys; external TLS termination needs its own topology')
        for native, key, side in [('echConfigList', 'ech_config_list', client), ('echServerKeys', 'ech_server_keys', server)]:
            if key in value:
                if native not in config_fields(version, 'TLSConfig'):
                    raise ConfigError('ECH field is not in this version of the official configuration builder')
                side[native] = text(value[key], key)
                warnings.append('ECH material was supplied, not generated or checked against DNS/CDN configuration.')
        warnings.append('Certificate files and SNI/ALPN must be valid on the actual deployment; no certificate was provisioned.')
        return {'security': kind, 'tlsSettings': server}, {'security': kind, 'tlsSettings': client}
    if any(k in value for k in ('certificate_file', 'key_file', 'client_trust_file', 'alpn', 'ech_config_list', 'ech_server_keys')):
        raise ConfigError('TLS-only fields cannot be used with REALITY')
    target = text(value.get('target'), 'REALITY target')
    if not re.fullmatch(r'(?:\[[0-9a-fA-F:]+\]|[^:\s/]+):[0-9]{1,5}', target):
        raise ConfigError('REALITY target must be host:port or [IPv6]:port')
    integer(int(target.rsplit(':', 1)[1]), 'REALITY target port', 1)
    private, password = value.get('private_key'), value.get('password')
    if (private is None) != (password is None):
        raise ConfigError('Supply both REALITY key roles, or let the target binary generate the pair')
    if private is None:
        if binary is None:
            raise ConfigError('REALITY key generation requires --binary for the target version')
        private, password = x25519(binary)
    if not base64_key(private) or not base64_key(password):
        raise ConfigError('REALITY credentials must be 32-byte base64url values')
    if binary is not None and x25519(binary, private)[1] != password:
        raise ConfigError('REALITY private key and client password are not a pair')
    if binary is None:
        warnings.append('Supplied REALITY keys have not been cryptographically paired; use a matching binary to verify.')
    sid = value.get('short_id', secrets.token_hex(8))
    if not isinstance(sid, str) or len(sid) % 2 or not re.fullmatch(r'[0-9a-fA-F]{0,16}', sid):
        raise ConfigError('REALITY short_id must be even-length hexadecimal, at most 16 characters')
    server = {'target': target, 'serverNames': [name], 'privateKey': private, 'shortIds': [sid]}
    client.update(password=password, shortId=sid)
    warnings.append('REALITY target suitability and the peer ClientHello are external prerequisites; no public target was probed.')
    return {'security': kind, 'realitySettings': server}, {'security': kind, 'realitySettings': client}


def generate(request, binary=None):
    object_keys(request, {'version', 'client_version', 'label', 'server', 'transport', 'security',
                          'users', 'flow', 'encryption', 'trusted_private_network', 'client_port', 'download'},
                'request', ('version', 'server', 'transport', 'security'))
    version = text(request['version'], 'version')
    client_version = text(request.get('client_version', version), 'client_version')
    rules, selected = load_rules(version)
    _, client_selected = load_rules(client_version)
    identity = None
    if binary is not None:
        binary, identity = identify(binary, version)
    warnings = []
    endpoint = request['server']
    object_keys(endpoint, {'address', 'port', 'listen'}, 'server', ('address', 'port'))
    host = address(endpoint['address'])
    port = integer(endpoint['port'], 'server port', 1)
    listen = endpoint.get('listen', '0.0.0.0')
    try:
        ipaddress.ip_address(listen)
    except (ValueError, TypeError) as error:
        raise ConfigError('server.listen must be an IP address') from error
    client_port = integer(request.get('client_port', 10808), 'client SOCKS port', 1)
    label = text(request.get('label', 'VLESS'), 'label')
    encryption = request.get('encryption', {'mode': 'none'})
    object_keys(encryption, {'mode', 'authentication', 'server', 'client'}, 'encryption')
    mode = encryption.get('mode', 'none')
    decryption = encryption_value = 'none'
    if mode == 'generate':
        if set(encryption) - {'mode', 'authentication'}:
            raise ConfigError('Generated Encryption cannot also contain supplied keys')
        if binary is None:
            raise ConfigError('VLESS Encryption generation requires the target --binary')
        decryption, encryption_value = encryption_pair(binary, encryption.get('authentication', 'x25519'))
    elif mode == 'supplied':
        object_keys(encryption, {'mode', 'server', 'client'}, 'supplied encryption', ('server', 'client'))
        decryption = text(encryption['server'], 'server decryption')
        encryption_value = text(encryption['client'], 'client encryption')
        if decryption == encryption_value or not all(s.startswith('mlkem768x25519plus.') for s in (decryption, encryption_value)):
            raise ConfigError('Supply distinct server/client VLESS Encryption strings, not a shared secret or none')
        if decryption.split('.')[:2] != encryption_value.split('.')[:2]:
            raise ConfigError('VLESS Encryption handshake and traffic appearance must match')
        warnings.append('Supplied Encryption key pairing requires a real handshake; config acceptance alone is insufficient.')
    elif mode != 'none' or set(encryption) - {'mode'}:
        raise ConfigError('Encryption mode must be none, generate or supplied with the matching fields')
    encrypted = decryption != 'none'
    server_security, client_security = security_pair(request['security'], version, binary, warnings)
    kind = server_security['security']
    private = request.get('trusted_private_network', False)
    if type(private) is not bool:
        raise ConfigError('trusted_private_network must be a boolean')
    if kind == 'none' and not encrypted:
        if not private:
            raise ConfigError('Unencrypted VLESS requires an explicitly trusted private network')
        if not private_destination(host):
            raise ConfigError('Unencrypted VLESS destination must be an RFC1918, ULA or loopback IP; use Encryption or TLS otherwise')
        warnings.append('No cryptographic transport protection: restricted to the explicitly trusted private network.')
    transport = request['transport']
    object_keys(transport, {'type', 'settings', 'server_settings', 'client_settings'}, 'transport', ('type',))
    name = text(transport['type'], 'transport type')
    settings = transport.get('settings', {})
    if not isinstance(settings, dict):
        raise ConfigError('transport.settings must be an object')
    server_settings, client_settings = deepcopy(settings), deepcopy(settings)
    for key, side in [('server_settings', server_settings), ('client_settings', client_settings)]:
        if key in transport:
            if not isinstance(transport[key], dict):
                raise ConfigError('Per-side transport settings must be an object')
            side.update(deepcopy(transport[key]))
    name, profile = validate_transport(version, name, server_settings, kind, encrypted=encrypted)
    validate_transport(client_version, name, client_settings, kind, encrypted=encrypted)
    for key in ('path', 'host', 'serviceName', 'auth', 'user', 'pass'):
        if server_settings.get(key, '') != client_settings.get(key, ''):
            raise ConfigError('Server/client path, host, serviceName or transport authentication do not match')
    if name == 'xhttp':
        sm, cm = server_settings.get('mode', 'auto'), client_settings.get('mode', 'auto')
        if sm != 'auto' and cm != sm:
            raise ConfigError('Explicit server XHTTP mode must match the client mode')
    if profile['status'] != 'source-reviewed':
        warnings.append('Transport status: ' + profile['status'] + '; see the versioned official reference.')
    server_stream = {selected['stream_key']: name, **server_security}
    client_stream = {client_selected['stream_key']: name, **client_security}
    if server_settings or name != 'raw':
        server_stream[profile['settings_key']] = server_settings
    if client_settings or name != 'raw':
        client_stream[profile['settings_key']] = deepcopy(client_settings)
    if 'download' in request:
        if name != 'xhttp' or client_settings.get('mode') == 'stream-one':
            raise ConfigError('Separate download requires XHTTP other than stream-one')
        download = request['download']
        object_keys(download, {'address', 'port'}, 'download', ('address', 'port'))
        down = dict(deepcopy(client_stream), address=address(download['address']),
                    port=integer(download['port'], 'download port', 1))
        client_stream[profile['settings_key']]['downloadSettings'] = down
        warnings.append('Download address must reach the SAME XHTTP listener/session store; external CDN/frontends are not provisioned or verified.')
    users = request.get('users', [{}])
    if not isinstance(users, list) or not users:
        raise ConfigError('users must be a nonempty array')
    server_users, clients, links, skips, ids = [], {}, [], [], set()
    for index, user in enumerate(users):
        object_keys(user, {'id', 'email', 'flow'}, 'user')
        try:
            user_id = str(uuid.UUID(user['id'])) if 'id' in user else str(uuid.uuid4())
        except (ValueError, TypeError, AttributeError) as error:
            raise ConfigError('User IDs must be UUIDs; map custom IDs with the target core before generation') from error
        if user_id in ids:
            raise ConfigError('Duplicate user UUID')
        ids.add(user_id)
        flow = user.get('flow', request.get('flow', ''))
        flow = text(flow, 'flow', nonempty=False)
        validate_transport(version, name, server_settings, kind, flow, encrypted)
        validate_transport(client_version, name, client_settings, kind, flow, encrypted)
        server_user = {'id': user_id}
        client_user = {'id': user_id, 'encryption': encryption_value}
        if flow:
            server_user['flow'] = flow.removesuffix('-udp443')
            client_user['flow'] = flow
        if 'email' in user:
            server_user['email'] = text(user['email'], 'user email')
        server_users.append(server_user)
        outbound = {'tag': 'proxy', 'protocol': 'vless', 'settings': {'vnext': [
            {'address': host, 'port': port, 'users': [client_user]}]}, 'streamSettings': deepcopy(client_stream)}
        client = {'log': {'loglevel': 'warning'}, 'inbounds': [
            {'tag': 'socks', 'listen': '127.0.0.1', 'port': client_port, 'protocol': 'socks', 'settings': {'udp': True}}
        ], 'outbounds': [outbound]}
        filename = 'client.json' if index == 0 else f'client-{index + 1}.json'
        clients[filename] = client
        try:
            links.append(encode_uri(outbound, label if len(users) == 1 else f'{label}-{index + 1}'))
        except LinkUnsupported as error:
            skips.append({'client': filename, 'reason': str(error)})
    server = {'log': {'loglevel': 'warning'}, 'inbounds': [
        {'tag': 'vless', 'listen': listen, 'port': port, 'protocol': 'vless',
         'settings': {selected['user_key']: server_users, 'decryption': decryption}, 'streamSettings': server_stream}
    ], 'outbounds': [{'protocol': 'freedom', 'tag': 'direct'}]}
    configs = {'server.json': server, **clients}
    manifest = {'schema_version': 1, 'server_version': version, 'client_version': client_version,
                'source_commit': selected['commit'], 'client_source_commit': client_selected['commit'],
                'rules_sha256': digest(RULES_PATH.read_bytes()), 'binary': identity,
                'profile': {'transport': name, 'security': kind, 'encrypted': encrypted},
                'trusted_private_network': private,
                'files': {name: digest(json_bytes(config)) for name, config in configs.items()},
                'freshness': 'Exact pinned version; current latest status was not checked by generation',
                'validation': {'structure': 'passed', 'config_build': 'not_run', 'handshake': 'not_run', 'external': 'not_verified'},
                'warnings': warnings, 'links_skipped': skips,
                'link_scope': 'Conservative connection-field encoding only; no GUI client import was tested'}
    return configs, links, manifest


def write_bundle(output, configs, links, manifest):
    output = Path(output).absolute()
    if output.exists() or output.is_symlink():
        raise ConfigError('Output already exists; choose a new directory (no files were overwritten)')
    if not output.parent.is_dir():
        raise ConfigError('Output parent directory must already exist')
    temp = Path(tempfile.mkdtemp(prefix='.xray-bundle-', dir=output.parent))
    try:
        artifacts = {name: json_bytes(config) for name, config in configs.items()}
        artifacts['manifest.json'] = json_bytes(manifest)
        if links:
            artifacts['links.txt'] = ('\n'.join(links) + '\n').encode()
        notes = ['# Private Xray configuration bundle', '',
                 f"Server: {manifest['server_version']}; client: {manifest['client_version']}.",
                 '', 'These files contain credentials. Do not commit or publish them.',
                 'Nothing has been installed. Config-build, handshake and external checks have NOT run.',
                 'Client configurations are alternatives for individual users, not simultaneous SOCKS listeners.',
                 'Do not import manifest.json as an Xray configuration.', '', '## Prerequisites / limitations',
                 *('- ' + warning for warning in manifest['warnings']),
                 *('- Link omitted for ' + item['client'] + ': ' + item['reason'] for item in manifest['links_skipped'])]
        artifacts['README.md'] = ('\n'.join(notes) + '\n').encode()
        for name, data in artifacts.items():
            with (temp / name).open('xb') as handle:
                os.chmod(temp / name, 0o600)
                handle.write(data)
        # mkdir is the no-overwrite arbitration point; do not replace a competing directory.
        output.mkdir(mode=0o700)
        try:
            for path in temp.iterdir():
                path.rename(output / path.name)
        except BaseException:
            shutil.rmtree(output)
            raise
    finally:
        shutil.rmtree(temp)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--request', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--binary', help='Exact server-version core for identity/key generation, not a system installation')
    args = parser.parse_args()
    try:
        configs, links, manifest = generate(read_json(args.request), args.binary)
        write_bundle(args.output, configs, links, manifest)
        print(f'Created {len(configs)} private configurations; {len(links)} conservative links. No deployment or handshake was performed.')
        for item in manifest['links_skipped']:
            print(f"Native JSON retained for {item['client']}: {item['reason']}")
        return 0
    except (ConfigError, OSError) as error:
        print(str(error) if isinstance(error, ConfigError) else 'Could not write private output; no private values were logged', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
