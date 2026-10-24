"""Read-only queries against the staging Supabase project through the Management API.

The bearer token is read from the macOS Keychain at call time and never printed or stored.
Only statements that start with SELECT or WITH are sent.
"""
import json
import re
import subprocess
import sys
import urllib.request

PROJECT = "coxhjvqpflgxkleydati"
URL = f"https://api.supabase.com/v1/projects/{PROJECT}/database/query"
_FORBIDDEN = re.compile(
    r"\b(insert|update|delete|drop|alter|create|grant|revoke|truncate|comment|copy|vacuum|call|do|set|reset|lock|refresh)\b",
    re.I,
)


def _token() -> str:
    return subprocess.run(
        ["security", "find-generic-password", "-s", "Supabase CLI", "-w"],
        check=True, capture_output=True, text=True,
    ).stdout.strip()


def _strip_literals(sql: str) -> str:
    return re.sub(r"'(?:[^']|'')*'", "''", sql)


def query(sql: str):
    s = sql.strip().rstrip(";")
    head = s.split(None, 1)[0].lower() if s else ""
    if head not in ("select", "with") or ";" in s or _FORBIDDEN.search(_strip_literals(s)):
        raise ValueError("only single read-only SELECT statements are allowed")
    body = json.dumps({"query": s, "read_only": True}).encode()
    req = urllib.request.Request(URL, data=body, method="POST", headers={
        "Authorization": "Bearer " + _token(),
        "Content-Type": "application/json",
        "User-Agent": "science-reader-interest-eval",
    })
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:  # surface the API's message, never the request headers
        raise RuntimeError(f"HTTP {e.code}: {e.read().decode()[:2000]}") from None


if __name__ == "__main__":
    print(json.dumps(query(sys.stdin.read()), indent=1, default=str))
