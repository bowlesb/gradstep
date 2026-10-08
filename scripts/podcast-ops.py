#!/usr/bin/env python3
"""Paper podcast operator tool (docs/architecture/PAPER_PODCASTS.md "Seed pilot runbook"). Staging only.

  python3 scripts/podcast-ops.py status
  python3 scripts/podcast-ops.py candidates [--limit 20]
  python3 scripts/podcast-ops.py policy --actor <owner-account> --set seed_enabled=true --set catalog_enabled=true --reason "..."
  python3 scripts/podcast-ops.py seed-period --actor <owner-account> --limit-usd 2 --enable --evidence owner-decision-20261008
  python3 scripts/podcast-ops.py seed --actor <owner-account> --approval <approval-id> --reason "..." [--fixture]
  python3 scripts/podcast-ops.py kick
  python3 scripts/podcast-ops.py review --actor <owner-account> --release <release-id> --publish|--reject --reason "..."
  python3 scripts/podcast-ops.py rights --actor <owner-account> --episode <episode-id> --state quarantined --reason "..."
  python3 scripts/podcast-ops.py cleanup
  python3 scripts/podcast-ops.py resolve-write --actor <owner-account> --write <write-id> --outcome not_written|verified --evidence <reference>

Every mutating call takes an explicit owner account (the database rechecks the owner role) and a request id; the id
is printed before the call so a lost reply can be replayed with --request-id (the database returns the same result
instead of acting twice). The service key comes from .env.staging and is never printed. Nothing here makes a provider
call itself: `seed` admits one job and wakes the worker, which spends inside the database-enforced grants.
"""
import argparse, json, re, sys, urllib.error, urllib.request, uuid
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STAGING = 'coxhjvqpflgxkleydati'
UUID = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
POLICY_KEYS = {'catalog_enabled', 'delivery_enabled', 'generation_enabled', 'seed_enabled', 'fixtures_enabled',
               'max_active_private_per_account', 'max_active_environment', 'max_jobs_day_environment', 'quality_allocation_microusd',
               'account_transfer_bytes_month', 'paid_account_transfer_bytes_month', 'environment_transfer_bytes_month'}


def env_file():
    # A git worktree has no .env.staging of its own; use the main checkout's.
    for base in [ROOT, *ROOT.parents]:
        if (base / '.env.staging').is_file() and (base / '.git').exists(): return base / '.env.staging'
    raise SystemExit('missing .env.staging')


def env_values():
    values = {}
    for line in env_file().read_text().splitlines():
        if '=' in line and not line.lstrip().startswith('#'):
            key, value = line.split('=', 1); values[key.strip()] = value.strip().strip('"').strip("'")
    if values.get('SUPABASE_PROJECT_REF') != STAGING: raise SystemExit('staging only')
    return values


