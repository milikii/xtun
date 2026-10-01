#!/usr/bin/env python3
"""Shared, version-pinned rules for the VLESS generator (not a full Xray schema)."""

import hashlib
import ipaddress
import json
from pathlib import Path
import re

import yaml

ROOT = Path(__file__).resolve().parents[1]
RULES_PATH = ROOT / 'extracted/compatibility/generation.yaml'


class ConfigError(ValueError):
    """A safe-to-display error which must not include credential values."""


def digest(data):
    return hashlib.sha256(data).hexdigest()


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode()


def read_json(path):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ConfigError('Duplicate JSON key; input was not accepted')
            result[key] = value
        return result
    try:
        return json.loads(Path(path).read_text(), object_pairs_hook=unique,
                          parse_constant=lambda _: (_ for _ in ()).throw(ConfigError('Non-finite JSON number')))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ConfigError('Cannot read a valid UTF-8 JSON document') from error


def object_keys(value, allowed, context, required=()):
    if not isinstance(value, dict):
        raise ConfigError(f'{context} must be an object')
    if set(value) - set(allowed):
        raise ConfigError(f'{context} contains unsupported fields; nothing was silently dropped')
    if set(required) - set(value):
        raise ConfigError(f'{context} is missing required fields: {", ".join(sorted(set(required) - set(value)))}')


def text(value, context, nonempty=True):
    if not isinstance(value, str) or (nonempty and not value) or any(ord(c) < 32 for c in value):
        raise ConfigError(f'{context} must be a string without control characters')
    return value


def integer(value, context, minimum=0, maximum=65535):
    if type(value) is not int or not minimum <= value <= maximum:
        raise ConfigError(f'{context} must be an integer in {minimum}..{maximum}')
    return value


def private_destination(value):
    """Generator policy: explicit RFC1918, ULA or loopback, not reserved ranges."""
    try:
        ip = ipaddress.ip_address(value)
    except (ValueError, TypeError):
        return False
    networks = ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '127.0.0.0/8', 'fc00::/7', '::1/128')
    return any(ip in ipaddress.ip_network(net) for net in networks)


def load_rules(version):
    rules = yaml.safe_load(RULES_PATH.read_text())
    if version not in rules['versions']:
        raise ConfigError('No reviewed generation rules for this exact version; refresh official evidence first')
    sources = yaml.safe_load((ROOT / 'sources.yaml').read_text())
    selected = rules['versions'][version]
    repository = sources['repositories'][selected['repository']]
    if repository.get('tag') != version:
        raise ConfigError('Generation rules do not match the pinned source version')
    selected = dict(selected, version=version, commit=repository['commit'])
    return rules, selected


def config_fields(version, struct_name):
    """Use pinned struct tags to reject unknown keys, never to infer runtime support."""
    _, selected = load_rules(version)
    manifest = read_json(ROOT / 'source/snapshot-manifest.json')['files']
    for path in sorted((ROOT / selected['config_root']).glob('*.go')):
        content = path.read_bytes()
        match = re.search(r'type ' + re.escape(struct_name) + r' struct\s*\{(.*?)^\}',
                          content.decode(), re.M | re.S)
        if not match:
            continue
        entry = manifest.get(path.relative_to(ROOT).as_posix(), {})
        if entry.get('sha256') != digest(content) or entry.get('commit') != selected['commit']:
            raise ConfigError('Official field evidence is missing, modified or pinned to another version')
        fields = {}
        for go_type, name in re.findall(r'^\s*\w+\s+(\S+)\s+`json:"([^",]+)(?:,[^"]*)?"`', match[1], re.M):
            if name != '-':
                fields[name] = go_type
        return fields
    raise ConfigError('No pinned field evidence for the requested configuration object')


