#!/usr/bin/env python3
"""Offline classification of bounded, operator-normalized synthetic probe logs.

No network, credentials, deployment, or host-admission authority. The operator
must separately establish provenance/completeness of the normalized envelope.
"""
from __future__ import annotations

import datetime as dt
import json
import re
import sys
from typing import Any

PROJECT = "coxhjvqpflgxkleydati"
RUNTIME = "supabase-edge-runtime-1.77.0 (compatible with Deno v2.1.4)"
CASES = ("deny_missing_auth", "deny_wrong_run", "deny_invalid_case", "control",
         "cpu-wasm", "memory-wasm", "background", "recovery")
DENIALS = dict(zip(CASES[:3], (401, 403, 400)))
TARGET = {"cpu-wasm": "CPUTime", "memory-wasm": "Memory", "background": "WallClockTime"}
REASONS = {"CPUTime", "Memory", "WallClockTime", "EarlyDrop", "EventLoopCompleted", "TerminationRequested"}
EVENTS = {"start", "complete", "fallback", "allocation_refused", "heartbeat", "beforeunload", "failed"}
TERMINALS = {"complete", "fallback", "allocation_refused", "failed"}
SHA = re.compile(r"[0-9a-f]{64}\Z")
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")
STAMP = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z\Z")
MAX_INPUT_BYTES = 512 * 1024
MAX_ROWS = 400


class InvalidEvidence(ValueError):
    """Only fixed codes, never input data, leave the classifier."""


def require(value: bool, code: str = "invalid_evidence") -> None:
    if not value:
        raise InvalidEvidence(code)


def keys(value: Any, expected: set[str]) -> dict:
    require(type(value) is dict and set(value) == expected)
    return value


def uuid(value: Any) -> bool:
    return isinstance(value, str) and UUID.fullmatch(value) is not None


def sha(value: Any) -> bool:
    return isinstance(value, str) and SHA.fullmatch(value) is not None


def enum(value: Any, choices: set[str]) -> bool:
    return isinstance(value, str) and value in choices


def instant(value: Any) -> dt.datetime:
    require(isinstance(value, str) and STAMP.fullmatch(value) is not None, "invalid_timestamp")
    try:
        return dt.datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError:
        raise InvalidEvidence("invalid_timestamp") from None


def loads(raw: str) -> Any:
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "duplicate_json_key")
            result[key] = value
        return result
    try:
        return json.loads(raw, object_pairs_hook=unique,
                          parse_constant=lambda _: (_ for _ in ()).throw(InvalidEvidence("invalid_json")))
    except (ValueError, RecursionError):
        raise InvalidEvidence("invalid_json") from None


