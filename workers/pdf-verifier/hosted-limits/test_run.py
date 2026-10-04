"""No-network operator schedules, using real observer/classifier and fake time."""
import copy
import datetime as dt
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import uuid

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("tested_limits_operator", HERE / "run.py")
R = importlib.util.module_from_spec(spec)
spec.loader.exec_module(R)
T = R.module("limits_observer_test_helpers", HERE / "test_observe.py")
FUNCTION = T.F.FUNCTION


class FakeAPI:
    management, anon = "fake-management-secret", "fake-anon-secret"

    def __init__(self, clock):
        self.clock, self.logs = clock, T.LogAPI([])
        self.counts = {"control": 0, "cleanup": 0, "logs": 0}
        self.cleaning, self.persist = False, lambda: None
        self.user, self.current_function, self.account = None, None, False
        self.transport, self.work = self, None
        self.posts, self.calls = [], []
        self.lost_case, self.unfinished_case = None, None
        self.lose_auth_create = False
        self.deploy_delay = 0
        self.replace_before_case = None
        self.cleanup_marker_mismatch = None
        self.evidence_attempted_before_post = []
        self.delayed_start_case = None
        self.hide_start_forever = False
        self.delayed_start_queries = []

    def count(self, log=False):
        R.API.count(self, log)

    def function(self, slug):
        self.count()
        self.calls.append(("function", slug))
        if self.replace_before_case is not None and len(self.posts) == self.replace_before_case:
            self.current_function["version"] = 2
        return copy.deepcopy(self.current_function)

    def management_request(self, suffix="", method="GET", body=None, expected=(200,), limit=65536):
        self.count(suffix.startswith("/analytics/endpoints/logs?"))
        self.calls.append(("management", method, suffix))
        if not suffix:
            return 200, {"id": R.PROJECT, "organization_id": R.ORGANIZATION, "name": "science-reader-staging"}, {}
        if suffix.startswith("/analytics/endpoints/logs?"):
            pending = self.delayed_start_case
            if pending and any(body["case"] == pending for body in self.posts):
                self.delayed_start_queries.append(len(self.posts))
                if self.hide_start_forever or len(self.delayed_start_queries) == 1:
                    original = self.logs.rows
                    def visible(row):
                        message = row.get("event_message", "")
                        if not message.startswith("{"):
                            return True
                        event = json.loads(message)
                        return not (event.get("case") == pending and event.get("event") == "start")
                    self.logs.rows = [row for row in original if visible(row)]
                    try:
                        return self.logs.management_request(suffix, limit)
                    finally:
                        self.logs.rows = original
            return self.logs.management_request(suffix, limit)
        if suffix.startswith("/functions/") and method == "DELETE":
            self.current_function = None
            return 200, None, {}
        raise AssertionError("Unexpected fake management request")

    def query(self, sql, read_only=False):
        self.count()
        self.calls.append(("query", read_only))
        if read_only:
            return [{"present": self.account}]
        assert "probe_account_not_pristine" in sql and self.user is not None
        self.account = False
        return []

    def auth(self, path, method="GET", body=None, admin=False, token=None, expected=(200,)):
        self.count()
        self.calls.append(("auth", method, path))
        if path == "/admin/users" and method == "POST":
            self.user = {key: copy.deepcopy(body[key]) for key in ("id", "email", "app_metadata")}
            self.account = True
            if self.lose_auth_create:
                raise R.B.ProbeError("transport_uncertain")
            return 201, copy.deepcopy(self.user), {}
        if path == "/token?grant_type=password":
            return 200, {"user": copy.deepcopy(self.user), "access_token": "fake.session.secret.token"}, {}
        if path == "/user":
            return 200, copy.deepcopy(self.user), {}
        if path.startswith("/admin/users/"):
            if method == "DELETE":
                assert not self.account
                self.user = None
                return 204, None, {}
            status = 200 if self.user else 404
            if self.cleaning and self.user is not None and self.cleanup_marker_mismatch:
                self.user["app_metadata"][self.cleanup_marker_mismatch] = "changed-identity"
            assert status in expected
            return status, copy.deepcopy(self.user), {}
        raise AssertionError("Unexpected fake Auth request")

    def deploy(self, work, slug, management):
        self.work = work
        journal = json.loads((work / "cleanup-journal.json").read_text())
        assert journal["deploy_attempted"] and not journal["auth_attempted"]
        self.clock.sleep(self.deploy_delay)
        self.current_function = {"id": FUNCTION, "name": slug, "slug": slug, "version": 1,
            "status": "ACTIVE", "created_at": int(self.clock.now().timestamp() * 1000),
            "updated_at": int(self.clock.now().timestamp() * 1000), "ezbr_sha256": "b" * 64, "verify_jwt": False}

    def request(self, host, path, method, body, headers, expected, limit, timeout):
        assert host == R.HOST and method == "POST" and path.endswith(self.current_function["slug"])
        disk = json.loads((self.work / "evidence.json").read_text())
        assert disk["requests"][-1]["attempt_id"] == body["attempt_id"] and disk["requests"][-1]["http_status"] is None
        self.evidence_attempted_before_post.append(True)
        self.posts.append(copy.deepcopy(body))
        if "Authorization" not in headers:
            return 401, {"error": "unauthorized"}, {}
        if body["run_id"] != self.user["app_metadata"]["check_run_id"]:
            return 403, {"error": "forbidden"}, {}
        if body["case"] == "invalid-case":
            return 400, {"error": "invalid_request"}, {}
        name = body["case"]
        started = self.clock.now() + dt.timedelta(milliseconds=10)
        execution, isolate = str(uuid.uuid4()), str(uuid.uuid4())
        identity = disk["identity"]
        payload = {"probe": R.PROBE_KIND, "event": "start", "run_id": body["run_id"],
                   "attempt_id": body["attempt_id"], "case": name, "source_sha256": identity["source_sha256"],
                   "deployment_id": identity["deployment_id"], "execution_id": execution, "isolate_id": isolate,
                   "runtime_version": R.C.RUNTIME, "sequence": 0, "elapsed_ms": 0, "pages": None}

        def event(at, kind, message=None, reason=None):
            self.logs.rows.append(T.raw({"timestamp": R.O.stamp(at), "event_type": kind, "function_id": FUNCTION,
                "deployment_id": identity["deployment_id"], "execution_id": execution, "reason": reason,
                "message": json.dumps(message) if message else None}))

        event(started, "Log", payload)
        if name == self.delayed_start_case:
            event(started + dt.timedelta(milliseconds=500), "Log", {**payload, "event": "beforeunload",
                "sequence": 1, "elapsed_ms": 500})
        if name != self.unfinished_case:
            if name in R.C.TARGET:
                seconds = 400 if name == "background" else 2
                event(started + dt.timedelta(seconds=seconds), "Shutdown", reason=R.C.TARGET[name])
            else:
                event(started + dt.timedelta(milliseconds=100), "Log", {**payload, "event": "complete",
                    "sequence": 1, "elapsed_ms": 100, "pages": 1 if name == "recovery" else None})
        if name == self.lost_case:
            raise R.B.ProbeError("transport_uncertain")
        return 202 if name == "background" else 200, {"arbitrary_body": "not trusted or retained"}, {"x-deno-execution-id": execution}


