#!/usr/bin/env python3
"""Operate one closed staging lifetime experiment, never admit a production host.

No automatic mutation/POST retries. Run directories and request manifests are
exclusive; a restarted operator can only clean up, not replay the experiment.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import secrets
import sys
import time
import uuid


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    sys.modules[name] = result
    spec.loader.exec_module(result)
    return result


HERE = Path(__file__).resolve().parent
B = module("limits_base_operator", HERE.parent / "hosted/run.py")
O = module("limits_observer", HERE / "observe.py")
C = O.C
ROOT, PROJECT, ORGANIZATION, HOST = B.ROOT, B.PROJECT, B.ORGANIZATION, B.HOST
PROBE_KIND = "hosted-limits-v1"
require, identifier, digest, save_json = B.require, B.identifier, B.digest, B.save_json
MAX_CONTROL_CALLS, MAX_CLEANUP_CALLS = 64, 24
MAX_JOURNAL_BYTES = 32768


def utcnow():
    return dt.datetime.now(dt.timezone.utc)


class API(B.API):
    """Bound normal control reads/mutations independently of cleanup authority."""
    def __init__(self, *args):
        super().__init__(*args)
        self.counts = {"control": 0, "cleanup": 0, "logs": 0}
        self.cleaning = False
        self.persist = lambda: None

    def count(self, log=False):
        category = "logs" if log else "cleanup" if self.cleaning else "control"
        cap = {"control": MAX_CONTROL_CALLS, "cleanup": MAX_CLEANUP_CALLS, "logs": O.MAX_QUERIES}[category]
        require(self.counts[category] < cap, category + "_request_budget")
        self.counts[category] += 1
        self.persist()

    def management_request(self, suffix="", method="GET", body=None, expected=(200,), limit=65536):
        self.count(suffix.startswith("/analytics/endpoints/logs?"))
        return super().management_request(suffix, method, body, expected, limit)

    def auth(self, path, method="GET", body=None, admin=False, token=None, expected=(200,)):
        self.count()
        return super().auth(path, method, body, admin, token, expected)


def checked_package(built, run_id, user_id):
    work = ROOT / ".artifacts/pdf-verifier/hosted-limits" / run_id
    require(built.get("directory") == str(work.relative_to(ROOT))
            and built.get("function") == B.MARKER + "-" + run_id[:8], "package_identity_mismatch")
    raw = (work / "source-manifest.json").read_bytes()
    require(len(raw) <= 65536 and hashlib.sha256(raw).hexdigest() == digest(built.get("source_manifest_sha256")),
            "package_manifest_mismatch")
    manifest = C.loads(raw.decode("utf-8"))
    config = manifest.get("config", {})
    require(config == built.get("config") and config.get("project") == PROJECT
            and config.get("runID") == run_id and config.get("userID") == user_id
            and config.get("buildSHA256") == B.package.BUILD_SHA256 and config.get("path") == "/" + built["function"]
            and type(config.get("createdAt")) is int and type(config.get("expiresAt")) is int
            and config["expiresAt"] - config["createdAt"] == 1200000, "package_config_mismatch")
    require(manifest.get("format") == 1 and manifest.get("build_sha256") == B.package.BUILD_SHA256
            and manifest.get("fixture_manifest_sha256") == B.package.FIXTURE_MANIFEST_SHA256, "package_build_mismatch")
    requests = built.get("requests")
    require(type(requests) is list and len(requests) == 8, "package_requests_mismatch")
    attempts = set()
    for index, request in enumerate(requests):
        require(type(request) is dict and set(request) == {"case", "attempt_id"}
                and request["case"] == C.CASES[index], "package_requests_mismatch")
        attempt = identifier(request["attempt_id"])
        require(attempt not in attempts and attempt not in (run_id, user_id), "package_requests_mismatch")
        attempts.add(attempt)
    require(manifest.get("requests") == requests, "package_requests_mismatch")
    require(config.get("requests") == [{"case": r["case"], "attemptID": r["attempt_id"]} for r in requests],
            "package_requests_mismatch")
    files = manifest.get("source_files")
    require(type(files) is dict and set(files) == {"index.ts", "handler.ts", "workloads.ts", "auth.ts",
                "runtime.ts", "wasm.ts", "verifier.mjs", "assets.ts"}, "package_files_mismatch")
    function = work / "supabase/functions" / built["function"]
    actual = set()
    total = 0
    for path in function.rglob("*"):
        require(not path.is_symlink(), "unsafe_package_path")
        if not path.is_file():
            continue
        name = path.relative_to(function).as_posix()
        require(name in files and re.fullmatch(r"[a-zA-Z0-9_/-]+\.(?:ts|mjs|wasm|json)", name), "package_files_mismatch")
        content = path.read_bytes()
        total += len(content)
        require(total <= 3000000 and hashlib.sha256(content).hexdigest() == digest(files[name]), "package_source_mismatch")
        actual.add(name)
    require(actual == set(files) and total == manifest.get("source_bytes") == built.get("source_bytes"), "package_size_mismatch")
    cli_path = work / "supabase/config.toml"
    expected_config = ('project_id = "science-reader-limits"\n\n[functions.' + built["function"] + ']\nverify_jwt = false\n').encode()
    require(not cli_path.is_symlink() and cli_path.read_bytes() == expected_config
            and hashlib.sha256(expected_config).hexdigest() == manifest.get("supabase_config_sha256"), "package_cli_config_mismatch")
    preserved = manifest.get("captured_files")
    producers = {"package.py", "wasm_recipe.py", "handler.ts", "workloads.ts", "auth.ts", "index.ts.in"}
    require(type(preserved) is dict and set(preserved) == producers | {
        "synthetic.wasm", "verifier-identity.json", "fixture-manifest.json", "recovery.pdf"}, "package_capture_mismatch")
    require(manifest.get("producer_files") == {name: preserved[name] for name in producers}, "package_capture_mismatch")
    for name, expected in preserved.items():
        path = work / "captured" / name
        require(not path.is_symlink() and path.stat().st_size <= 262144, "unsafe_package_capture")
        require(hashlib.sha256(path.read_bytes()).hexdigest() == digest(expected), "package_capture_mismatch")
    require(preserved["verifier-identity.json"] == B.package.BUILD_SHA256
            and preserved["fixture-manifest.json"] == B.package.FIXTURE_MANIFEST_SHA256
            and preserved["synthetic.wasm"] == manifest.get("synthetic_sha256")
            and preserved["recovery.pdf"] == manifest.get("recovery_fixture_sha256"), "package_capture_mismatch")
    # The independent packager binds its selected qpdf/WASM and fixed-workload
    # sources. This operator verifies every emitted byte before remote mutation.
    return work, manifest


def user_matches(user, journal):
    B.user_matches(user, journal)
    metadata = user["app_metadata"]
    require(metadata.get("probe_kind") == PROBE_KIND
            and metadata.get("deployment_id") == journal["deployment_id"], "synthetic_user_marker_mismatch")


def remote_identity(api, journal):
    _, project, _ = api.management_request()
    require(type(project) is dict and project.get("id") == PROJECT
            and project.get("organization_id") == ORGANIZATION
            and project.get("name") == "science-reader-staging", "remote_project_mismatch")
    require(B.function_identity(api.function(journal["function_slug"]), journal) == journal["function_identity"],
            "function_identity_changed")


def case_body(run_id, request):
    name = request["case"]
    return {"run_id": str(uuid.UUID(int=0)) if name == "deny_wrong_run" else run_id,
            "attempt_id": request["attempt_id"], "case": "invalid-case" if name == "deny_invalid_case" else name}


def safe_to_continue(report, name):
    result = next(row for row in report["cases"] if row["case"] == name)
    if name in C.DENIALS:
        return result["status"] == "denial_confirmed"
    if name in ("control", "recovery"):
        return result["status"] == "completed"
    return result["isolate_termination_observed"] or result["status"] in {"fallback_only", "allocation_refused_only"}


def invoke_cases(api, journal, evidence, requests, token, persist, *, observations=None, observer=None,
                 now=utcnow, sleep=time.sleep, progress=print):
    require(not evidence["requests"], "execution_resume_forbidden")
    observations = observations if observations is not None else {"shutdown_accounting": [], "classification": None}
    observer = observer or O.Observer(api, journal, evidence, persist, now, sleep, observations["shutdown_accounting"])
    for planned in requests:
        name = planned["case"]
        required = 600000 if name == "background" else 180000
        require(journal["expires_at"] - int(now().timestamp() * 1000) >= required, "case_start_window_closed")
        remote_identity(api, journal)
        # Identity requests may consume time. Check again immediately before the
        # one POST; a deployment/clock delay cannot extend this package.
        require(journal["expires_at"] - int(now().timestamp() * 1000) >= required, "case_start_window_closed")
        request = {**planned, "sent_at": O.stamp(now()), "http_status": None}
        evidence["requests"].append(request)
        evidence["window"].update({"end": request["sent_at"], "complete": False})
        journal["phase"] = "executing"
        journal["active_case"] = name
        persist()
        headers = {"apikey": api.anon, "x-probe-source-sha256": journal["source_manifest_sha256"]}
        if name != "deny_missing_auth":
            headers["Authorization"] = "Bearer " + token
        progress("Lifetime experiment: " + name + " requested once.", flush=True)
        try:
            status, _, response_ids = api.transport.request(HOST, "/functions/v1/" + journal["function_slug"],
                "POST", case_body(journal["run_id"], planned), headers,
                expected=(200, 202, 400, 401, 403, 404, 409, 410, 429, 500, 502, 503, 504, 546), limit=8192, timeout=60)
            request["http_status"] = status
            journal["responses"].append({"attempt_id": request["attempt_id"], "http_status": status,
                                         "response_ids": response_ids})
        except B.ProbeError:
            # A host kill may prevent a JSON response. Retain uncertainty and
            # observe this same attempt; never dispatch another POST for it.
            journal["responses"].append({"attempt_id": request["attempt_id"], "http_status": None,
                                         "response_ids": {}})
        persist()
        if name in C.DENIALS:
            require(request["http_status"] == C.DENIALS[name], "unexpected_denial_status")
            continue  # The control log snapshot also checks for work after denials.
        delays = (60,) * 8 if name == "background" else (10, 20, 30)
        confirmed = False
        for delay in delays:
            require(len(journal["log_queries"]) < O.MAX_QUERIES - 4, "observation_budget_reserved_for_final")
            # Short waits keep the operator observable; the agent can inspect
            # progress while this independent bounded subprocess is running.
            remaining = delay
            while remaining:
                interval = min(30, remaining)
                sleep(interval)
                remaining -= interval
            report = observer.observe()
            observations["classification"] = report
            persist()
            if safe_to_continue(report, name):
                confirmed = True
                result = next(row for row in report["cases"] if row["case"] == name)
                progress("Lifetime experiment: " + name + " — " + result["status"] + ".", flush=True)
                break
        require(confirmed, "execution_stop_unconfirmed")
    journal["active_case"] = None
    journal["phase"] = "observing_final"
    persist()
    sleep(10)
    observations["classification"] = observer.observe(final=True)
    persist()
    return observer


def validate_journal(value, run_id):
    B.validate_journal(value, run_id)
    require(value.get("probe_kind") == PROBE_KIND and type(value.get("log_queries")) is list
            and len(value["log_queries"]) <= O.MAX_QUERIES, "invalid_limits_journal")
    if value.get("function_identity") is not None:
        require(value.get("deployment_id") == PROJECT + "_" + value["function_identity"]["id"] + "_1",
                "invalid_limits_journal")
    counts = value.get("api_counts")
    require(type(counts) is dict and set(counts) == {"control", "cleanup", "logs"}
            and all(type(counts[key]) is int and 0 <= counts[key] <= maximum
                    for key, maximum in (("control", MAX_CONTROL_CALLS), ("cleanup", MAX_CLEANUP_CALLS), ("logs", O.MAX_QUERIES))),
            "invalid_limits_journal")
    return value


def cleanup(api, journal, path):
    api.cleaning = True
    # Reuse exact-id/version/hash function deletion and the tested guarded SQL
    # which refuses to delete any nonpristine synthetic account.
    return B.cleanup(api, journal, path, verify_user=user_matches,
        account_sql=lambda value: B.cleanup_account_sql(value, {
            "probe_kind": PROBE_KIND, "deployment_id": value["deployment_id"],
        }))


def run_probe(api, run_id, user_id, *, builder=None, deploy=B.deploy_cli, now=utcnow, sleep=time.sleep):
    identifier(run_id)
    identifier(user_id)
    require(run_id != user_id, "distinct_probe_identities_required")
    if builder is None:
        builder = module("limits_packager", HERE / "package.py").build
    created = int(now().timestamp() * 1000)
    attempts = [str(uuid.uuid4()) for _ in C.CASES]
    built = builder(run_id, user_id, created, attempts)
    work, manifest = checked_package(built, run_id, user_id)
    path, evidence_path = work / "cleanup-journal.json", work / "evidence.json"
    require(not path.exists() and not evidence_path.exists(), "execution_resume_forbidden")
    journal = {"format": 1, "project": PROJECT, "organization": ORGANIZATION, "probe_kind": PROBE_KIND,
               "run_id": run_id, "user_id": user_id, "function_slug": built["function"],
               "source_manifest_sha256": built["source_manifest_sha256"], "created_at": created,
               "expires_at": created + 1200000, "function_identity": None, "deployment_id": None,
               "auth_attempted": False, "auth_confirmed": False, "deploy_attempted": False, "deploy_confirmed": False,
               "auth_absent": False, "function_absent": False, "cleanup_complete": False, "phase": "prepared",
               "log_queries": [], "responses": [], "active_case": None,
               "api_counts": api.counts}
    # Preflight absence before creating an ownership journal or any resource.
    require(api.function(journal["function_slug"]) is None, "function_already_exists")
    api.auth("/admin/users/" + user_id, admin=True, expected=(404,))
    require(api.query(B.account_absence_sql(user_id), read_only=True) == [{"present": False}], "account_already_exists")
    evidence = None
    observations = {"shutdown_accounting": [], "classification": None}

    def persist_journal():
        require(len(B.json_bytes(journal)) <= MAX_JOURNAL_BYTES, "cleanup_journal_limit")
        save_json(path, journal)

    def persist():
        persist_journal()
        if evidence is not None:
            save_json(evidence_path, evidence)
            save_json(work / "observations.json", observations)

    api.persist = persist_journal
    persist()
    failure = None
    observer = None
    try:
        checked_package(built, run_id, user_id)
        require(api.function(journal["function_slug"]) is None, "function_already_exists")
        journal.update({"deploy_attempted": True, "phase": "deploying"})
        persist()
        deploy(work, journal["function_slug"], api.management)
        journal["deploy_confirmed"] = True
        persist()
        journal["function_identity"] = B.function_identity(api.function(journal["function_slug"]), journal)
        journal["deployment_id"] = PROJECT + "_" + journal["function_identity"]["id"] + "_1"
        journal["phase"] = "deployed"
        persist()
        identity = {"run_id": run_id, "function_id": journal["function_identity"]["id"],
                    "deployment_id": journal["deployment_id"], "source_sha256": journal["source_manifest_sha256"],
                    "runtime_version": C.RUNTIME}
        evidence = {"identity": identity, "requests": [], "rows": [],
                    "window": {"start": O.stamp(dt.datetime.fromtimestamp(created / 1000, dt.timezone.utc) - dt.timedelta(seconds=5)),
                               "end": O.stamp(now()), "complete": False, "truncated": False}}
        persist()  # Optional evidence storage must work before declaring Auth intent.
        password = secrets.token_urlsafe(48)
        email = "pdf-probe-" + run_id + "@science-reader.invalid"
        journal.update({"auth_attempted": True, "phase": "auth_creating"})
        persist_journal()
        _, user, _ = api.auth("/admin/users", "POST", {"id": user_id, "email": email, "password": password,
            "email_confirm": True, "app_metadata": {"science_reader_check": B.MARKER, "probe_kind": PROBE_KIND,
                "check_run_id": run_id, "source_manifest_sha256": built["source_manifest_sha256"],
                "deployment_id": journal["deployment_id"]}}, admin=True, expected=(200, 201))
        user_matches(user, journal)
        journal.update({"auth_confirmed": True, "phase": "auth_created"})
        persist()
        _, session, _ = api.auth("/token?grant_type=password", "POST", {"email": email, "password": password})
        password = None
        require(type(session) is dict, "invalid_auth_session")
        user_matches(session.get("user"), journal)
        token = session.get("access_token")
        require(isinstance(token, str) and re.fullmatch("[A-Za-z0-9_.-]{20,4096}", token), "invalid_auth_session")
        session = None
        _, current_user, _ = api.auth("/user", token=token)
        user_matches(current_user, journal)
        observer = O.Observer(api, journal, evidence, persist, now, sleep, observations["shutdown_accounting"])
        invoke_cases(api, journal, evidence, built["requests"], token, persist,
                     observations=observations, observer=observer, now=now, sleep=sleep)
        token = None
    except (B.ProbeError, O.ObservationError, C.InvalidEvidence) as error:
        failure = str(error)
    except Exception:
        failure = "operator_failed"
    finally:
        if evidence is not None and failure is not None:
            evidence["window"].update({"end": O.stamp(now()), "complete": False})
        # Optional evidence/report writes must never block resource cleanup.
        # Cleanup checkpoints only its independently durable ownership journal.
        api.persist = persist_journal
        failures = cleanup(api, journal, path)
        if observer is not None and failure in {"execution_stop_unconfirmed", "observation_budget_reserved_for_final"}:
            # Ingress is now revoked. One bounded final observation may find a
            # delayed stop; this never resumes the request sequence or treats
            # function deletion as proof. The original stop reason is retained.
            try:
                sleep(10)
                observations["classification"] = observer.observe(final=True)
            except Exception:
                evidence["window"].update({"complete": False, "truncated": True})
        try:
            classification = C.classify(evidence) if evidence is not None else None
        except C.InvalidEvidence:
            classification = None
        # Deletion is recorded separately, never treated as stop evidence.
        report = {"scope": "closed synthetic hosted lifetime evidence", "hosted_admitted": False,
                  "run_id": run_id, "source_manifest_sha256": built["source_manifest_sha256"],
                  "failure": failure, "cleanup_verified": journal["cleanup_complete"], "cleanup_failures": failures,
                  "classification": classification, "api_counts": api.counts}
        try:
            if evidence is not None:
                save_json(evidence_path, evidence)
                save_json(work / "observations.json", observations)
            save_json(work / "report.json", report)
        except Exception:
            failure = failure or "evidence_checkpoint_failed"
    require(not failures, "cleanup_required_journal_retained")
    require(failure is None, failure or "probe_failed")
    return work


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-ref", required=True, choices=[PROJECT])
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--user-id")
    parser.add_argument("--cleanup-only", action="store_true")
    args = parser.parse_args()
    run_id = identifier(args.run_id)
    require(args.cleanup_only or args.user_id is not None, "user_id_required")
    if args.cleanup_only:
        path = ROOT / ".artifacts/pdf-verifier/hosted-limits" / run_id / "cleanup-journal.json"
        journal = validate_journal(B.read_json(path, 65536), run_id)
    env, pat = B.load_credentials()
    api = API(B.JSONTransport(), pat, env["SUPABASE_ANON_KEY"], env["SUPABASE_SERVICE_ROLE_KEY"])
    if args.cleanup_only:
        api.counts = journal["api_counts"]
        api.cleaning = True
        api.persist = lambda: save_json(path, journal)
    _, remote, _ = api.management_request()
    B.check_project(B.read_json(ROOT / "infra/account.json"), env, remote)
    if args.cleanup_only:
        require(not cleanup(api, journal, path), "cleanup_required_journal_retained")
        print("Exact temporary function and tagged synthetic Auth/account are absent.")
    else:
        run_probe(api, run_id, identifier(args.user_id))
        print("Closed lifetime experiment finished; cleanup verified. No host admission or acquisition was enabled.")


if __name__ == "__main__":
    try:
        main()
    except (B.ProbeError, O.ObservationError, C.InvalidEvidence) as error:
        raise SystemExit("Lifetime experiment stopped: " + str(error)) from None
    except Exception:
        raise SystemExit("Lifetime experiment stopped: operator_failed; inspect the no-secret journal.") from None
