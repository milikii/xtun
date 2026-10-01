#!/usr/bin/env python3
"""Check versioned examples and observable config compatibility, without starting services."""

import argparse
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import uuid


ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT)
    parser.add_argument('--binary', required=True)
    parser.add_argument('--version', required=True, choices=['v26.3.27', 'v26.9.9'])
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    binary = Path(shutil.which(args.binary) or args.binary).resolve()
    version = subprocess.check_output([str(binary), 'version'], text=True, timeout=10)
    if not re.match(r'Xray ' + re.escape(args.version[1:]) + r'\s', version):
        raise SystemExit('Binary version does not match the requested test baseline')
    keys = subprocess.check_output([str(binary), 'x25519'], text=True, timeout=10)
    private = re.search(r'^PrivateKey:\s*(\S+)', keys, re.M)
    public = re.search(r'^(?:Password(?: \(PublicKey\))?|PublicKey):\s*(\S+)', keys, re.M)
    if not private or not public:
        raise SystemExit('Could not parse x25519 output; no key material printed')
    values = {
        'REPLACE_WITH_UUID': str(uuid.uuid4()),
        'REPLACE_WITH_PRIVATE_KEY': private[1],
        'REPLACE_WITH_PASSWORD': public[1],
        'REPLACE_WITH_SHORT_ID': '0123456789abcdef',
        'REPLACE_WITH_SERVER_ADDRESS': '127.0.0.1',
        'REPLACE_WITH_REALITY_TARGET:443': '127.0.0.1:443',
        'REPLACE_WITH_SERVER_NAME': 'example.com',
    }
    def substitute(value):
        if isinstance(value, dict):
            return {k: substitute(v) for k, v in value.items()}
        if isinstance(value, list):
            return [substitute(v) for v in value]
        return values.get(value, value) if isinstance(value, str) else value

    base = {'log': {'loglevel': 'warning'}, 'outbounds': [
        {'protocol': 'socks', 'settings': {'address': '127.0.0.1', 'port': 9}}
    ]}
    reality = {'fingerprint': 'chrome', 'serverName': 'example.com',
               'password': public[1], 'shortId': '0123456789abcdef'}
    cases = []
    def stream_case(name, stream, accepted, reason=''):
        config = deepcopy(base)
        config['outbounds'][0]['streamSettings'] = stream
        cases.append((name, config, accepted, reason))

    stream_case('tls-allowInsecure-false', {'security': 'tls', 'tlsSettings': {'allowInsecure': False}}, True)
    stream_case('tls-allowInsecure-true', {'security': 'tls', 'tlsSettings': {'allowInsecure': True}}, False, 'removed')
    stream_case('tls-native-fingerprint', {'security': 'tls', 'tlsSettings': {'fingerprint': 'unsafe'}}, True)
    for method in ('http', 'quic'):
        stream_case('removed-' + method, {'network': method}, False, 'removed')
    stream_case('grpc-reality', {'network': 'grpc', 'security': 'reality', 'realitySettings': reality}, True)
    invalid_reality = dict(reality, fingerprint='unsafe')
    stream_case('reality-native-fingerprint', {'network': 'tcp', 'security': 'reality', 'realitySettings': invalid_reality}, False, 'fingerprint')
    implicit = {k: v for k, v in reality.items() if k != 'fingerprint'}
    stream_case('reality-implicit-chrome', {'network': 'tcp', 'security': 'reality', 'realitySettings': implicit}, True)
    stream_case('ws-reality-rejected', {'network': 'ws', 'security': 'reality', 'realitySettings': reality}, False, 'REALITY only supports')
    stream_case('xhttp-string-range', {'network': 'xhttp', 'xhttpSettings': {'xPaddingBytes': '100-1000'}}, True)
    stream_case('xhttp-object-range-rejected', {'network': 'xhttp', 'xhttpSettings': {'xPaddingBytes': {'from': 100, 'to': 1000}}}, False)
    stream_case('xhttp-xmux-conflict', {'network': 'xhttp', 'xhttpSettings': {'xmux': {'maxConcurrency': 1, 'maxConnections': 3}}}, False, 'maxConnections')
    stream_case('xhttp-host-header-rejected', {'network': 'xhttp', 'xhttpSettings': {'headers': {'HoSt': 'example.com'}}}, False, 'host')
    stream_case('xhttp-extra-replaces-outer', {'network': 'xhttp', 'xhttpSettings': {
        'headers': {'host': 'example.com'}, 'extra': {}
    }}, True)

    chain = deepcopy(base)
    chain['outbounds'][0]['proxySettings'] = {'tag': 'direct'}
    chain['outbounds'].append({'tag': 'direct', 'protocol': 'freedom'})
    cases.append(('proxySettings-version-boundary', chain, args.version == 'v26.3.27',
                  'proxySettings' if args.version == 'v26.9.9' else ''))

    example = json.loads((args.root / 'examples' / f'vless-xhttp-reality-{args.version}.json').read_text())
    for side in ('server', 'client'):
        cases.append(('example-' + side, substitute(example[side]), True, ''))

    results = []
    with tempfile.TemporaryDirectory(prefix='xray-skill-config-check-') as directory:
        for name, config, accepted, reason in cases:
            path = Path(directory) / (name + '.json')
            path.write_text(json.dumps(config))
            path.chmod(0o600)
            proc = subprocess.run([str(binary), 'run', '-test', '-config', str(path)],
                                  capture_output=True, text=True, timeout=15)
            output = proc.stdout + proc.stderr
            ok = (proc.returncode == 0) == accepted and (not reason or reason in output)
            if accepted:
                ok = ok and 'Configuration OK' in output
            results.append({'case': name, 'expected_accepted': accepted,
                            'exit_code': proc.returncode, 'passed': ok})
            print(f"{'PASS' if ok else 'FAIL'} {name} (exit {proc.returncode})")
            if not ok:
                for value in (private[1], public[1]):
                    output = output.replace(value, '[test key]')
                print(output[-1800:])
    report = {'version': args.version, 'binary_version_output': version.strip(),
              'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
              'example_config_sha256': hashlib.sha256(json.dumps(
                  {side: example[side] for side in ('server', 'client')},
                  sort_keys=True, ensure_ascii=False).encode()).hexdigest(),
              'scope': 'Configuration parsing/building only; no listeners, live handshakes or throughput tests',
              'results': results}
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    passed = sum(r['passed'] for r in results)
    print(f'{args.version}: {passed}/{len(results)} configuration checks passed')
    return 0 if passed == len(results) else 1


if __name__ == '__main__':
    raise SystemExit(main())
