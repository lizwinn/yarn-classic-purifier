# SPDX-License-Identifier: MIT
import gzip
import io
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

HELPER = Path(sys.argv.pop(1)).resolve()


class ArchiveTests(unittest.TestCase):
    def test_only_timestamps_change_and_rebuild_bytes_match(self):
        with tempfile.TemporaryDirectory() as temporary:
            outputs = []
            for timestamp in (123456789, 987654321):
                archive = Path(temporary) / f'{timestamp}.tgz'
                with archive.open('wb') as raw:
                    with gzip.GzipFile(fileobj=raw, mode='wb', mtime=timestamp) as compressed:
                        with tarfile.open(fileobj=compressed, mode='w|') as output:
                            for name, kind, payload, mode, target in (
                                ('package', tarfile.DIRTYPE, b'', 0o755, ''),
                                ('package/run', tarfile.REGTYPE, b'#!/bin/sh\nexit 42\n', 0o755, ''),
                                ('package/payload', tarfile.REGTYPE, b'\x00\xff\x00', 0o640, ''),
                                ('package/link', tarfile.SYMTYPE, b'', 0o777, 'payload'),
                            ):
                                member = tarfile.TarInfo(name)
                                member.type, member.mode, member.linkname = kind, mode, target
                                member.mtime, member.size = timestamp, len(payload)
                                member.pax_headers = {'atime': str(timestamp), 'comment': 'preserved'}
                                output.addfile(member, io.BytesIO(payload) if payload else None)
                with tarfile.open(archive) as original:
                    expected = [(m.name, m.type, m.mode, m.linkname,
                                 original.extractfile(m).read() if m.isfile() else None) for m in original]
                subprocess.run([sys.executable, str(HELPER), str(archive)],
                               env=dict(os.environ, SOURCE_DATE_EPOCH='1'), check=True)
                with tarfile.open(archive) as normalized:
                    actual = []
                    for member in normalized:
                        self.assertEqual(member.mtime, 1)
                        self.assertEqual(member.pax_headers.get('comment'), 'preserved')
                        self.assertNotIn('atime', member.pax_headers)
                        actual.append((member.name, member.type, member.mode, member.linkname,
                                       normalized.extractfile(member).read() if member.isfile() else None))
                    self.assertEqual(actual, expected)
                outputs.append(archive.read_bytes())
            self.assertEqual(*outputs)


if __name__ == '__main__':
    unittest.main()
