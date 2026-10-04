"""Offline log transport, interval, truncation and evidence-boundary checks."""
import copy
import datetime as dt
import importlib.util
import json
from pathlib import Path
import re
import unittest
from urllib.parse import parse_qs, urlsplit

HERE = Path(__file__).resolve().parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


O = load("tested_limits_observer", HERE / "observe.py")
F = load("limits_log_fixtures", HERE / "test_classify.py")


def raw(row):
    result = {name.replace(".", "_"): "" for name in O.FIELDS}
    result.update({k: v or "" for k, v in row.items() if k != "message"})
    result["event_message"] = row["message"] or "platform text must not be retained"
    return result


class Clock:
    def __init__(self, seconds=30):
        self.value = F.BASE + dt.timedelta(seconds=seconds)
        self.waits = []

    def now(self):
        return self.value

    def sleep(self, seconds):
        self.waits.append(seconds)
        self.value += dt.timedelta(seconds=seconds)


class LogAPI:
    def __init__(self, rows):
        self.rows, self.calls = rows, []
        self.error = None

    def management_request(self, path, limit):
        self.calls.append(path)
        if self.error is not None:
            return 200, self.error, {}
        params = parse_qs(urlsplit(path).query)
        sql = params["sql"][0]
        a = re.search(r"timestamp >= parseDateTime64BestEffort\('([^']+)'", sql).group(1)
        b = re.search(r"timestamp <= parseDateTime64BestEffort\('([^']+)'", sql).group(1)
        start, end = O.C.instant(a), O.C.instant(b)
        values = sorted((r for r in self.rows if start <= O.C.instant(r["timestamp"]) <= end), key=lambda r: r["timestamp"])
        return 200, {"result": copy.deepcopy(values[:50]), "error": None}, {}


def setup(count=4, seconds=30):
    evidence = F.example(count)
    rows = [raw(row) for row in evidence["rows"]]
    evidence["rows"] = []
    evidence["window"].update({"end": F.stamp(seconds), "complete": False})
    journal = {"log_queries": []}
    api, clock, saved = LogAPI(rows), Clock(seconds), []
    persist = lambda: saved.append(copy.deepcopy((journal, evidence)))
    observer = O.Observer(api, journal, evidence, persist, clock.now, clock.sleep)
    return observer, api, clock, journal, evidence, saved


