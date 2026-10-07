#!/usr/bin/env python3
"""Read-only Cloud Run configuration and allocation evidence for the dedicated Gradstep project.

  python3 scripts/inspect-pipeline-spending.py --hours 24 --output .artifacts/pipeline-spending.json

Uses existing gcloud authentication. No provisioning, log bodies, secrets, invoices or billable queries.
Allocation metrics are observed resource usage, not an invoice or a guaranteed final cost.
"""
import argparse
import datetime as dt
import importlib.util
import json
import math
from pathlib import Path
import subprocess
import urllib.error
import urllib.parse
import urllib.request

PROJECT = 'gradstep'
REGION = 'us-west1'
SERVICE = 'gradstep-pipeline'
MAX_RESPONSE = 8 * 1024 * 1024
METRICS = {
    'container/billable_instance_time': ('seconds', 'ALIGN_SUM'),
    'container/cpu/allocation_time': ('vcpu_seconds', 'ALIGN_SUM'),
    'container/memory/allocation_time': ('gib_seconds', 'ALIGN_SUM'),
    'container/instance_count': ('instances', 'ALIGN_MAX'),
    'request_count': ('requests', 'ALIGN_SUM'),
}
SPEC = importlib.util.spec_from_file_location('pipeline_deploy', Path(__file__).with_name('deploy-pipeline-worker.py'))
DEPLOY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DEPLOY)


class InspectionError(Exception):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise InspectionError('redirect_refused')


def get_json(token, url):
    """Only fixed Google read APIs; no raw response/error text can escape."""
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != 'https' or parsed.hostname not in {
        'monitoring.googleapis.com', 'cloudbilling.googleapis.com', 'bigquery.googleapis.com'}:
        raise InspectionError('scope_refused')
    if not (f'/projects/{PROJECT}/' in parsed.path): raise InspectionError('project_scope_refused')
    request = urllib.request.Request(url, headers={'Authorization': 'Bearer ' + token})
    try:
        with urllib.request.build_opener(NoRedirect).open(request, timeout=30) as response:
            data = response.read(MAX_RESPONSE + 1)
        if len(data) > MAX_RESPONSE: raise InspectionError('response_limit')
        value = json.loads(data)
        if not isinstance(value, dict): raise InspectionError('invalid_response')
        return value
    except urllib.error.HTTPError as error: raise InspectionError(f'http_{error.code}') from None
    except (urllib.error.URLError, TimeoutError, ValueError): raise InspectionError('request_failed') from None


def points_value(series):
    values = []
    for point in series.get('points', []):
        raw = point.get('value', {})
        if not isinstance(raw, dict) or len(set(raw) & {'doubleValue', 'int64Value'}) != 1:
            raise InspectionError('invalid_metric')
        try: value = float(raw.get('doubleValue', raw.get('int64Value')))
        except (TypeError, ValueError): raise InspectionError('invalid_metric') from None
        if not math.isfinite(value) or value < 0: raise InspectionError('invalid_metric')
        values.append(value)
    return values


def metric_report(get, metric, start, end):
    unit, aligner = METRICS[metric]
    params = {
        'filter': f'metric.type="run.googleapis.com/{metric}" AND resource.type="cloud_run_revision" '
                  f'AND resource.labels.service_name="{SERVICE}" AND resource.labels.location="{REGION}"',
        'interval.startTime': start.isoformat(), 'interval.endTime': end.isoformat(),
        'view': 'FULL', 'pageSize': 1000,
        'aggregation.alignmentPeriod': f'{int((end - start).total_seconds())}s',
        'aggregation.perSeriesAligner': aligner,
    }
    rows, seen = [], set()
    for _ in range(20):
        value = get(f'https://monitoring.googleapis.com/v3/projects/{PROJECT}/timeSeries?' + urllib.parse.urlencode(params))
        for series in value.get('timeSeries', []):
            labels = series.get('resource', {}).get('labels', {})
            if labels.get('project_id') != PROJECT or labels.get('service_name') != SERVICE or labels.get('location') != REGION:
                raise InspectionError('metric_scope_mismatch')
            values = points_value(series)
            if not values: raise InspectionError('missing_metric_points')
            row = {'revision': labels.get('revision_name'), 'value': max(values, default=0) if aligner == 'ALIGN_MAX' else sum(values)}
            # These are known service-metric labels, never arbitrary resource labels or customer text.
            for key in ('state', 'response_code', 'response_code_class'):
                if key in series.get('metric', {}).get('labels', {}): row[key] = series['metric']['labels'][key]
            rows.append(row)
        token = value.get('nextPageToken')
        if not token: break
        if token in seen: raise InspectionError('repeated_page')
        seen.add(token); params['pageToken'] = token
    else: raise InspectionError('page_limit')
    report = {'unit': unit, 'series': rows, 'observed': bool(rows)}
    # Peak counts from different revisions cannot be summed into a simultaneous service peak.
    if aligner == 'ALIGN_SUM': report['total'] = sum(row['value'] for row in rows) if rows else None
    else: report['aggregation'] = 'per_revision_peak_not_service_peak'
    return report