def classify(evidence: Any) -> dict:
    """Input schema is intentionally closed; report contains only fixed enums/IDs."""
    keys(evidence, {"identity", "requests", "window", "rows"})
    ident = keys(evidence["identity"], {"run_id", "function_id", "deployment_id", "source_sha256", "runtime_version"})
    require(uuid(ident["run_id"]) and uuid(ident["function_id"]) and sha(ident["source_sha256"]), "invalid_identity")
    require(ident["deployment_id"] == f"{PROJECT}_{ident['function_id']}_1", "invalid_identity")
    require(ident["runtime_version"] == RUNTIME, "runtime_changed")
    window = keys(evidence["window"], {"start", "end", "complete", "truncated"})
    begin, end = instant(window["start"]), instant(window["end"])
    require(0 < (end - begin).total_seconds() <= 1800, "invalid_window")
    require(type(window["complete"]) is bool and type(window["truncated"]) is bool)
    requests = evidence["requests"]
    require(type(requests) is list and len(requests) <= len(CASES), "request_budget")
    attempts, requested = {}, {}
    last_sent = begin
    for index, request in enumerate(requests):
        keys(request, {"case", "attempt_id", "sent_at", "http_status"})
        name = request["case"]
        require(name == CASES[index], "request_order")
        require(uuid(request["attempt_id"]) and request["attempt_id"] not in attempts, "duplicate_attempt")
        sent = instant(request["sent_at"])
        require(last_sent <= sent <= end, "request_order")
        last_sent = sent
        status = request["http_status"]
        require(status is None or type(status) is int and 100 <= status <= 599)
        attempts[request["attempt_id"]] = name
        requested[name] = {**request, "sent": sent}
    rows = evidence["rows"]
    require(type(rows) is list and len(rows) <= MAX_ROWS, "row_budget")
    app = {name: [] for name in CASES}
    shutdowns: dict[str, list[dict]] = {}
    runtime_failures: dict[str, list[dict]] = {}
    seen = set()
    for row in rows:
        keys(row, {"timestamp", "event_type", "function_id", "deployment_id", "execution_id", "reason", "message"})
        at = instant(row["timestamp"])
        require(begin <= at <= end, "row_outside_window")
        require(row["function_id"] == ident["function_id"], "foreign_function")
        require(row["deployment_id"] in (None, ident["deployment_id"]), "foreign_deployment")
        require(uuid(row["execution_id"]), "invalid_execution")
        require(enum(row["event_type"], {"Log", "Boot", "Shutdown", "UncaughtException", "BootFailure"}))
        require(row["reason"] is None or enum(row["reason"], REASONS))
        message = row["message"]
        require(message is None or isinstance(message, str) and len(message) <= 4096)
        if message is not None:
            try:
                require(len(message.encode("utf-8")) <= 4096)
            except UnicodeEncodeError:
                raise InvalidEvidence("invalid_utf8") from None
        failure = row["event_type"] in {"UncaughtException", "BootFailure"}
        # The event identity matters; arbitrary exception text must not enter
        # either the retained evidence or its deduplication key.
        canonical = json.dumps({**row, "message": None} if failure else row,
                               sort_keys=True, separators=(",", ":"))
        if canonical in seen:
            continue
        seen.add(canonical)
        if row["event_type"] == "Shutdown":
            require(row["reason"] in REASONS and message is None, "invalid_shutdown")
            shutdowns.setdefault(row["execution_id"], []).append({"at": at, "reason": row["reason"]})
            continue
        require(row["reason"] is None)
        if failure:
            runtime_failures.setdefault(row["execution_id"], []).append({
                "at": at, "event_type": row["event_type"], "execution_id": row["execution_id"],
            })
            continue
        if row["event_type"] != "Log" or message is None:
            continue  # Never retain raw runtime errors or arbitrary console text.
        try:
            payload = loads(message)
        except InvalidEvidence:
            # A damaged structured record could have been our terminal event.
            # Do not turn it into evidence of uninterrupted work by dropping it.
            require(not message.lstrip().startswith("{"), "malformed_application_log")
            continue
        if not isinstance(payload, dict) or payload.get("probe") != "hosted-limits-v1":
            continue
        keys(payload, {"probe", "event", "run_id", "attempt_id", "case", "source_sha256", "deployment_id",
                       "execution_id", "isolate_id", "runtime_version", "sequence", "elapsed_ms", "pages"})
        require(enum(payload["event"], EVENTS), "invalid_probe_event")
        require(payload["run_id"] == ident["run_id"] and payload["source_sha256"] == ident["source_sha256"], "source_mismatch")
        require(payload["runtime_version"] == RUNTIME, "runtime_changed")
        require(payload["deployment_id"] == ident["deployment_id"] and payload["execution_id"] == row["execution_id"], "identity_mismatch")
        require(uuid(payload["isolate_id"]), "invalid_identity")
        attempt = payload["attempt_id"]
        require(isinstance(attempt, str) and attempt in attempts and attempts[attempt] == payload["case"], "unrequested_work")
        name = payload["case"]
        require(name not in DENIALS, "work_after_denial")
        require(at >= requested[name]["sent"], "work_before_request")
        require(type(payload["sequence"]) is int and 0 <= payload["sequence"] <= 64)
        require((payload["event"] == "failed" and payload["elapsed_ms"] is None) or
                type(payload["elapsed_ms"]) in (int, float) and 0 <= payload["elapsed_ms"] <= 500000)
        require(payload["pages"] is None or type(payload["pages"]) is int and payload["pages"] == 1)
        event = payload["event"]
        if event == "start":
            require(payload["sequence"] == 0 and payload["elapsed_ms"] == 0 and payload["pages"] is None)
        else:
            require(payload["sequence"] > 0)
        require(payload["pages"] is None or name == "recovery" and event == "complete")
        require(event != "complete" or name in {"control", "recovery"})
        require(name != "recovery" or event != "complete" or payload["pages"] == 1)
        require(event != "fallback" or name in TARGET)
        require(event != "allocation_refused" or name == "memory-wasm")
        require(event != "heartbeat" or name == "background")
        app[name].append({**payload, "at": at})

    # Log delivery may expose later events before their start. Validate every
    # received sequence/binding now, but require a unique start before attributing
    # an isolate shutdown. Different cases may share a warm isolate.
    spans = {}
    execution_to_isolate, isolate_to_execution = {}, {}
    for name, events in app.items():
        if not events:
            continue
        events.sort(key=lambda e: e["sequence"])
        starts = [event for event in events if event["event"] == "start"]
        require(len(starts) <= 1, "ambiguous_start")
        first = events[0]
        execution, isolate = first["execution_id"], first["isolate_id"]
        require(execution_to_isolate.setdefault(execution, isolate) == isolate, "ambiguous_isolate")
        require(isolate_to_execution.setdefault(isolate, execution) == execution, "ambiguous_execution")
        previous, previous_at, previous_ms = -1, first["at"], 0
        terminals = []
        for event in events:
            require(event["execution_id"] == execution and event["isolate_id"] == isolate, "ambiguous_start")
            require(not terminals, "event_after_terminal")
            require(event["sequence"] > previous and event["at"] >= previous_at and
                    (event["elapsed_ms"] is None or event["elapsed_ms"] >= previous_ms), "event_order")
            if event["event"] in TERMINALS:
                terminals.append(event)
            previous, previous_at, previous_ms = event["sequence"], event["at"], event["elapsed_ms"]
        stops = shutdowns.get(execution, [])
        require(len(stops) <= 1, "ambiguous_shutdown")
        stop = stops[0] if stops else None
        require(stop is None or all(event["at"] <= stop["at"] for event in events), "event_after_shutdown")
        terminal = terminals[0] if terminals else None
        failures = runtime_failures.get(execution, [])
        require(stop is None or all(event["at"] <= stop["at"] for event in failures), "event_after_shutdown")
        boundary = terminal["at"] if terminal else stop["at"] if stop else end
        # A runtime failure before this same execution's start is also
        # inconsistent with a healthy case. Do not silently clear that history.
        failures = sorted((event for event in failures if event["at"] <= boundary), key=lambda e: e["at"])
        spans[name] = {"start": starts[0] if starts else None, "terminal": terminal,
                       "shutdown": stop, "runtime_failures": failures}

    # Serial work is a run-wide rule, not merely an isolate-local busy flag.
    # Missing evidence makes the sequence unconfirmed; proven overlap is invalid.
    serial_confirmed = all(requested[name]["http_status"] == status
                           for name, status in DENIALS.items() if name in requested)
    for index, name in enumerate(CASES[3:], start=3):
        if name not in requested or index + 1 == len(requests):
            continue
        span = spans.get(name)
        if span is None:
            serial_confirmed = False
            continue
        terminal = span["terminal"] or span["shutdown"]
        if terminal is None:
            serial_confirmed = False
            if CASES[index + 1] in spans:
                raise InvalidEvidence("overlapping_cases")
            continue
        require(terminal["at"] <= requested[CASES[index + 1]]["sent"], "overlapping_cases")

    results = []
    # A complete query window is not complete execution evidence: the start may
    # arrive on a later bounded GET. Until then no partial span can authorize work.
    complete = (window["complete"] and not window["truncated"] and serial_confirmed
                and all(span["start"] is not None for span in spans.values()))
    for name in CASES:
        result = {"case": name, "status": "not_requested", "target_limit_observed": False,
                  "isolate_termination_observed": False, "shutdown_reason": None, "runtime_failure_events": []}
        if name in requested:
            result["status"] = "inconclusive"
            span = spans.get(name)
            if span is not None:
                result["runtime_failure_events"] = [
                    {"event_type": failure["event_type"], "execution_id": failure["execution_id"],
                     "timestamp": failure["at"].isoformat().replace("+00:00", "Z")}
                    for failure in span["runtime_failures"]
                ]
            if complete and name in DENIALS:
                if requested[name]["http_status"] == DENIALS[name]:
                    result["status"] = "denial_confirmed"
            elif complete and span is not None:
                stop, terminal = span["shutdown"], span["terminal"]
                # A later shutdown of a warm worker does not prove a host limit
                # stopped an earlier case which had already returned.
                if span["runtime_failures"]:
                    # An exception before a later cumulative limit shutdown
                    # prevents attributing successful stress to that limit.
                    # The final isolate stop remains independently observable.
                    if stop is not None:
                        result["shutdown_reason"] = stop["reason"]
                        result["isolate_termination_observed"] = True
                elif terminal is not None:
                    result["status"] = {"complete": "completed", "fallback": "fallback_only", "failed": "inconclusive",
                                        "allocation_refused": "allocation_refused_only"}[terminal["event"]]
                elif stop is not None:
                    result["shutdown_reason"] = stop["reason"]
                    result["isolate_termination_observed"] = True
                    if name in TARGET and stop["reason"] in TARGET.values():
                        result["status"] = "hard_stop_observed"
                        result["target_limit_observed"] = stop["reason"] == TARGET[name]
                    else:
                        result["status"] = "other_shutdown_observed"
        results.append(result)
    return {"schema_version": 1, "run_id": ident["run_id"], "source_sha256": ident["source_sha256"],
            "observation_complete": complete, "hosted_admitted": False, "cases": results}


def main() -> int:
    raw = sys.stdin.buffer.read(MAX_INPUT_BYTES + 1)
    try:
        require(len(raw) <= MAX_INPUT_BYTES, "input_limit")
        report = classify(loads(raw.decode("utf-8")))
    except (InvalidEvidence, UnicodeDecodeError) as error:
        print(json.dumps({"error": str(error) if isinstance(error, InvalidEvidence) else "invalid_utf8",
                          "hosted_admitted": False}))
        return 2
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
