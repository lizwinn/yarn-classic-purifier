#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Normalize native Yarn's archive timestamps, preserving members and payloads."""
import gzip
import os
from pathlib import Path
import sys
import tarfile
import tempfile

archive = Path(sys.argv[1])
epoch = int(os.environ['SOURCE_DATE_EPOCH'])
with tempfile.NamedTemporaryFile(dir=archive.parent, delete=False) as temporary:
    name = Path(temporary.name)
    try:
        with gzip.GzipFile(fileobj=temporary, mode='wb', filename='', mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode='w|', format=tarfile.PAX_FORMAT) as destination:
                with tarfile.open(archive, mode='r|gz') as source:
                    for member in source:
                        member.mtime = epoch
                        member.pax_headers = {key: value for key, value in member.pax_headers.items()
                                              if key not in ('mtime', 'atime', 'ctime')}
                        destination.addfile(member, source.extractfile(member) if member.isfile() else None)
        temporary.flush()
        name.replace(archive)
    finally:
        name.unlink(missing_ok=True)
