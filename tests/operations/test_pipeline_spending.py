import datetime as dt
import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest import mock
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('pipeline_spending', ROOT / 'scripts/inspect-pipeline-spending.py')
SPENDING = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SPENDING)
START = dt.datetime(2026, 10, 6, tzinfo=dt.timezone.utc)
END = START + dt.timedelta(days=1)


def series(value, revision='fixture-revision', metric_labels=None):
    return {'resource': {'labels': {'project_id': SPENDING.PROJECT, 'service_name': SPENDING.SERVICE,
                                   'location': SPENDING.REGION, 'revision_name': revision}},
            'metric': {'labels': metric_labels or {}},
            'points': [{'value': {'doubleValue': value}}]}


class PipelineSpendingTests(unittest.TestCase):
    def test_pages_are_aggregated_with_a_fixed_service_region_and_window(self):
        urls = []
        def get(url):
            urls.append(url)
            params = parse_qs(urlsplit(url).query)
            self.assertIn('resource.labels.service_name="gradstep-pipeline"', params['filter'][0])
            self.assertIn('resource.labels.location="us-west1"', params['filter'][0])
            self.assertEqual(params['interval.startTime'], [START.isoformat()])
            self.assertEqual(params['aggregation.perSeriesAligner'], ['ALIGN_SUM'])
            self.assertEqual(params['aggregation.alignmentPeriod'], ['86400s'])
            if 'pageToken' not in params:
                return {'timeSeries': [series(12)], 'nextPageToken': 'fixture-next'}
            return {'timeSeries': [series(18, 'second-revision')]}
        result = SPENDING.metric_report(get, 'container/billable_instance_time', START, END)
        self.assertEqual(result['total'], 30)
        self.assertEqual(result['unit'], 'seconds')
        self.assertTrue(result['observed'])
        self.assertEqual(len(urls), 2)

    def test_revision_instance_peaks_are_not_summed_as_a_concurrent_service_peak(self):
        def get(url):
            self.assertEqual(parse_qs(urlsplit(url).query)['aggregation.perSeriesAligner'], ['ALIGN_MAX'])
            return {'timeSeries': [series(3), series(3, 'second-revision')]}
        result = SPENDING.metric_report(get, 'container/instance_count', START, END)
        self.assertNotIn('total', result)
        self.assertEqual(result['aggregation'], 'per_revision_peak_not_service_peak')

    def test_absent_series_are_unknown_not_a_zero_invoice(self):
        result = SPENDING.inspect(lambda _: {}, {}, START, END)
        self.assertFalse(result['allocation_is_invoice'])
        self.assertFalse(result['expected_deployment_policy'])
        for metric in ('container/billable_instance_time', 'request_count'):
            self.assertIsNone(result['metrics'][metric]['total'])
            self.assertFalse(result['metrics'][metric]['observed'])

    def test_failed_queries_and_incomplete_inventory_remain_visible(self):
        def get(url):
            if '/timeSeries' in url: raise SPENDING.InspectionError('http_403')
            if '/datasets' in url: return {'datasets': [{'datasetReference': {'datasetId': 'billing'}}], 'nextPageToken': 'next'}
            if '/alertPolicies' in url: return {'alertPolicies': [{'enabled': True}, {'enabled': False}], 'nextPageToken': 'next'}
            return {'billingEnabled': True, 'billingAccountName': 'do-not-print-fixture'}
        result = SPENDING.inspect(get, {}, START, END)
        self.assertEqual(result['metrics']['request_count'], {'error': 'http_403', 'observed': False})
        self.assertEqual(result['checks']['billing_export_datasets'], {'datasets': ['billing'], 'complete': False})
        self.assertEqual(result['checks']['alert_policies'], {'policy_count': 2, 'enabled_count': 1, 'complete': False})
        self.assertNotIn('do-not-print-fixture', json.dumps(result))

    def test_foreign_series_invalid_numbers_and_repeated_pages_fail_closed(self):
        wrong = series(3); wrong['resource']['labels']['project_id'] = 'unrelated-project'
        with self.assertRaisesRegex(SPENDING.InspectionError, 'metric_scope_mismatch'):
            SPENDING.metric_report(lambda _: {'timeSeries': [wrong]}, 'request_count', START, END)
        for value in (-1, float('nan'), float('inf'), None, 'invalid'):
            with self.subTest(value=value), self.assertRaises(SPENDING.InspectionError):
                SPENDING.metric_report(lambda _: {'timeSeries': [series(value)]}, 'request_count', START, END)
        with self.assertRaisesRegex(SPENDING.InspectionError, 'repeated_page'):
            SPENDING.metric_report(lambda _: {'nextPageToken': 'same'}, 'request_count', START, END)

    def test_arbitrary_labels_and_configuration_secrets_are_excluded(self):
        def get(url):
            return {'timeSeries': [series(1, metric_labels={'response_code': '200', 'custom_secret': 'do-not-print-fixture'})]}
        result = SPENDING.inspect(get, {'spec': {'template': {'spec': {'containers': [{'env': [
            {'name': 'API_KEY', 'value': 'do-not-print-fixture'}]}]}}}}, START, END)
        self.assertNotIn('do-not-print-fixture', json.dumps(result))
        self.assertNotIn('custom_secret', json.dumps(result))

    def test_transport_refuses_foreign_hosts_and_projects_before_connecting(self):
        with mock.patch.object(SPENDING.urllib.request, 'build_opener') as opener:
            for url in ('https://other.invalid/v3/projects/gradstep/timeSeries',
                        'https://monitoring.googleapis.com/v3/projects/textbrain/timeSeries'):
                with self.assertRaises(SPENDING.InspectionError): SPENDING.get_json('fixture', url)
            opener.assert_not_called()

    def test_main_never_exposes_provider_or_cli_error_details(self):
        out = io.StringIO()
        from contextlib import redirect_stdout
        with mock.patch('sys.argv', ['inspect-pipeline-spending.py']), \
             mock.patch.object(SPENDING.subprocess, 'run', side_effect=ValueError('secret-fixture')), redirect_stdout(out):
            self.assertEqual(SPENDING.main(), 1)
        self.assertEqual(json.loads(out.getvalue()), {'error': 'pipeline_spending_inspection_failed'})


if __name__ == '__main__': unittest.main()
