"""Bounded, exact-function log observation for the closed lifetime experiment.

No deployment or execution authority. Unknown log text and runtime exception
messages are never retained. A complete query is not a delivery guarantee.
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import json
from pathlib import Path
from urllib.parse import urlencode

_spec = importlib.util.spec_from_file_location("limits_classifier", Path(__file__).with_name("classify.py"))
C = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(C)

FIELDS = ("function_id", "deployment_id", "execution_id", "event_type", "reason", "runtime_version",
          "cpu_time_used", "memory_used.total", "memory_used.heap", "memory_used.external")
APP_KEYS = {"probe", "event", "run_id", "attempt_id", "case", "source_sha256", "deployment_id",
            "execution_id", "isolate_id", "runtime_version", "sequence", "elapsed_ms", "pages"}
MAX_QUERIES = 24
MAX_PAGE = 50
SLICE_SECONDS = 180


class ObservationError(ValueError):
    """Fixed diagnostic code; no remote message is included."""


def require(ok, code):
    if not ok:
        raise ObservationError(code)


def stamp(value: dt.datetime) -> str:
    require(value.tzinfo == dt.timezone.utc, "invalid_utc_time")
    return value.isoformat(timespec="microseconds").replace("+00:00", "Z")


def query_path(function_id: str, start: str, end: str) -> str:
    require(C.uuid(function_id), "invalid_function_id")
    a, b = C.instant(start), C.instant(end)
    require(0 < (b - a).total_seconds() <= 1800, "invalid_query_window")
    # The API rounds its window to minutes. Widen those parameters and add exact
    # timestamp predicates in SQL, so rounding cannot omit boundary records.
    floor = a.replace(second=0, microsecond=0)
    ceiling = b.replace(second=0, microsecond=0) + dt.timedelta(minutes=1)
    columns = ", ".join(f"log_attributes['{name}'] AS {name.replace('.', '_')}" for name in FIELDS)
    # ClickHouse expands SELECT aliases in WHERE. Qualify the source timestamp
    # so the formatted output alias cannot replace the DateTime64 predicate.
    sql = ("SELECT formatDateTime(logs.timestamp, '%Y-%m-%dT%H:%i:%S.%fZ', 'UTC') AS timestamp, "
           f"event_message, {columns} FROM logs WHERE source = 'function_logs' "
           f"AND log_attributes['function_id'] = '{function_id}' "
           f"AND logs.timestamp >= parseDateTime64BestEffort('{start}', 6, 'UTC') "
           f"AND logs.timestamp <= parseDateTime64BestEffort('{end}', 6, 'UTC') "
           "ORDER BY logs.timestamp ASC LIMIT 50")
    return "/analytics/endpoints/logs?" + urlencode({
        "sql": sql, "iso_timestamp_start": stamp(floor), "iso_timestamp_end": stamp(ceiling),
    })


def normalize_page(value, identity, start, end):
    require(type(value) is dict and set(value) <= {"result", "error"}
            and value.get("error") in (None, "") and type(value.get("result")) is list, "invalid_log_response")
    raw_rows = value["result"]
    require(len(raw_rows) <= MAX_PAGE, "oversized_log_page")
    expected = {"timestamp", "event_message", *(name.replace(".", "_") for name in FIELDS)}
    rows, metrics = [], []
    begin, finish = C.instant(start), C.instant(end)
    for raw in raw_rows:
        require(type(raw) is dict and set(raw) == expected, "invalid_log_fields")
        at = C.instant(raw["timestamp"])
        require(begin <= at <= finish, "log_outside_query")
        require(raw["function_id"] == identity["function_id"], "foreign_function")
        deployment = raw["deployment_id"] or None
        require(deployment in (None, identity["deployment_id"]), "foreign_deployment")
        execution = raw["execution_id"]
        require(C.uuid(execution), "missing_execution_id")
        kind = raw["event_type"]
        require(kind in {"Log", "Boot", "Shutdown", "UncaughtException", "BootFailure"}, "unknown_platform_event")
        require(raw["runtime_version"] in (None, "", identity["runtime_version"]), "runtime_changed")
        reason = raw["reason"] or None
        require((kind == "Shutdown" and reason in C.REASONS) or (kind != "Shutdown" and reason is None), "invalid_shutdown_reason")
        message = None
        if kind == "Log":
            text = raw["event_message"]
            require(isinstance(text, str) and len(text.encode("utf-8")) <= 10000, "invalid_log_message")
            try:
                payload = C.loads(text)
            except C.InvalidEvidence:
                require(not text.lstrip().startswith("{"), "malformed_application_log")
                payload = None
            if type(payload) is dict and payload.get("probe") == "hosted-limits-v1":
                # Validate the full context/field types through classify before
                # persisting anything; only the closed schema is admitted here.
                require(set(payload) == APP_KEYS, "invalid_application_schema")
                message = json.dumps(payload, sort_keys=True, separators=(",", ":"), allow_nan=False)
                require(len(message.encode("utf-8")) <= 4096, "application_log_limit")
        rows.append({"timestamp": stamp(at), "event_type": kind, "function_id": identity["function_id"],
                     "deployment_id": deployment, "execution_id": execution, "reason": reason, "message": message})
        # These remain worker accounting and shutdown snapshots. They are never
        # converted into per-document CPU, configured limits, or peak RSS.
        if kind == "Shutdown":
            numeric = {}
            for name in ("cpu_time_used", "memory_used.total", "memory_used.heap", "memory_used.external"):
                entry = raw[name.replace(".", "_")]
                if entry not in (None, ""):
                    require(isinstance(entry, str) and entry.isascii() and entry.isdigit()
                            and len(entry) <= 16 and int(entry) <= 2**53 - 1, "invalid_shutdown_accounting")
                    numeric[name] = int(entry)
            metrics.append({"timestamp": stamp(at), "execution_id": execution,
                            "scope": "worker-accounted CPU and shutdown memory snapshots", "values": numeric})
    return rows, metrics, len(raw_rows) == MAX_PAGE


class Observer:
    def __init__(self, api, journal, evidence, persist, now, sleep, accounting=None):
        self.api, self.journal, self.evidence, self.persist = api, journal, evidence, persist
        self.now, self.sleep = now, sleep
        self.accounting = accounting if accounting is not None else []
        self.closed = []
        self.current_start = C.instant(evidence["window"]["start"])

    def _page(self, start, end):
        queries = self.journal["log_queries"]
        require(len(queries) < MAX_QUERIES, "log_query_budget")
        if queries:
            previous = C.instant(queries[-1]["sent_at"])
            delay = 7 - (self.now() - previous).total_seconds()
            if delay > 0:
                self.sleep(delay)
        entry = {"start": stamp(start), "end": stamp(end), "sent_at": stamp(self.now()), "state": "dispatching"}
        queries.append(entry)
        self.persist()  # A lost response consumes the GET budget too.
        try:
            _, value, _ = self.api.management_request(query_path(self.evidence["identity"]["function_id"],
                                                               entry["start"], entry["end"]), limit=262144)
            rows, metrics, full = normalize_page(value, self.evidence["identity"], entry["start"], entry["end"])
            entry.update({"state": "full" if full else "complete", "rows": len(value["result"])})
            self.persist()
            if full:
                require((end - start).total_seconds() > 0.002, "unsplittable_log_page")
                middle = start + (end - start) / 2
                left, lm = self._page(start, middle)
                right, rm = self._page(middle, end)
                return left + right, lm + rm
            return rows, metrics
        except Exception:
            entry["state"] = "incomplete"
            self.persist()
            raise

    @staticmethod
    def _unique(rows):
        result = {}
        for row in rows:
            key = json.dumps(row, sort_keys=True, separators=(",", ":"), allow_nan=False)
            result[key] = row
        return list(result.values())

    def observe(self, final=False):
        finish = self.now()
        begin = C.instant(self.evidence["window"]["start"])
        require(0 < (finish - begin).total_seconds() <= 1800, "observation_window_expired")
        self.evidence["window"].update({"end": stamp(finish), "complete": False})
        self.persist()
        pieces = []
        while self.current_start + dt.timedelta(seconds=SLICE_SECONDS) < finish:
            boundary = self.current_start + dt.timedelta(seconds=SLICE_SECONDS)
            interval = (self.current_start, boundary)
            self.closed.append(interval)
            pieces.append(interval)
            self.current_start = boundary
        if final:
            pieces = list(self.closed)  # Re-read sealed windows for late arrivals.
        pieces.append((self.current_start, finish))
        fresh, metrics = [], []
        try:
            for a, b in pieces:
                rows, accounting = self._page(a, b)
                fresh.extend(rows)
                metrics.extend(accounting)
            merged = self._unique(self.evidence["rows"] + fresh)
            require(len(merged) <= C.MAX_ROWS, "observation_row_budget")
            candidate = {**self.evidence, "rows": merged,
                         "window": {"start": stamp(begin), "end": stamp(finish), "complete": True, "truncated": False}}
            report = C.classify(candidate)  # Context and all payload fields checked before persistence.
            self.evidence.update(candidate)
            self.accounting[:] = self._unique(self.accounting + metrics)
            self.persist()
            return report
        except Exception:
            self.evidence["window"].update({"complete": False, "truncated": True})
            self.persist()
            raise