def inspect(get, service, start, end):
    policy = DEPLOY.deployment_policy(service)
    try: DEPLOY.verify_policy(policy); policy_match = True
    except RuntimeError: policy_match = False
    report = {'format': 1, 'project': PROJECT, 'region': REGION, 'service': SERVICE,
              'window_start': start.isoformat(), 'window_end': end.isoformat(),
              'generated_at': dt.datetime.now(dt.timezone.utc).isoformat(),
              'allocation_is_invoice': False, 'expected_deployment_policy': policy_match,
              'configuration': policy, 'metrics': {}, 'checks': {},
              'limitations': ['Metric publication can lag; the default window ends three minutes ago.',
                             'Missing series mean unavailable or no reported data, not verified zero usage.',
                             'Allocation does not include pricing, credits, shared free allowances or all invoice items.',
                             'No datasets in this project does not rule out a billing export in another project.']}
    for metric in METRICS:
        try: report['metrics'][metric] = metric_report(get, metric, start, end)
        except InspectionError as error: report['metrics'][metric] = {'error': str(error), 'observed': False}
    for name, url in {
        'billing': f'https://cloudbilling.googleapis.com/v1/projects/{PROJECT}/billingInfo',
        'billing_export_datasets': f'https://bigquery.googleapis.com/bigquery/v2/projects/{PROJECT}/datasets?maxResults=100',
        'alert_policies': f'https://monitoring.googleapis.com/v3/projects/{PROJECT}/alertPolicies?pageSize=100',
    }.items():
        try:
            value = get(url)
            if name == 'billing': safe = {'enabled': value.get('billingEnabled'), 'account_linked': bool(value.get('billingAccountName'))}
            elif name == 'billing_export_datasets':
                safe = {'datasets': [row.get('datasetReference', {}).get('datasetId') for row in value.get('datasets', [])],
                        'complete': not bool(value.get('nextPageToken'))}
            else:
                safe = {'policy_count': len(value.get('alertPolicies', [])),
                        'enabled_count': sum(row.get('enabled', True) is True for row in value.get('alertPolicies', [])),
                        'complete': not bool(value.get('nextPageToken'))}
            report['checks'][name] = safe
        except InspectionError as error: report['checks'][name] = {'error': str(error)}
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--hours', type=int, default=24)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if not 1 <= args.hours <= 744: parser.error('--hours must be from 1 through 744')
    try:
        token = subprocess.run(['gcloud', 'auth', 'print-access-token'], capture_output=True, text=True, check=True).stdout.strip()
        service = json.loads(subprocess.run(['gcloud', 'run', 'services', 'describe', SERVICE, '--project', PROJECT,
            '--region', REGION, '--format=json'], capture_output=True, text=True, check=True).stdout)
        end = dt.datetime.now(dt.timezone.utc).replace(microsecond=0) - dt.timedelta(minutes=3)
        report = inspect(lambda url: get_json(token, url), service, end - dt.timedelta(hours=args.hours), end)
        encoded = json.dumps(report, indent=2, sort_keys=True) + '\n'
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(encoded)
            print(json.dumps({'saved': str(args.output), 'expected_deployment_policy': report['expected_deployment_policy'],
                              'allocation_is_invoice': False}))
        else: print(encoded, end='')
        return 0
    except Exception:
        print(json.dumps({'error': 'pipeline_spending_inspection_failed'}))
        return 1


if __name__ == '__main__': raise SystemExit(main())
