import copy
import datetime as dt
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest

SPEC = importlib.util.spec_from_file_location("hosted_limits_classify", Path(__file__).with_name("classify.py"))
C = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(C)
RUN = "10000000-0000-4000-8000-000000000001"
FUNCTION = "20000000-0000-4000-8000-000000000001"
DEPLOYMENT = f"{C.PROJECT}_{FUNCTION}_1"
SOURCE = "a" * 64
BASE = dt.datetime(2026, 10, 4, tzinfo=dt.timezone.utc)


def stamp(seconds):
    return (BASE + dt.timedelta(seconds=seconds)).isoformat().replace("+00:00", "Z")


def uid(prefix, number):
    return f"{prefix}0000000-0000-4000-8000-{number:012d}"


def example(count=8):
    sent = (1, 2, 3, 4, 6, 10, 20, 425)
    evidence = {
        "identity": {"run_id": RUN, "function_id": FUNCTION, "deployment_id": DEPLOYMENT,
                     "source_sha256": SOURCE, "runtime_version": C.RUNTIME},
        "requests": [{"case": name, "attempt_id": uid(3, n), "sent_at": stamp(sent[n]),
                      "http_status": C.DENIALS.get(name, 202 if name == "background" else 200)}
                     for n, name in enumerate(C.CASES[:count])],
        "window": {"start": stamp(0), "end": stamp(600), "complete": True, "truncated": False},
        "rows": [],
    }
    for name, at, end in (("control", 4.1, 4.2), ("cpu-wasm", 6.1, 8.3),
                          ("memory-wasm", 10.1, 12.0), ("background", 20.1, 420.0),
                          ("recovery", 425.1, 425.4)):
        if name not in C.CASES[:count]:
            continue
        add_event(evidence, name, "start", at)
        if name in C.TARGET:
            add_shutdown(evidence, name, C.TARGET[name], end)
        else:
            add_event(evidence, name, "complete", end, sequence=1,
                      pages=1 if name == "recovery" else None)
    return evidence


def row(execution, at, event_type="Log", reason=None, message=None):
    return {"timestamp": stamp(at), "event_type": event_type, "function_id": FUNCTION,
            "deployment_id": DEPLOYMENT, "execution_id": execution, "reason": reason, "message": message}


def add_event(evidence, name, event, at, *, sequence=0, pages=None, execution=None, isolate=None):
    index = C.CASES.index(name)
    request = next(r for r in evidence["requests"] if r["case"] == name)
    execution = execution or uid(4, index)
    payload = {"probe": "hosted-limits-v1", "event": event, "run_id": RUN,
               "attempt_id": request["attempt_id"], "case": name, "source_sha256": SOURCE,
               "deployment_id": DEPLOYMENT, "execution_id": execution,
               "isolate_id": isolate or uid(5, index), "runtime_version": C.RUNTIME,
               "sequence": sequence, "elapsed_ms": 0 if event == "start" else 100, "pages": pages}
    evidence["rows"].append(row(execution, at, message=json.dumps(payload)))


def add_shutdown(evidence, name, reason, at):
    evidence["rows"].append(row(uid(4, C.CASES.index(name)), at, "Shutdown", reason))


def mutate_event(evidence, name, which_event="start", **changes):
    for record in evidence["rows"]:
        if record["message"]:
            payload = json.loads(record["message"])
            if payload["case"] == name and payload["event"] == which_event:
                payload.update(changes)
                record["message"] = json.dumps(payload)
                return record
    raise AssertionError("fixture event missing")


def remove_shutdown(evidence, name):
    execution = uid(4, C.CASES.index(name))
    evidence["rows"] = [r for r in evidence["rows"]
                        if not (r["execution_id"] == execution and r["event_type"] == "Shutdown")]


def result(evidence, name):
    return next(r for r in C.classify(evidence)["cases"] if r["case"] == name)


