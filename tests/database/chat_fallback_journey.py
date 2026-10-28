"""Zero-spend chat journey on the real migrated schema (migration 0163, JUDGMENT_LOG 55): the TypeScript chat code (run by
Node) calls the SQL functions through psql; OpenRouter is a local fake. Every action with a fallback, after a silent Flash,
is answered by Haiku inside the hold the reader accepted."""
import os
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[2]


def verify(bin_path, db, base):
    base = list(base)
    if len(base) != 4 or base[:3] != ['-h', '127.0.0.1', '-p'] or not base[3].isdigit() or not db.startswith('science_reader_test_'):
        raise ValueError('Refusing a non-disposable/non-loopback chat journey target')
    env = {k: v for k, v in os.environ.items() if not k.startswith('PG')}
    result = subprocess.run(['node', str(ROOT / 'tests/database/chat-fallback-journey.ts')], cwd=ROOT, capture_output=True, text=True, timeout=600,
                            env={**env, 'CHAT_JOURNEY_PSQL': str(bin_path / 'psql'), 'CHAT_JOURNEY_PORT': base[3], 'CHAT_JOURNEY_DB': db})
    if result.returncode:
        raise AssertionError(result.stdout[-4000:] + result.stderr[-4000:])
    print('PASS chat fallback journey:', result.stdout.strip().splitlines()[-1], flush=True)
