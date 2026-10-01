"""Pure parsing tests: never download or execute an external binary."""
import io
from pathlib import Path
import stat
import sys
import unittest
from unittest.mock import patch
import warnings
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from fetch_core import FetchError, allowed_download, checksum, unpack


class FetchParsingTests(unittest.TestCase):
    def archive(self, entries):
        output = io.BytesIO()
        with warnings.catch_warnings():
            warnings.simplefilter('ignore', UserWarning)
            with zipfile.ZipFile(output, 'w') as archive:
                for name, data in entries:
                    archive.writestr(name, data)
        return output.getvalue()

    def test_checksum_sources(self):
        sha = 'ab' * 32
        self.assertEqual(checksum('sha256:' + sha, ('SHA2-256 (archive.zip) = ' + sha).encode()), sha)
        self.assertEqual(checksum(None, ('SHA256= ' + sha).encode()), sha)
        self.assertEqual(checksum('sha256:' + sha, None), sha)

    def test_checksum_rejects_missing_conflict_duplicates(self):
        sha = 'a' * 64
        for api, data in ((None, None), ('md5:' + sha, None), ('sha256:' + sha, b'SHA256= ' + b'b' * 64),
                          (None, b'\xff'), (None, (('SHA256= ' + sha + '\n') * 2).encode())):
            with self.assertRaises(FetchError):
                checksum(api, data)

    def test_hosts(self):
        allowed_download('https://github.com/XTLS/Xray-core/releases/download/v1/asset')
        for url in ('http://github.com/a', 'https://github.com.evil.test/a', 'https://user@github.com/a',
                    'https://github.com:8443/a', 'file:///tmp/asset'):
            with self.assertRaises(FetchError):
                allowed_download(url)

    def test_archive_subset(self):
        binary, license_data = unpack(self.archive([('xray', b'\x7fELFtest'), ('LICENSE', b'license'), ('geoip.dat', b'unused')]))
        self.assertEqual(binary, b'\x7fELFtest')
        self.assertEqual(license_data, b'license')

    def test_unsafe_archives(self):
        for entries in ([('xray', b'not ELF')], [('other', b'\x7fELF')],
                        [('xray', b'\x7fELF'), ('../escape', b'bad')],
                        [('xray', b'\x7fELF'), ('/absolute', b'bad')],
                        [('xray', b'\x7fELF'), ('xray', b'\x7fELF')]):
            with self.assertRaises(FetchError):
                unpack(self.archive(entries))
        link = zipfile.ZipInfo('link')
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        with self.assertRaises(FetchError):
            unpack(self.archive([('xray', b'\x7fELF'), (link, b'/tmp')]))
        with self.assertRaises(FetchError):
            unpack(b'not a zip')

    def test_archive_size_bound(self):
        with patch('fetch_core.MAX_BINARY', 4):
            with self.assertRaises(FetchError):
                unpack(self.archive([('xray', b'\x7fELFtoo large')]))


if __name__ == '__main__':
    unittest.main()