def rpc(env, name, params):
    key = env.get('SUPABASE_SECRET_KEY') or env['SUPABASE_SERVICE_ROLE_KEY']
    request = urllib.request.Request(env['SUPABASE_URL'].rstrip('/') + '/rest/v1/rpc/' + name, data=json.dumps(params).encode(), method='POST',
                                     headers={'apikey': key, 'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            body = response.read()
            return json.loads(body) if body else None
    except urllib.error.HTTPError as error:
        detail = json.loads(error.read(2000) or b'{}')
        # Database errors are finite codes (RAISE messages), never secrets.
        raise SystemExit(f"{name}: HTTP {error.code} {detail.get('message') or detail.get('code') or ''}".strip()) from None


def uuid_arg(value):
    if not UUID.match(value or ''): raise argparse.ArgumentTypeError('expected a UUID')
    return value


def reason(value):
    value = (value or '').strip()
    if not 3 <= len(value) <= 500: raise argparse.ArgumentTypeError('reason must be 3-500 characters')
    return value


def policy_changes(pairs):
    changes = {}
    for pair in pairs:
        key, _, raw = pair.partition('=')
        if key not in POLICY_KEYS: raise SystemExit(f'unknown policy key: {key}')
        if raw in ('true', 'false'): changes[key] = raw == 'true'
        elif raw.isdigit(): changes[key] = int(raw)
        else: raise SystemExit(f'invalid value for {key}')
    if not changes: raise SystemExit('nothing to change')
    return changes


def request_id(args):
    value = args.request_id or str(uuid.uuid4())
    print(json.dumps({'request_id': value}), file=sys.stderr)
    return value


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('status'); sub.add_parser('kick'); sub.add_parser('cleanup')
    c = sub.add_parser('candidates'); c.add_argument('--limit', type=int, default=20)
    w = sub.add_parser('resolve-write', help='settle an uncertain upload with evidence (bucket listing / readback)')
    w.add_argument('--actor', type=uuid_arg, required=True); w.add_argument('--write', type=uuid_arg, required=True)
    w.add_argument('--outcome', choices=['verified', 'not_written'], required=True); w.add_argument('--evidence', required=True)
    for name in ('policy', 'seed-period', 'seed', 'review', 'rights'):
        p = sub.add_parser(name)
        p.add_argument('--actor', type=uuid_arg, required=True, help='your owner account id')
        p.add_argument('--request-id', type=uuid_arg, help='replay a previous call exactly')
        if name != 'seed-period': p.add_argument('--reason', type=reason, required=name != 'seed-period')
        if name == 'policy': p.add_argument('--set', action='append', default=[], metavar='KEY=VALUE')
        if name == 'seed-period':
            p.add_argument('--limit-usd', type=float, required=True); p.add_argument('--enable', action='store_true')
            p.add_argument('--evidence', required=True); p.add_argument('--period', help='YYYY-MM-01 (default: current UTC month)')
            p.add_argument('--max-episodes', type=int, default=2, choices=[0, 1, 2], help='Decision 2 approves at most two seed episodes')
        if name == 'seed':
            p.add_argument('--approval', type=uuid_arg, required=True); p.add_argument('--fixture', action='store_true')
        if name == 'review':
            p.add_argument('--release', type=uuid_arg, required=True)
            group = p.add_mutually_exclusive_group(required=True)
            group.add_argument('--publish', action='store_true'); group.add_argument('--reject', action='store_true')
        if name == 'rights':
            p.add_argument('--episode', type=uuid_arg, required=True)
            p.add_argument('--state', choices=['active', 'quarantined', 'withdrawn'], required=True)
    args = parser.parse_args(argv)
    env = env_values()
    if args.command == 'status': result = rpc(env, 'worker_podcast_status', {})
    elif args.command == 'candidates': result = rpc(env, 'worker_podcast_seed_candidates', {'p_limit': args.limit})
    elif args.command == 'kick': result = rpc(env, 'worker_podcast_kick_due', {})
    elif args.command == 'policy':
        result = rpc(env, 'worker_podcast_policy_set', {'p_actor': args.actor, 'p_request_id': request_id(args),
                                                       'p_changes': policy_changes(args.set), 'p_reason': args.reason})
    elif args.command == 'seed-period':
        microusd = round(args.limit_usd * 1_000_000)
        if not 0 <= microusd <= 2_000_000: raise SystemExit('the approved seed allowance is at most $2')
        period = args.period or datetime.now(timezone.utc).strftime('%Y-%m-01')
        result = rpc(env, 'worker_podcast_seed_period', {'p_actor': args.actor, 'p_request_id': request_id(args), 'p_period': period,
                                                        'p_limit_microusd': microusd, 'p_enabled': args.enable, 'p_evidence': args.evidence,
                                                        'p_max_episodes': args.max_episodes})
    elif args.command == 'seed':
        result = rpc(env, 'worker_podcast_seed_admit', {'p_actor': args.actor, 'p_request_id': request_id(args),
                                                       'p_approval_id': args.approval, 'p_reason': args.reason, 'p_fixture': args.fixture})
    elif args.command == 'review':
        result = rpc(env, 'worker_podcast_review', {'p_actor': args.actor, 'p_request_id': request_id(args), 'p_release_id': args.release,
                                                   'p_decision': 'publish' if args.publish else 'reject', 'p_reason': args.reason})
    elif args.command == 'rights':
        result = rpc(env, 'worker_podcast_rights', {'p_actor': args.actor, 'p_request_id': request_id(args), 'p_episode_id': args.episode,
                                                   'p_state': args.state, 'p_reason': args.reason})
    elif args.command == 'resolve-write':
        result = rpc(env, 'worker_podcast_write_resolve', {'p_actor': args.actor, 'p_write_id': args.write, 'p_outcome': args.outcome,
                                                          'p_evidence': args.evidence})
    elif args.command == 'cleanup':
        result = rpc(env, 'worker_podcast_cleanup', {'p_limit': 50})
        objects = result.get('objects') or []
        if objects:
            key = env.get('SUPABASE_SECRET_KEY') or env['SUPABASE_SERVICE_ROLE_KEY']
            paths = [o['path'] for o in objects if o.get('bucket') == 'podcast-assets']
            request = urllib.request.Request(env['SUPABASE_URL'].rstrip('/') + '/storage/v1/object/podcast-assets', method='DELETE',
                                             data=json.dumps({'prefixes': paths}).encode(),
                                             headers={'apikey': key, 'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'})
            with urllib.request.urlopen(request, timeout=60): pass
            result['confirmed'] = rpc(env, 'worker_podcast_cleanup_confirm', {'p_object_ids': [o['id'] for o in objects]})
    print(json.dumps(result, indent=1, sort_keys=True))


if __name__ == '__main__':
    main()
