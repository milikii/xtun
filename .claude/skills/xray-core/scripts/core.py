#!/usr/bin/env python3
"""Invoke a user-selected Xray binary without installing services or logging secrets."""

import base64
import os
from pathlib import Path
import re
import shutil
import subprocess

from rules import ConfigError, digest, load_rules


def command(binary, args, timeout=20):
    try:
        result = subprocess.run([str(binary), *args], capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ConfigError('Xray command could not complete; private command output was not logged') from error
    if result.returncode:
        raise ConfigError('Xray command failed; private command output was not logged')
    return result.stdout + result.stderr


def identify(binary, version):
    _, selected = load_rules(version)
    path = Path(shutil.which(str(binary)) or binary).resolve()
    if not path.is_file() or not os.access(path, os.X_OK):
        raise ConfigError('An executable Xray binary is required')
    output = command(path, ['version'])
    if not re.match(r'Xray ' + re.escape(version.removeprefix('v')) + r'\s', output):
        raise ConfigError('Binary version does not match the requested exact version')
    if selected['commit'][:7] not in output.splitlines()[0]:
        raise ConfigError('Binary commit does not match the pinned source baseline')
    return path, {'version': version, 'commit': selected['commit'], 'sha256': digest(path.read_bytes()),
                  'provenance': 'User-selected binary; version/commit self-report checked, not a signature verification'}


def base64_key(value, sizes=(32,)):
    try:
        if not isinstance(value, str) or not re.fullmatch(r'[A-Za-z0-9_-]+', value):
            return False
        decoded = base64.b64decode(value + '=' * (-len(value) % 4), altchars=b'-_', validate=True)
        return len(decoded) in sizes
    except (ValueError, TypeError):
        return False


def x25519(binary, private=None):
    output = command(binary, ['x25519'] + (['-i', private] if private is not None else []))
    private_match = re.search(r'^PrivateKey:\s*(\S+)', output, re.M)
    public_match = re.search(r'^(?:Password(?: \(PublicKey\))?|PublicKey):\s*(\S+)', output, re.M)
    if not private_match or not public_match or not all(base64_key(m[1]) for m in (private_match, public_match)):
        raise ConfigError('Unrecognized X25519 command output; no credentials were logged')
    return private_match[1], public_match[1]


def encryption_pair(binary, authentication='x25519'):
    if authentication not in ('x25519', 'mlkem768'):
        raise ConfigError('Encryption authentication must be x25519 or mlkem768')
    output = command(binary, ['vlessenc'])
    blocks = re.split(r'^Authentication:\s*', output, flags=re.M)[1:]
    for block in blocks:
        heading = block.splitlines()[0].lower()
        if not heading.startswith(authentication):
            continue
        server = re.search(r'^"decryption":\s*"([^"\r\n]+)"', block, re.M)
        client = re.search(r'^"encryption":\s*"([^"\r\n]+)"', block, re.M)
        if server and client and server[1] != client[1] and all(m[1].startswith('mlkem768x25519plus.') for m in (server, client)):
            return server[1], client[1]
    raise ConfigError('The requested Encryption pair was not present in this binary output')