def check_fields(value, version, struct_name, context):
    fields = config_fields(version, struct_name)
    object_keys(value, fields, context)
    for name, item in value.items():
        kind = fields[name].lstrip('*')
        if item is None:
            raise ConfigError(f'{context}: null is not accepted by the generator')
        if kind == 'string':
            text(item, context, nonempty=False)
        elif kind == 'bool' and type(item) is not bool:
            raise ConfigError(f'{context}: expected a boolean')
        elif kind in ('int32', 'int64', 'uint16', 'uint32', 'uint64'):
            bits = int(re.search(r'\d+', kind)[0])
            integer(item, context, 0 if kind.startswith('u') else -(2 ** (bits - 1)),
                    2 ** bits - 1 if kind.startswith('u') else 2 ** (bits - 1) - 1)
        elif kind == 'Int32Range':
            if type(item) is int:
                integer(item, context, 0, 2 ** 31 - 1)
            elif isinstance(item, str) and re.fullmatch(r'\d+(?:-\d+)?', item):
                parts = [int(x) for x in item.split('-')]
                if max(parts) > 2 ** 31 - 1 or parts[-1] < parts[0]:
                    raise ConfigError(f'{context}: invalid range')
            else:
                raise ConfigError(f'{context}: expected a nonnegative integer or range string')
        elif kind == 'map[string]string':
            if not isinstance(item, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in item.items()):
                raise ConfigError(f'{context}: expected a string map')
            for key, field in item.items():
                text(key, context)
                text(field, context, nonempty=False)
        elif kind == 'XmuxConfig':
            check_fields(item, version, kind, 'xmux')
        elif kind == 'StringList':
            if not isinstance(item, list) or not all(isinstance(x, str) for x in item):
                raise ConfigError(f'{context}: expected a string list')
        elif kind not in ('string', 'bool', 'Int32Range') and not re.fullmatch(r'u?int\d+', kind):
            raise ConfigError(f'{context}: this nested field needs additional reviewed rules; use the official reference')


def validate_transport(version, name, settings, security, flow='', encrypted=False):
    rules, _ = load_rules(version)
    name = rules['aliases'].get(name, name)
    if name in rules['removed']:
        raise ConfigError('This standalone transport was removed; XHTTP H2/H3 are separate supported capabilities')
    if name not in rules['transports']:
        raise ConfigError('Transport has no reviewed generation profile')
    profile = rules['transports'][name]
    if version not in profile.get('versions', rules['versions']):
        raise ConfigError('This transport profile is not available for the selected version')
    if profile.get('generate') is False:
        raise ConfigError('Core capability exists, but its topology is not yet covered by this generator; consult the versioned reference')
    if security not in profile['security']:
        raise ConfigError('Transport and security combination is not in the reviewed generator profiles')
    if flow and flow not in ('xtls-rprx-vision', 'xtls-rprx-vision-udp443'):
        raise ConfigError('Unsupported VLESS flow')
    if flow and not encrypted and (name != 'raw' or security not in ('tls', 'reality')):
        raise ConfigError('Without VLESS Encryption, this generator only enables Vision on RAW + TLS/REALITY')
    check_fields(settings, version, profile['struct'], 'transport settings')
    if name == 'xhttp':
        if settings.get('mode', 'auto') not in ('auto', 'packet-up', 'stream-up', 'stream-one'):
            raise ConfigError('Invalid XHTTP mode')
        if any(k.lower() == 'host' for k in settings.get('headers', {})):
            raise ConfigError('XHTTP headers cannot contain Host; use host')
        xmux = settings.get('xmux', {})
        if xmux.get('maxConcurrency', 0) not in (0, '0') and xmux.get('maxConnections', 0) not in (0, '0'):
            raise ConfigError('XMUX maxConcurrency and maxConnections are mutually exclusive')
        if settings.get('uplinkDataPlacement') in ('cookie', 'header') and settings.get('mode') != 'packet-up':
            raise ConfigError('Uplink data in cookie/header requires packet-up')
        if settings.get('uplinkHTTPMethod', 'POST').upper() == 'GET' and settings.get('mode') != 'packet-up':
            raise ConfigError('GET uplink requires packet-up')
        if settings.get('xPaddingBytes') in (0, '0', '0-0'):
            raise ConfigError('XHTTP padding cannot be disabled')
    if name == 'httpupgrade' and any(k.lower() == 'host' for k in settings.get('headers', {})):
        raise ConfigError('HTTPUpgrade headers cannot contain Host; use host')
    if name == 'masque':
        headers = {key.lower(): value for key, value in settings.get('headers', {}).items()}
        if 'host' in headers or 'capsule-protocol' in headers:
            raise ConfigError('MASQUE headers cannot override Host or capsule-protocol')
        if 'authorization' in headers and (settings.get('user') or settings.get('pass')):
            raise ConfigError('MASQUE header authentication conflicts with user/pass')
        if ':' in settings.get('user', ''):
            raise ConfigError('MASQUE user cannot contain a colon')
        path = settings.get('path', '')
        for template in ('{target}', '{ipproto}', '{?target,ipproto}', '{?ipproto,target}', '{&target,ipproto}', '{&ipproto,target}'):
            path = path.replace(template, '*')
        if path and (not path.startswith('/') or '{' in path or '}' in path):
            raise ConfigError('Invalid MASQUE path template')
    if name == 'hysteria' and settings.get('version') != 2:
        raise ConfigError('Hysteria transport requires version: 2')
    return name, profile
