"""Review A11 (2026-10-21): the operator script changes money only through owner-attributed, audited functions.

The script reads .env.staging when it starts, so this checks its source and its argument parser offline.
"""
import ast
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / 'scripts/pipeline-ops.py').read_text()
TREE = ast.parse(SOURCE)


def called_rpcs():
    names = set()
    for node in ast.walk(TREE):
        if isinstance(node, ast.Call) and getattr(node.func, 'id', None) == 'rpc' and node.args:
            first = node.args[0]
            if isinstance(first, ast.Constant) and isinstance(first.value, str):
                names.add(first.value)
    return names


def parser_arguments(command):
    """The flags declared for one sub-command (add_parser(command) followed by its add_argument calls)."""
    flags, current = {}, None
    for line in SOURCE.splitlines():
        if f"sub.add_parser('{command}'" in line:
            current = line.split('=')[0].strip()
        if current and f'{current}.add_argument(' in line:
            for part in line.split(f'{current}.add_argument(')[1:]:
                name = part.split(',')[0].strip().strip("'\"")
                flags[name] = 'required=True' in part.split(')')[0]
    return flags


class PipelineOpsSafeguards(unittest.TestCase):
    def test_no_unaudited_money_paths(self):
        rpcs = called_rpcs()
        for retired in ('worker_set_platform_budget', 'worker_grant_credits', 'worker_pipeline_resolve_uncertain'):
            self.assertNotIn(retired, rpcs, retired)
        self.assertIn('worker_owner_set_budget_limit', rpcs)
        self.assertIn('worker_openrouter_tariff_renew', rpcs)

    def test_budget_needs_an_owner_and_a_reason_and_never_touches_the_pause_switch(self):
        flags = parser_arguments('budget')
        self.assertEqual(flags, {'--usd': True, '--actor': True, '--reason': True})
        self.assertNotIn('not args.disable', SOURCE, 'a limit change never resumes a paused month')
        self.assertNotIn('datetime.date.today()', SOURCE, 'the database picks the UTC month')

    def test_grant_and_resolve_are_gone(self):
        self.assertNotIn("add_parser('grant'", SOURCE)
        self.assertNotIn("add_parser('resolve'", SOURCE)


if __name__ == '__main__':
    unittest.main()
