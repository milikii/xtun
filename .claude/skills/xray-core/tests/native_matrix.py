#!/usr/bin/env python3
"""Exercise generated configurations against an explicitly supplied official core."""

import argparse
from copy import deepcopy
import json
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from check_configs import private_report, validate_bundle
from generate import generate, write_bundle
from rules import ConfigError


def scenarios(version, cert, key):
    base = {'version': version, 'server': {'address': '127.0.0.1', 'port': 18443, 'listen': '127.0.0.1'},
            'transport': {'type': 'raw'}, 'security': {'type': 'tls', 'server_name': 'example.test',
            'certificate_file': str(cert), 'key_file': str(key), 'client_trust_file': str(cert)}}
    for transport in ('raw', 'xhttp', 'ws', 'grpc', 'httpupgrade', 'hysteria'):
        data = deepcopy(base)
        data['transport'] = {'type': transport}
        if transport == 'hysteria':
            data['transport']['settings'] = {'version': 2}
            data['security']['alpn'] = ['h3']
        yield transport + '-tls', data
    for transport in ('raw', 'xhttp', 'grpc'):
        data = deepcopy(base)
        data['transport']['type'] = transport
        data['security'] = {'type': 'reality', 'server_name': 'example.test', 'target': '127.0.0.1:19443'}
        yield transport + '-reality', data
    for security in ('tls', 'reality'):
        data = deepcopy(base)
        data['flow'] = 'xtls-rprx-vision'
        if security == 'reality':
            data['security'] = {'type': 'reality', 'server_name': 'example.test', 'target': '127.0.0.1:19443'}
        yield 'vision-' + security, data
    for mode in ('packet-up', 'stream-up', 'stream-one'):
        data = deepcopy(base)
        data['transport'] = {'type': 'xhttp', 'settings': {'mode': mode, 'path': '/test'}}
        data['security']['alpn'] = ['h2']
        yield 'xhttp-' + mode + '-h2', data
    data = deepcopy(base)
    data['transport'] = {'type': 'xhttp', 'settings': {'mode': 'stream-one'}}
    data['security']['alpn'] = ['h3']
    yield 'xhttp-h3', data
    data = deepcopy(base)
    data['transport'] = {'type': 'xhttp', 'settings': {'mode': 'packet-up'}}
    data['download'] = {'address': '127.0.0.1', 'port': 18443}
    yield 'xhttp-separate-download', data
    for transport in ('raw', 'xhttp', 'kcp'):
        for auth in ('x25519', 'mlkem768'):
            data = deepcopy(base)
            data['transport'] = {'type': transport}
            data['security'] = {'type': 'none'}
            data['encryption'] = {'mode': 'generate', 'authentication': auth}
            yield transport + '-encryption-' + auth, data
    data = deepcopy(base)
    data['transport']['type'] = 'xhttp'
    data['flow'] = 'xtls-rprx-vision'
    data['encryption'] = {'mode': 'generate'}
    yield 'xhttp-encryption-vision', data
    if version == 'v26.9.30':
        for alpn in ('h2', 'h3'):
            data = deepcopy(base)
            data['transport'] = {'type': 'masque'}
            data['security']['alpn'] = [alpn]
            yield 'masque-' + alpn, data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--handshake', action='store_true')
    args = parser.parse_args()
    results = []
    with tempfile.TemporaryDirectory(prefix='xray-native-matrix-') as temp:
        root = Path(temp)
        cert, key = root / 'cert.pem', root / 'key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256',
                        '-nodes', '-days', '1', '-subj', '/CN=example.test', '-addext', 'subjectAltName=DNS:example.test',
                        '-keyout', str(key), '-out', str(cert)], check=True, capture_output=True)
        for name, data in scenarios(args.version, cert, key):
            try:
                configs, links, manifest = generate(data, args.binary)
                bundle = root / name
                write_bundle(bundle, configs, links, manifest)
                validation = validate_bundle(bundle, args.binary, args.binary)
                passed = all(x['status'] == 'passed' for x in validation['native_build'].values())
                passed &= validation.get('reality_key_pairing', {'status': 'passed'})['status'] == 'passed'
                result = {'case': name, 'status': 'passed' if passed else 'failed', 'build': validation}
                if args.handshake and passed:
                    from check_handshake import validate_handshake
                    result['handshake'] = validate_handshake(bundle, args.binary, args.binary)
                    if result['handshake']['handshake']['status'] != 'passed':
                        result['status'] = result['handshake']['handshake']['status']
                results.append(result)
            except (ConfigError, OSError, ValueError) as error:
                results.append({'case': name, 'status': 'failed', 'reason': str(error) if isinstance(error, ConfigError) else 'Scenario did not complete; private data withheld'})
            print(name + ': ' + results[-1]['status'], flush=True)
    report = {'version': args.version, 'scope': 'Generated configuration build matrix; only an explicit handshake section proves local transport tests',
              'external': 'not_verified', 'results': results}
    private_report(args.report, report)
    return 0 if all(x['status'] == 'passed' for x in results) else 1


if __name__ == '__main__':
    raise SystemExit(main())