class ClassifierTests(unittest.TestCase):
    def rejected(self, evidence, code=None):
        with self.assertRaises(C.InvalidEvidence) as error:
            C.classify(evidence)
        if code:
            self.assertEqual(str(error.exception), code)

    def test_target_stops_and_final_recovery_never_admit(self):
        report = C.classify(example())
        self.assertFalse(report["hosted_admitted"])
        self.assertTrue(report["observation_complete"])
        self.assertEqual([r["status"] for r in report["cases"]],
                         ["denial_confirmed"] * 3 + ["completed"] + ["hard_stop_observed"] * 3 + ["completed"])
        self.assertEqual(sum(r["target_limit_observed"] for r in report["cases"]), 3)
        self.assertNotIn("peak", json.dumps(report))

    def test_client_timeout_without_shutdown_is_inconclusive(self):
        evidence = example(5)
        evidence["requests"][-1]["http_status"] = 504
        remove_shutdown(evidence, "cpu-wasm")
        self.assertEqual(result(evidence, "cpu-wasm")["status"], "inconclusive")

    def test_lost_response_with_exact_shutdown_is_observable_without_retry(self):
        evidence = example(5)
        evidence["requests"][-1]["http_status"] = None
        self.assertTrue(result(evidence, "cpu-wasm")["target_limit_observed"])

    def test_different_shutdown_cause_is_not_target_pass(self):
        evidence = example(6)
        remove_shutdown(evidence, "memory-wasm")
        add_shutdown(evidence, "memory-wasm", "CPUTime", 12)
        actual = result(evidence, "memory-wasm")
        self.assertEqual(actual["status"], "hard_stop_observed")
        self.assertFalse(actual["target_limit_observed"])
        self.assertTrue(actual["isolate_termination_observed"])

    def test_early_drop_and_manual_termination_do_not_establish_limits(self):
        for reason in ("EarlyDrop", "EventLoopCompleted", "TerminationRequested"):
            evidence = example(5)
            remove_shutdown(evidence, "cpu-wasm")
            add_shutdown(evidence, "cpu-wasm", reason, 8.3)
            self.assertEqual(result(evidence, "cpu-wasm")["status"], "other_shutdown_observed")
            self.assertFalse(result(evidence, "cpu-wasm")["target_limit_observed"])

    def test_fallback_before_later_shutdown_does_not_become_host_pass(self):
        evidence = example(5)
        add_event(evidence, "cpu-wasm", "fallback", 8, sequence=1)
        actual = result(evidence, "cpu-wasm")
        self.assertEqual(actual["status"], "fallback_only")
        self.assertFalse(actual["target_limit_observed"])

    def test_allocation_refusal_is_not_memory_termination(self):
        evidence = example(6)
        remove_shutdown(evidence, "memory-wasm")
        add_event(evidence, "memory-wasm", "allocation_refused", 12, sequence=1)
        self.assertEqual(result(evidence, "memory-wasm")["status"], "allocation_refused_only")

    def test_beforeunload_and_heartbeat_are_not_terminal(self):
        evidence = example(7)
        remove_shutdown(evidence, "background")
        add_event(evidence, "background", "heartbeat", 30, sequence=1)
        add_event(evidence, "background", "beforeunload", 350, sequence=2)
        self.assertEqual(result(evidence, "background")["status"], "inconclusive")

    def test_truncated_or_incomplete_logs_cannot_pass(self):
        for field, value in (("truncated", True), ("complete", False)):
            evidence = example()
            evidence["window"][field] = value
            report = C.classify(evidence)
            self.assertFalse(report["observation_complete"])
            self.assertFalse(any(r["target_limit_observed"] for r in report["cases"]))

    def test_no_work_and_prefix_have_explicit_not_requested_cases(self):
        self.assertTrue(all(r["status"] == "not_requested" for r in C.classify(example(0))["cases"]))
        report = C.classify(example(5))
        self.assertEqual([r["status"] for r in report["cases"][-3:]], ["not_requested"] * 3)

    def test_failed_denial_check_cannot_be_followed_by_a_positive_run(self):
        evidence = example(5)
        evidence["requests"][0]["http_status"] = 500
        self.assertFalse(C.classify(evidence)["observation_complete"])
        self.assertFalse(result(evidence, "cpu-wasm")["target_limit_observed"])

    def test_duplicate_or_reordered_requests_and_over_budget_rejected(self):
        for edit, code in ((lambda e: e["requests"].append(copy.deepcopy(e["requests"][-1])), "request_budget"),
                           (lambda e: e["requests"].reverse(), "request_order"),
                           (lambda e: e["requests"][1].update(attempt_id=e["requests"][0]["attempt_id"]), "duplicate_attempt")):
            evidence = example()
            edit(evidence)
            self.rejected(evidence, code)

    def test_duplicate_delivery_to_second_isolate_rejected(self):
        evidence = example(5)
        add_event(evidence, "cpu-wasm", "start", 6.2, execution=uid(4, 99), isolate=uid(5, 99))
        self.rejected(evidence, "ambiguous_start")

    def test_same_rows_from_overlapping_queries_deduplicate(self):
        evidence = example()
        evidence["rows"] += copy.deepcopy(evidence["rows"])
        self.assertTrue(result(evidence, "cpu-wasm")["target_limit_observed"])

    def test_two_nonidentical_shutdown_events_are_ambiguous(self):
        evidence = example(5)
        add_shutdown(evidence, "cpu-wasm", "CPUTime", 8.4)
        self.rejected(evidence, "ambiguous_shutdown")

    def test_wrong_source_runtime_envelope_and_deployment_rejected(self):
        changes = (({"source_sha256": "b" * 64}, "source_mismatch"),
                   ({"runtime_version": "different"}, "runtime_changed"),
                   ({"execution_id": uid(4, 99)}, "identity_mismatch"),
                   ({"deployment_id": DEPLOYMENT[:-1] + "2"}, "identity_mismatch"))
        for change, code in changes:
            evidence = example(5)
            mutate_event(evidence, "cpu-wasm", **change)
            self.rejected(evidence, code)

    def test_missing_shutdown_deployment_can_join_exact_function_execution(self):
        evidence = example(5)
        evidence["rows"][-1]["deployment_id"] = None
        self.assertTrue(result(evidence, "cpu-wasm")["target_limit_observed"])

    def test_foreign_function_or_shutdown_deployment_rejected(self):
        for field, value, code in (("function_id", uid(2, 99), "foreign_function"),
                                   ("deployment_id", DEPLOYMENT[:-1] + "2", "foreign_deployment")):
            evidence = example(5)
            evidence["rows"][-1][field] = value
            self.rejected(evidence, code)

    def test_event_after_shutdown_or_terminal_rejected(self):
        evidence = example(5)
        add_event(evidence, "cpu-wasm", "fallback", 9, sequence=1)
        self.rejected(evidence, "event_after_shutdown")
        evidence = example(5)
        add_event(evidence, "control", "beforeunload", 4.3, sequence=2)
        self.rejected(evidence, "event_after_terminal")

    def test_cross_isolate_overlap_rejected(self):
        evidence = example(6)
        remove_shutdown(evidence, "cpu-wasm")
        self.rejected(evidence, "overlapping_cases")
        evidence = example(6)
        remove_shutdown(evidence, "cpu-wasm")
        add_shutdown(evidence, "cpu-wasm", "CPUTime", 11)
        self.rejected(evidence, "overlapping_cases")

    def test_missing_prior_start_cannot_yield_positive_run(self):
        evidence = example(5)
        evidence["rows"] = [r for r in evidence["rows"] if r["execution_id"] != uid(4, 3)]
        self.assertFalse(C.classify(evidence)["observation_complete"])
        self.assertFalse(result(evidence, "cpu-wasm")["target_limit_observed"])

    def test_delayed_memory_start_allows_reobservation_without_authorizing_work(self):
        evidence = example(6)
        evidence["requests"][-1]["http_status"] = None
        start = mutate_event(evidence, "memory-wasm")
        evidence["rows"].remove(start)
        # A real log query can first deliver Shutdown and beforeunload, then
        # deliver the earlier start on a later GET of the same time window.
        add_event(evidence, "memory-wasm", "beforeunload", 11.99, sequence=1)
        mutate_event(evidence, "memory-wasm", "beforeunload", elapsed_ms=1890)
        before = C.classify(evidence)
        actual = next(r for r in before["cases"] if r["case"] == "memory-wasm")
        self.assertFalse(before["observation_complete"])
        self.assertFalse(before["hosted_admitted"])
        self.assertEqual(actual["status"], "inconclusive")
        self.assertFalse(actual["target_limit_observed"])
        self.assertFalse(actual["isolate_termination_observed"])

        requests = copy.deepcopy(evidence["requests"])
        evidence["rows"].append(start)
        after = C.classify(evidence)
        actual = next(r for r in after["cases"] if r["case"] == "memory-wasm")
        self.assertTrue(after["observation_complete"])
        self.assertEqual(actual["status"], "hard_stop_observed")
        self.assertTrue(actual["target_limit_observed"])
        self.assertTrue(actual["isolate_termination_observed"])
        self.assertFalse(after["hosted_admitted"])
        self.assertEqual(evidence["requests"], requests)

    def test_valid_non_start_events_without_start_remain_inconclusive(self):
        cases = (("control", "complete"), ("cpu-wasm", "fallback"),
                 ("memory-wasm", "allocation_refused"), ("background", "heartbeat"),
                 ("memory-wasm", "beforeunload"), ("cpu-wasm", "failed"),
                 ("recovery", "complete"))
        for name, event in cases:
            with self.subTest(case=name, event=event):
                index = C.CASES.index(name)
                evidence = example(index + 1)
                evidence["rows"] = [r for r in evidence["rows"] if r["execution_id"] != uid(4, index)]
                sent = (C.instant(evidence["requests"][-1]["sent_at"]) - BASE).total_seconds()
                add_event(evidence, name, event, sent + 0.2, sequence=1,
                          pages=1 if name == "recovery" else None)
                if event == "failed":
                    mutate_event(evidence, name, event, elapsed_ms=None)
                report = C.classify(evidence)
                actual = next(r for r in report["cases"] if r["case"] == name)
                self.assertFalse(report["observation_complete"])
                self.assertEqual(actual["status"], "inconclusive")
                self.assertFalse(actual["isolate_termination_observed"])
                self.assertFalse(actual["target_limit_observed"])

    def test_partial_span_keeps_binding_and_sequence_conflicts_fatal(self):
        def partial():
            evidence = example(6)
            evidence["rows"].remove(mutate_event(evidence, "memory-wasm"))
            add_event(evidence, "memory-wasm", "beforeunload", 11, sequence=1)
            return evidence

        evidence = partial()
        add_event(evidence, "memory-wasm", "allocation_refused", 11.1, sequence=2,
                  execution=uid(4, 99), isolate=uid(5, 99))
        self.rejected(evidence, "ambiguous_start")
        evidence = partial()
        add_event(evidence, "memory-wasm", "allocation_refused", 11.1, sequence=1)
        self.rejected(evidence, "event_order")
        evidence = partial()
        add_event(evidence, "memory-wasm", "allocation_refused", 10.9, sequence=2)
        self.rejected(evidence, "event_order")
        evidence = partial()
        add_event(evidence, "memory-wasm", "allocation_refused", 12.1, sequence=2)
        self.rejected(evidence, "event_after_shutdown")
        evidence = partial()
        mutate_event(evidence, "memory-wasm", "beforeunload", elapsed_ms=None)
        self.rejected(evidence)

    def test_missing_start_does_not_mask_known_overlap_or_binding_conflict(self):
        evidence = example(7)
        evidence["rows"].remove(mutate_event(evidence, "memory-wasm"))
        add_event(evidence, "memory-wasm", "beforeunload", 11, sequence=1)
        remove_shutdown(evidence, "memory-wasm")
        add_shutdown(evidence, "memory-wasm", "Memory", 21)
        self.rejected(evidence, "overlapping_cases")

        evidence = example(6)
        evidence["rows"].remove(mutate_event(evidence, "memory-wasm"))
        add_event(evidence, "memory-wasm", "beforeunload", 11, sequence=1,
                  execution=uid(4, 4), isolate=uid(5, 99))
        self.rejected(evidence, "ambiguous_isolate")

    def test_delayed_start_cannot_create_conflicting_execution_or_time_order(self):
        for changes, code in (({"execution_id": uid(4, 99), "isolate_id": uid(5, 99)}, "ambiguous_start"),
                              ({"timestamp": stamp(11.5)}, "event_order")):
            evidence = example(6)
            start = mutate_event(evidence, "memory-wasm")
            evidence["rows"].remove(start)
            add_event(evidence, "memory-wasm", "beforeunload", 11, sequence=1)
            self.assertFalse(C.classify(evidence)["observation_complete"])
            if "timestamp" in changes:
                start.update(changes)
            else:
                payload = json.loads(start["message"])
                payload.update(changes)
                start["message"] = json.dumps(payload)
                start["execution_id"] = payload["execution_id"]
            evidence["rows"].append(start)
            self.rejected(evidence, code)

    def test_warm_serial_worker_shutdown_only_belongs_to_active_case(self):
        evidence = example(5)
        execution, isolate = uid(4, 3), uid(5, 3)
        record = mutate_event(evidence, "cpu-wasm", execution_id=execution, isolate_id=isolate)
        record["execution_id"] = execution
        evidence["rows"][-1]["execution_id"] = execution
        self.assertEqual(result(evidence, "control")["status"], "completed")
        self.assertTrue(result(evidence, "cpu-wasm")["target_limit_observed"])

    def test_unrequested_work_and_work_after_denial_rejected(self):
        evidence = example(5)
        mutate_event(evidence, "cpu-wasm", attempt_id=uid(3, 99))
        self.rejected(evidence, "unrequested_work")
        evidence = example(3)
        add_event(evidence, "deny_missing_auth", "start", 1.1)
        self.rejected(evidence, "work_after_denial")

    def test_recovery_requires_exact_one_page_completion(self):
        for pages in (None, 0, 2, True):
            evidence = example()
            mutate_event(evidence, "recovery", "complete", pages=pages)
            self.rejected(evidence)

    def test_runtime_text_and_credentials_are_discarded(self):
        evidence = example(5)
        secret = "sentinel-secret-do-not-copy"
        evidence["rows"].append(row(uid(4, 4), 7, message=secret))
        evidence["rows"].append(row(uid(4, 4), 7.1, "UncaughtException", message=secret))
        self.assertNotIn(secret, json.dumps(C.classify(evidence)))

    def test_runtime_failure_before_limit_shutdown_makes_workload_inconclusive(self):
        for event_type in ("UncaughtException", "BootFailure"):
            evidence = example(5)
            evidence["rows"].append(row(uid(4, 4), 7, event_type, message="sentinel-secret"))
            actual = result(evidence, "cpu-wasm")
            self.assertEqual(actual["status"], "inconclusive")
            self.assertFalse(actual["target_limit_observed"])
            self.assertTrue(actual["isolate_termination_observed"])
            self.assertEqual(actual["shutdown_reason"], "CPUTime")
            self.assertEqual(actual["runtime_failure_events"], [
                {"event_type": event_type, "execution_id": uid(4, 4), "timestamp": stamp(7)}])
            self.assertNotIn("sentinel-secret", json.dumps(actual))

    def test_runtime_failure_without_shutdown_cannot_prove_isolate_stop(self):
        evidence = example(5)
        remove_shutdown(evidence, "cpu-wasm")
        evidence["rows"].append(row(uid(4, 4), 7, "UncaughtException"))
        actual = result(evidence, "cpu-wasm")
        self.assertEqual(actual["status"], "inconclusive")
        self.assertFalse(actual["target_limit_observed"])
        self.assertFalse(actual["isolate_termination_observed"])
        self.assertEqual(len(actual["runtime_failure_events"]), 1)

    def test_runtime_failure_before_recovery_completion_is_not_success(self):
        evidence = example()
        evidence["rows"].append(row(uid(4, 7), 425.2, "UncaughtException"))
        self.assertEqual(result(evidence, "recovery")["status"], "inconclusive")

    def test_unrelated_execution_failure_does_not_taint_matched_work(self):
        evidence = example(5)
        evidence["rows"].append(row(uid(4, 99), 7, "BootFailure"))
        actual = result(evidence, "cpu-wasm")
        self.assertTrue(actual["target_limit_observed"])
        self.assertEqual(actual["runtime_failure_events"], [])

    def test_failure_after_work_terminal_is_not_attributed_to_earlier_case(self):
        evidence = example(5)
        evidence["rows"].append(row(uid(4, 3), 5, "UncaughtException"))
        self.assertEqual(result(evidence, "control")["status"], "completed")
        self.assertEqual(result(evidence, "control")["runtime_failure_events"], [])

    def test_failure_after_shutdown_is_conflicting_evidence(self):
        evidence = example(5)
        evidence["rows"].append(row(uid(4, 4), 8.4, "UncaughtException"))
        self.rejected(evidence, "event_after_shutdown")

    def test_runtime_failure_deduplication_does_not_depend_on_raw_exception(self):
        evidence = example(5)
        evidence["rows"].append(row(uid(4, 4), 7, "UncaughtException", message="first-secret"))
        evidence["rows"].append(row(uid(4, 4), 7, "UncaughtException", message="second-secret"))
        actual = result(evidence, "cpu-wasm")
        self.assertEqual(len(actual["runtime_failure_events"]), 1)
        self.assertNotIn("secret", json.dumps(actual))

    def test_untrusted_shapes_raise_only_fixed_invalid_evidence(self):
        for field in ("event_type", "reason", "execution_id", "message"):
            evidence = example(5)
            evidence["rows"][-1][field] = {"secret": "not-an-enum"}
            self.rejected(evidence)
        evidence = example(5)
        mutate_event(evidence, "cpu-wasm", event=[])
        self.rejected(evidence)

    def test_row_and_time_bounds(self):
        evidence = example(5)
        evidence["rows"] *= 101
        self.rejected(evidence, "row_budget")
        evidence = example(5)
        evidence["window"]["end"] = stamp(1801)
        self.rejected(evidence, "invalid_window")
        evidence = example(5)
        evidence["rows"][-1]["timestamp"] = stamp(601)
        self.rejected(evidence, "row_outside_window")

    def test_duplicate_json_key_and_nonfinite_number_rejected(self):
        for raw in ('{"a":1,"a":2}', '{"a":NaN}', '{"a":Infinity}'):
            with self.assertRaises(C.InvalidEvidence):
                C.loads(raw)

    def test_cli_size_limit_invalid_json_and_safe_output(self):
        script = str(Path(__file__).with_name("classify.py"))
        for raw in (b'x' * (C.MAX_INPUT_BYTES + 1), b'{"private":"sentinel-secret"', b'\xff'):
            run = subprocess.run([sys.executable, script], input=raw, capture_output=True, timeout=3)
            self.assertEqual(run.returncode, 2)
            self.assertEqual(run.stderr, b'')
            self.assertNotIn(b'sentinel-secret', run.stdout)
            self.assertFalse(json.loads(run.stdout)["hosted_admitted"])

    def test_damaged_structured_terminal_cannot_disappear_into_a_pass(self):
        for message in ('{"probe":"hosted-limits-v1","event":"fallback"',
                        '{"probe":"hosted-limits-v1","event":"fallback","event":"start"}'):
            evidence = example(5)
            evidence["rows"].append(row(uid(4, 4), 8, message=message))
            self.rejected(evidence, "malformed_application_log")

    def test_caught_failed_event_cannot_become_a_later_limit_pass(self):
        evidence = example(5)
        add_event(evidence, "cpu-wasm", "failed", 8, sequence=1)
        mutate_event(evidence, "cpu-wasm", "failed", elapsed_ms=None)
        actual = result(evidence, "cpu-wasm")
        self.assertEqual(actual['status'], 'inconclusive')
        self.assertFalse(actual['target_limit_observed'])
        add_event(evidence, "cpu-wasm", "beforeunload", 8.1, sequence=2)
        self.rejected(evidence, "event_after_terminal")

    def test_only_failed_event_may_have_unknown_elapsed_time(self):
        evidence = example(5)
        add_event(evidence, "cpu-wasm", "fallback", 8, sequence=1)
        mutate_event(evidence, "cpu-wasm", "fallback", elapsed_ms=None)
        self.rejected(evidence)


if __name__ == "__main__":
    unittest.main()