def builder(run_id, user_id, created, attempts):
    package = R.module("limits_operator_test_package", HERE / "package.py")
    with patch.object(package, "ROOT", R.ROOT):
        return package.build(run_id, user_id, created, attempts,
                             output_root=R.ROOT / ".artifacts/pdf-verifier/hosted-limits")


class OperatorTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = patch.object(R, "ROOT", Path(temporary.name))
        root.start()
        self.addCleanup(root.stop)
        self.run_id, self.user_id = str(uuid.uuid4()), str(uuid.uuid4())
        self.clock = T.Clock(0)
        self.api = FakeAPI(self.clock)
        self.work = R.ROOT / ".artifacts/pdf-verifier/hosted-limits" / self.run_id

    def run_it(self):
        with patch("builtins.print"):
            return R.run_probe(self.api, self.run_id, self.user_id, builder=builder, deploy=self.api.deploy,
                               now=self.clock.now, sleep=self.clock.sleep)

    def report(self):
        return json.loads((self.work / "report.json").read_text())

    def assert_cleaned(self):
        self.assertIsNone(self.api.current_function)
        self.assertIsNone(self.api.user)
        self.assertFalse(self.api.account)
        self.assertTrue(json.loads((self.work / "cleanup-journal.json").read_text())["cleanup_complete"])

    def test_exact_eight_serial_cases_and_complete_cleanup(self):
        self.run_it()
        self.assertEqual(len(self.api.posts), 8)
        self.assertEqual(len({body["attempt_id"] for body in self.api.posts}), 8)
        self.assertTrue(all(self.api.evidence_attempted_before_post))
        self.assertLessEqual(self.api.counts["logs"], 24)
        self.assertLessEqual(self.api.counts["control"], 64)
        self.assertTrue(all(wait <= 30 for wait in self.clock.waits))
        self.assert_cleaned()
        report = self.report()
        self.assertIsNone(report["failure"])
        self.assertTrue(report["classification"]["observation_complete"])
        self.assertFalse(report["hosted_admitted"])
        self.assertEqual(sum(row["target_limit_observed"] for row in report["classification"]["cases"]), 3)
        for path in self.work.rglob("*.json"):
            for secret in ("fake-management-secret", "fake-anon-secret", "fake.session.secret.token", "arbitrary_body"):
                self.assertNotIn(secret, path.read_text())

    def test_lost_response_observes_same_attempt_without_repeating_post(self):
        self.api.lost_case = "cpu-wasm"
        self.run_it()
        self.assertEqual(sum(body["case"] == "cpu-wasm" for body in self.api.posts), 1)
        self.assertIsNone(json.loads((self.work / "evidence.json").read_text())["requests"][4]["http_status"])
        self.assertTrue(self.report()["classification"]["cases"][4]["target_limit_observed"])
        self.assert_cleaned()

    def test_delayed_start_polls_same_attempt_before_any_successor(self):
        self.api.delayed_start_case = "memory-wasm"
        self.run_it()
        self.assertEqual(self.api.delayed_start_queries[:2], [6, 6])
        self.assertEqual(len(self.api.posts), 8)
        self.assertEqual(len({body["attempt_id"] for body in self.api.posts}), 8)
        self.assertTrue(self.report()["classification"]["cases"][5]["target_limit_observed"])
        self.assertIsNone(self.report()["failure"])
        self.assert_cleaned()

    def test_permanently_missing_start_exhausts_polling_without_successor(self):
        self.api.delayed_start_case = "memory-wasm"
        self.api.hide_start_forever = True
        with self.assertRaisesRegex(R.B.ProbeError, "execution_stop_unconfirmed"):
            self.run_it()
        self.assertEqual(len(self.api.posts), 6)
        self.assertTrue(all(count == 6 for count in self.api.delayed_start_queries))
        self.assertEqual(self.report()["classification"]["cases"][5]["status"], "inconclusive")
        self.assertFalse(self.report()["classification"]["cases"][5]["isolate_termination_observed"])
        self.assert_cleaned()

    def test_missing_stop_prevents_following_requests_and_keeps_uncertainty(self):
        self.api.unfinished_case = "cpu-wasm"
        with self.assertRaisesRegex(R.B.ProbeError, "execution_stop_unconfirmed"):
            self.run_it()
        self.assertEqual(len(self.api.posts), 5)
        self.assert_cleaned()
        report = self.report()
        self.assertEqual(report["failure"], "execution_stop_unconfirmed")
        self.assertEqual(report["classification"]["cases"][4]["status"], "inconclusive")
        self.assertFalse(report["classification"]["cases"][4]["isolate_termination_observed"])
        self.assertEqual(report["classification"]["cases"][5]["status"], "not_requested")

    def test_auth_create_response_loss_never_retries_create(self):
        self.api.lose_auth_create = True
        with self.assertRaisesRegex(R.B.ProbeError, "transport_uncertain"):
            self.run_it()
        self.assertEqual(sum(call == ("auth", "POST", "/admin/users") for call in self.api.calls), 1)
        self.assertEqual(self.api.posts, [])
        self.assert_cleaned()

    def test_background_requires_full_remaining_start_window(self):
        self.api.deploy_delay = 650
        with self.assertRaisesRegex(R.B.ProbeError, "case_start_window_closed"):
            self.run_it()
        self.assertFalse(any(body["case"] == "background" for body in self.api.posts))
        self.assert_cleaned()

    def test_changed_function_is_not_called_or_deleted_but_auth_is_cleaned(self):
        self.api.replace_before_case = 4
        with self.assertRaisesRegex(R.B.ProbeError, "cleanup_required"):
            self.run_it()
        self.assertEqual(len(self.api.posts), 4)
        self.assertIsNotNone(self.api.current_function)
        self.assertIsNone(self.api.user)
        self.assertFalse(self.api.account)

    def test_optional_evidence_failure_cannot_block_owned_resource_cleanup(self):
        original = R.save_json
        calls = 0

        def broken_evidence(path, value):
            nonlocal calls
            if path.name == "evidence.json":
                calls += 1
                raise OSError("synthetic evidence volume failure")
            return original(path, value)

        with patch.object(R, "save_json", broken_evidence):
            with self.assertRaisesRegex(R.B.ProbeError, "operator_failed"):
                self.run_it()
        self.assertGreater(calls, 0)
        self.assert_cleaned()

    def test_query_failure_never_promotes_old_complete_snapshot(self):
        self.api.logs.error = {"result": None, "error": "private provider text"}
        with self.assertRaisesRegex(R.B.ProbeError, "invalid_log_response"):
            self.run_it()
        self.assert_cleaned()
        self.assertFalse(self.report()["classification"]["observation_complete"])
        self.assertNotIn("private provider text", (self.work / "report.json").read_text())

    def test_extended_auth_marker_mismatch_prevents_account_and_auth_deletion(self):
        self.api.cleanup_marker_mismatch = "probe_kind"
        with self.assertRaisesRegex(R.B.ProbeError, "cleanup_required"):
            self.run_it()
        self.assertIsNone(self.api.current_function)
        self.assertIsNotNone(self.api.user)
        self.assertTrue(self.api.account)
        self.assertFalse(any(call[:2] == ("query", False) for call in self.api.calls))
        self.assertFalse(any(call[:2] == ("auth", "DELETE") for call in self.api.calls))

    def test_extended_markers_are_rechecked_inside_locked_sql(self):
        journal = {"user_id": self.user_id, "run_id": self.run_id, "source_manifest_sha256": "a" * 64}
        deployment = R.PROJECT + "_" + FUNCTION + "_1"
        sql = R.B.cleanup_account_sql(journal, {"probe_kind": R.PROBE_KIND, "deployment_id": deployment})
        self.assertIn("raw_app_meta_data->>'probe_kind'='hosted-limits-v1'", sql)
        self.assertIn("raw_app_meta_data->>'deployment_id'='" + deployment + "'", sql)
        self.assertLess(sql.index("for update"), sql.index("raw_app_meta_data->>'deployment_id'"))
        with self.assertRaises(R.B.ProbeError):
            R.B.cleanup_account_sql(journal, {"probe_kind": "'; delete from auth.users; --"})

    def test_rerun_cannot_replay_existing_request_manifest(self):
        self.run_it()
        before = len(self.api.posts)
        with self.assertRaisesRegex(ValueError, "package_exists"):
            self.run_it()
        self.assertEqual(len(self.api.posts), before)


if __name__ == "__main__":
    unittest.main()
