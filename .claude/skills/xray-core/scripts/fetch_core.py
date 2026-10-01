#!/usr/bin/env python3
"""Cache a checksum-verified official Xray release. No system installation.

Downloading and executing an external binary requires the user's authorization.
Only `version` is executed here, after archive verification; configuration and
handshake tests are separate, explicit commands.
"""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from urllib.parse import quote, urlparse
from urllib.request import HTTPRedirectHandler, Request, build_opener
import zipfile

from upstream import API, HttpClient, UpstreamError, resolve_tag

ARCHIVES = {'amd64': 'Xray-linux-64.zip', 'arm64': 'Xray-linux-arm64-v8a.zip'}
MAX_ARCHIVE = 128 * 1024 * 1024
MAX_BINARY = 256 * 1024 * 1024


class FetchError(ValueError):
    pass


def allowed_download(url):
    parsed = urlparse(url)
    if parsed.scheme != 'https' or parsed.hostname not in ('github.com', 'release-assets.githubusercontent.com', 'objects.githubusercontent.com') or parsed.username or parsed.password or parsed.port not in (None, 443):
        raise FetchError('Refusing a download outside the official HTTPS release hosts')


class ReleaseRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        allowed_download(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def download(url, limit=MAX_ARCHIVE):
    allowed_download(url)
    try:
        with build_opener(ReleaseRedirects()).open(Request(url, headers={'User-Agent': 'xray-core-skill'}), timeout=90) as response:
            allowed_download(response.geturl())
            data = response.read(limit + 1)
    except OSError as error:
        raise FetchError('Official release download failed; nothing was executed') from error
    if len(data) > limit:
        raise FetchError('Release download exceeds the size limit')
    return data


def checksum(api_digest, dgst):
    api_hash = None
    if api_digest is not None:
        if not isinstance(api_digest, str) or not re.fullmatch(r'sha256:[a-fA-F0-9]{64}', api_digest):
            raise FetchError('Unrecognized API archive digest')
        api_hash = api_digest.split(':')[1].lower()
    file_hash = None
    if dgst is not None:
        try:
            lines = dgst.decode('ascii').splitlines()
        except UnicodeError as error:
            raise FetchError('Invalid official digest file') from error
        values = []
        for line in lines:
            match = re.fullmatch(r'(?:SHA2-256|SHA256)(?:\s*\([^\r\n]*\))?\s*=\s*([a-fA-F0-9]{64})\s*', line)
            if match:
                values.append(match[1].lower())
        if len(values) != 1:
            raise FetchError('Official digest file must contain exactly one SHA256 entry')
        file_hash = values[0]
    if api_hash and file_hash and api_hash != file_hash:
        raise FetchError('API and digest-file hashes disagree')
    if not (api_hash or file_hash):
        raise FetchError('Release has no usable official SHA256')
    return api_hash or file_hash


def unpack(archive):
    try:
        with zipfile.ZipFile(io.BytesIO(archive)) as z:
            names, total = set(), 0
            for info in z.infolist():
                path = PurePosixPath(info.filename)
                mode = info.external_attr >> 16
                if info.filename in names or path.is_absolute() or '..' in path.parts or '\\' in info.filename or stat.S_ISLNK(mode) or info.flag_bits & 1:
                    raise FetchError('Unsafe or duplicate ZIP entry')
                names.add(info.filename)
                total += info.file_size
                if info.file_size > MAX_BINARY or total > 512 * 1024 * 1024 or (info.compress_size and info.file_size > info.compress_size * 1000):
                    raise FetchError('ZIP expansion exceeds the size limit')
            if 'xray' not in names or z.getinfo('xray').is_dir():
                raise FetchError('Official archive does not contain the expected executable')
            binary = z.read('xray')
            if not binary.startswith(b'\x7fELF'):
                raise FetchError('Expected a Linux ELF executable')
            license_data = z.read('LICENSE') if 'LICENSE' in names else None
            return binary, license_data
    except (zipfile.BadZipFile, RuntimeError) as error:
        raise FetchError('Invalid official ZIP archive') from error


def fetch(version, output, arch='amd64'):
    if not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', version) or arch not in ARCHIVES:
        raise FetchError('Use an exact Xray release tag and a supported Linux architecture')
    output = Path(output).absolute()
    if output.exists() or output.is_symlink() or not output.parent.is_dir():
        raise FetchError('Choose a new output directory under an existing parent; no overwrites')
    client = HttpClient(token=os.environ.get('GITHUB_TOKEN'))
    release = client.json(API + '/releases/tags/' + quote(version, safe=''))
    if release.get('tag_name') != version or release.get('draft') is not False:
        raise FetchError('Release metadata does not match the requested public tag')
    commit = resolve_tag(client.json, version)
    archive_name = ARCHIVES[arch]
    assets = release.get('assets', [])
    def asset(name, required=True):
        matches = [a for a in assets if a.get('name') == name]
        if not matches and not required:
            return None
        if len(matches) != 1:
            raise FetchError('Official release asset is missing or ambiguous')
        value = matches[0]
        expected = 'https://github.com/XTLS/Xray-core/releases/download/' + version + '/' + name
        if value.get('browser_download_url') != expected:
            raise FetchError('Release asset URL does not match the official tag and filename')
        return value
    archive_asset = asset(archive_name)
    digest_asset = asset(archive_name + '.dgst', required=False)
    dgst = download(digest_asset['browser_download_url'], 65536) if digest_asset else None
    expected = checksum(archive_asset.get('digest'), dgst)
    archive = download(archive_asset['browser_download_url'])
    actual = hashlib.sha256(archive).hexdigest()
    if actual != expected:
        raise FetchError('Release archive hash mismatch; nothing was extracted or executed')
    binary, license_data = unpack(archive)
    temp = Path(tempfile.mkdtemp(prefix='.xray-release-', dir=output.parent))
    try:
        executable = temp / 'xray'
        executable.write_bytes(binary)
        executable.chmod(0o700)
        proc = subprocess.run([str(executable), 'version'], capture_output=True, text=True, timeout=15)
        first = proc.stdout.splitlines()[0] if proc.stdout else ''
        if proc.returncode or not first.startswith('Xray ' + version[1:] + ' ') or commit[:7] not in first:
            raise FetchError('Verified archive binary does not identify as the pinned release/commit')
        identity = {'tag': version, 'commit': commit, 'arch': arch, 'archive_sha256': actual,
                    'binary_sha256': hashlib.sha256(binary).hexdigest(), 'source_url': archive_asset['browser_download_url'],
                    'checksum_sources': ['official API'] if dgst is None else ['official .dgst'] + (['official API'] if archive_asset.get('digest') else []),
                    'version_output': first}
        (temp / 'identity.json').write_text(json.dumps(identity, indent=2) + '\n')
        (temp / 'identity.json').chmod(0o600)
        if license_data:
            (temp / 'LICENSE').write_bytes(license_data)
            (temp / 'LICENSE').chmod(0o600)
        output.mkdir(mode=0o700)
        for path in temp.iterdir():
            path.rename(output / path.name)
        return identity
    except (OSError, subprocess.TimeoutExpired) as error:
        raise FetchError('Verified binary could not execute on this host; no system installation was attempted') from error
    finally:
        shutil.rmtree(temp)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--arch', choices=ARCHIVES, default='amd64')
    args = parser.parse_args()
    try:
        identity = fetch(args.version, args.output, args.arch)
        print(json.dumps(identity, indent=2))
        return 0
    except (FetchError, UpstreamError, OSError, ValueError) as error:
        print(f'Fetch failed: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
