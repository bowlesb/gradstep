"""Where the local PostgreSQL 18 client/server binaries are (backups, restores, database tests, benchmarks).

`SCIENCE_READER_PG_BIN` always wins. Without it, the binaries are found on PATH (`psql`), and last the owner's Mac
keeps a portable PostgreSQL 18.4 build at LOCAL_TOOLS (docs/TESTING.md). That is a tool directory only: no script
reads another project's files, credentials or database through it. Anything else is a clear error, never a guess.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess

LOCAL_TOOLS = Path('/Users/benbowlwes/textbrain/scripts/.pgtools/postgresql-18.4.0-aarch64-apple-darwin/bin')


def pg_bin() -> Path:
    configured = os.environ.get('SCIENCE_READER_PG_BIN')
    if configured:
        path = Path(configured)
        if not (path / 'psql').is_file():
            raise SystemExit(f'SCIENCE_READER_PG_BIN has no psql: {path}')
        return path
    found = shutil.which('psql')
    if found and (Path(found).parent / 'pg_dump').is_file() and (Path(found).parent / 'createdb').is_file():
        version = subprocess.run([found, '--version'], capture_output=True, text=True, timeout=10).stdout
        if re.search(r'\b18\.\d+', version):
            return Path(found).parent
    if (LOCAL_TOOLS / 'psql').is_file():
        return LOCAL_TOOLS
    raise SystemExit('PostgreSQL 18 binaries not found: set SCIENCE_READER_PG_BIN to their bin directory (docs/TESTING.md).')