class ObservationTests(unittest.TestCase):
    def test_query_binds_function_precise_utc_and_bounded_window(self):
        path = O.query_path(F.FUNCTION, F.stamp(1.123456), F.stamp(61.654321))
        params = parse_qs(urlsplit(path).query)
        sql = params["sql"][0]
        self.assertIn("source = 'function_logs'", sql)
        self.assertIn("log_attributes['function_id'] = '" + F.FUNCTION + "'", sql)
        self.assertIn("formatDateTime(logs.timestamp, '%Y-%m-%dT%H:%i:%S.%fZ', 'UTC')", sql)
        self.assertIn("AND logs.timestamp >= parseDateTime64BestEffort", sql)
        self.assertIn("AND logs.timestamp <= parseDateTime64BestEffort", sql)
        self.assertIn("ORDER BY logs.timestamp ASC", sql)
        self.assertIn(F.stamp(1.123456), sql)
        self.assertTrue(sql.endswith("LIMIT 50"))
        self.assertEqual(O.C.instant(params["iso_timestamp_start"][0]), F.BASE)
        self.assertEqual(O.C.instant(params["iso_timestamp_end"][0]), F.BASE + dt.timedelta(seconds=120))
        for a, b in ((F.stamp(2), F.stamp(1)), (F.stamp(0), F.stamp(1801))):
            with self.assertRaises(O.ObservationError):
                O.query_path(F.FUNCTION, a, b)
        with self.assertRaises(O.ObservationError):
            O.query_path("' OR 1=1", F.stamp(0), F.stamp(1))

    def test_control_logs_are_classified_before_retention(self):
        observer, api, clock, journal, evidence, saved = setup()
        report = observer.observe()
        self.assertTrue(report["observation_complete"])
        self.assertEqual(report["cases"][3]["status"], "completed")
        self.assertFalse(report["hosted_admitted"])
        self.assertEqual(journal["log_queries"][0]["state"], "complete")
        self.assertEqual(saved[1][0]["log_queries"][0]["state"], "dispatching")

    def test_unknown_text_and_exception_messages_never_persist(self):
        observer, api, _, journal, evidence, saved = setup()
        secret = "secret-canary-token-and-private-text"
        api.rows.append(raw(F.row(F.uid(4, 30), 10, "UncaughtException", message=secret)))
        api.rows.append(raw(F.row(F.uid(4, 31), 11, "Log", message=secret)))
        observer.observe()
        self.assertNotIn(secret, json.dumps(saved))
        self.assertTrue(any(row["event_type"] == "UncaughtException" for row in evidence["rows"]))

    def test_finite_shutdown_accounting_keeps_its_actual_scope(self):
        observer, api, _, journal, evidence, _ = setup(5)
        stop = next(row for row in api.rows if row["event_type"] == "Shutdown")
        stop.update({"cpu_time_used": "2001", "memory_used_total": "123456", "memory_used_heap": "123",
                     "memory_used_external": "123333"})
        report = observer.observe()
        self.assertTrue(report["cases"][4]["target_limit_observed"])
        self.assertEqual(observer.accounting[0]["values"]["cpu_time_used"], 2001)
        self.assertIn("shutdown memory snapshots", observer.accounting[0]["scope"])
        self.assertNotIn("peak", json.dumps(journal))

    def test_bad_metric_or_identity_cannot_be_relabelled_as_a_result(self):
        for field, bad in (("function_id", F.uid(9, 1)), ("execution_id", ""), ("deployment_id", "wrong"),
                           ("runtime_version", "new-runtime"), ("cpu_time_used", "nan"), ("reason", "invented")):
            observer, api, _, _, evidence, _ = setup(5)
            next(r for r in api.rows if r["event_type"] == "Shutdown")[field] = bad
            with self.assertRaises((O.ObservationError, O.C.InvalidEvidence)):
                observer.observe()
            self.assertFalse(evidence["window"]["complete"])
            self.assertEqual(evidence["rows"], [])

    def test_truncated_or_extra_application_fields_never_persist(self):
        for mutation in ("broken", "extra", "runtime", "attempt"):
            observer, api, _, _, evidence, saved = setup()
            entry = api.rows[0]
            payload = json.loads(entry["event_message"])
            if mutation == "broken":
                entry["event_message"] = '{"probe":"hosted-limits-v1"'
            else:
                if mutation == "extra":
                    payload["private_secret"] = "canary-not-retained"
                elif mutation == "runtime":
                    payload["runtime_version"] = "future-runtime"
                else:
                    payload["attempt_id"] = F.uid(8, 1)
                entry["event_message"] = json.dumps(payload)
            with self.assertRaises((O.ObservationError, O.C.InvalidEvidence)):
                observer.observe()
            self.assertEqual(evidence["rows"], [])
            self.assertNotIn("canary-not-retained", json.dumps(saved))

    def test_full_pages_split_and_boundary_rows_are_deduplicated(self):
        observer, api, clock, journal, evidence, _ = setup(0, 200)
        api.rows = [raw(F.row(F.uid(4, n + 10), n * 3, "Boot")) for n in range(70)]
        report = observer.observe()
        self.assertTrue(report["observation_complete"])
        self.assertEqual(len(evidence["rows"]), 67)
        self.assertEqual(journal["log_queries"][0]["state"], "full")
        self.assertTrue(any(q["state"] == "complete" for q in journal["log_queries"][1:]))
        self.assertTrue(all(0 <= wait <= 7 for wait in clock.waits))

    def test_full_unsplittable_timestamp_stays_inconclusive(self):
        observer, api, _, journal, evidence, _ = setup(0, 0.001)
        api.rows = [raw(F.row(F.uid(4, n + 10), 0, "Boot")) for n in range(50)]
        with self.assertRaisesRegex(O.ObservationError, "unsplittable_log_page"):
            observer.observe()
        self.assertFalse(evidence["window"]["complete"])
        self.assertTrue(evidence["window"]["truncated"])
        self.assertEqual(len(api.calls), 1)

    def test_final_observation_revisits_closed_intervals_for_late_rows(self):
        observer, api, clock, _, evidence, _ = setup(4, 200)
        observer.observe()
        late = raw(F.row(F.uid(4, 50), 2, "Boot"))
        api.rows.append(late)
        clock.sleep(200)
        observer.observe()
        self.assertFalse(any(r["execution_id"] == F.uid(4, 50) for r in evidence["rows"]))
        clock.sleep(10)
        observer.observe(final=True)
        self.assertTrue(any(r["execution_id"] == F.uid(4, 50) for r in evidence["rows"]))
        self.assertEqual(len({json.dumps(r, sort_keys=True) for r in evidence["rows"]}), len(evidence["rows"]))

    def test_query_error_is_not_an_empty_success(self):
        for response in ({"result": None, "error": "private backend error"}, {"result": []}, {"result": [], "error": "boom"}):
            observer, api, _, _, evidence, saved = setup()
            api.error = response
            if response == {"result": []}:
                # Empty result is a complete read, but absence does not prove a stop.
                self.assertEqual(observer.observe()["cases"][3]["status"], "inconclusive")
            else:
                with self.assertRaises(O.ObservationError):
                    observer.observe()
                self.assertFalse(evidence["window"]["complete"])
            self.assertNotIn("private backend error", json.dumps(saved))

    def test_exhausted_query_budget_does_not_send_or_claim_completion(self):
        observer, api, _, journal, evidence, _ = setup()
        journal["log_queries"] = [{"sent_at": F.stamp(0)} for _ in range(24)]
        with self.assertRaisesRegex(O.ObservationError, "log_query_budget"):
            observer.observe()
        self.assertEqual(api.calls, [])
        self.assertFalse(evidence["window"]["complete"])

    def test_foreign_window_and_unknown_fields_fail_closed(self):
        for field, value in (("timestamp", F.stamp(900)), ("new_field", "anything"), ("event_type", "FutureEvent")):
            observer, api, _, _, evidence, _ = setup()
            entry = api.rows[0]
            entry[field] = value
            # Force a faulty transport to return its row even outside SQL range.
            api.error = {"result": [entry], "error": None}
            with self.assertRaises((O.ObservationError, O.C.InvalidEvidence)):
                observer.observe()
            self.assertFalse(evidence["window"]["complete"])

    def test_large_valid_observation_does_not_expand_cleanup_journal(self):
        observer, api, _, journal, evidence, _ = setup(0, 200)
        api.rows = [raw(F.row(F.uid(4, n + 20), n / 2, "Shutdown", "EarlyDrop")) for n in range(350)]
        for row in api.rows:
            row.update({"cpu_time_used": "2001", "memory_used_total": "123456", "memory_used_heap": "123",
                        "memory_used_external": "123333"})
        observer.observe()
        self.assertEqual(len(observer.accounting), 350)
        self.assertEqual(len(evidence["rows"]), 350)
        self.assertLess(len(json.dumps(journal).encode()), 10000)
        self.assertNotIn("shutdown_accounting", journal)


if __name__ == "__main__":
    unittest.main()
