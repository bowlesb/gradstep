#!/usr/bin/env python3
"""Run the Python operations tests (tests/operations/test_*.py) and fail loudly.

Fails on any failure or error, on zero tests, on a missing file, and on any skipped or expected-failure test: an
operations contract that cannot run is not a pass. `--no-database` leaves out the suites that need the disposable local
PostgreSQL 18 server on 127.0.0.1:55431 (the fast tier has no database); `npm run test:ops` runs them all.
"""
import argparse
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
DATABASE_SUITES = {'test_restore_quarantine'}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--no-database', action='store_true', help='Skip the suites that need the local PostgreSQL server.')
    args = parser.parse_args(argv)
    names = sorted(path.stem for path in (ROOT / 'tests/operations').glob('test_*.py'))
    if args.no_database:
        names = [name for name in names if name not in DATABASE_SUITES]
    if not names:
        print('No operations test files found', file=sys.stderr)
        return 1
    sys.path.insert(0, str(ROOT / 'tests/operations'))
    suite = unittest.TestSuite(unittest.defaultTestLoader.loadTestsFromName(name) for name in names)
    result = unittest.TextTestRunner(verbosity=1).run(suite)
    problems = []
    if result.testsRun == 0: problems.append('no tests ran')
    if result.skipped: problems.append(f'{len(result.skipped)} skipped')
    if result.expectedFailures or result.unexpectedSuccesses: problems.append('expected-failure markers present')
    if not result.wasSuccessful(): problems.append(f'{len(result.failures)} failed, {len(result.errors)} errors')
    print(f'operations (Python): {result.testsRun} tests in {len(names)} files' + (f' — FAILED: {"; ".join(problems)}' if problems else ' — passed'))
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
