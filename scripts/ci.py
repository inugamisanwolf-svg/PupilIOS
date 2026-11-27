#!/usr/bin/env python3
"""PupilIOS CI driver — trigger, watch, harvest.

Standard library only (Python 3.11+). The GitHub token is read from the Windows
credential store via `git credential fill`; it is never printed, logged, or
written to disk.

Usage:
    python scripts/ci.py run                # dispatch + wait + harvest
    python scripts/ci.py dispatch
    python scripts/ci.py status             # latest runs
    python scripts/ci.py wait --run-id N
    python scripts/ci.py logs --run-id N    # download logs, print error: lines
    python scripts/ci.py artifact --run-id N
    python scripts/ci.py owners             # errors -> responsible teammate
"""
from __future__ import annotations

import argparse
import io
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

OWNER = "inugamisanwolf-svg"
REPO = "PupilIOS"
WORKFLOW = "ios-build.yml"
ARTIFACT_NAME = "PupilIOS-unsigned-ipa"
DEFAULT_REF = "main"
API = "https://api.github.com"
UA = "PupilIOS-ci/1.0"

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DIST = os.path.join(ROOT, "dist")
LOG_DIR = os.path.join(ROOT, "ci-logs")

# Ownership map, straight from docs/CONTRACT.md §1.
OWNER_MAP = [
    ("Sources/Hitomi", "core-api"),
    ("Sources/Store", "core-api"),
    ("Sources/UI/Browse", "ui-browse"),
    ("Sources/UI/Search", "ui-browse"),
    ("Sources/UI/Detail", "ui-browse"),
    ("Sources/UI/Common", "ui-browse"),
    ("Sources/UI/Library", "ui-browse"),
    ("Sources/UI/Reader", "ui-reader"),
    ("Sources/UI/Root", "ui-reader"),
    ("Sources/App", "ui-reader"),
    ("Sources/DesignSystem", "astryx-design"),
    ("Sources/", "core-api"),
    ("Resources/astryx", "astryx-design"),
    ("project.yml", "build-ci"),
    (".github/", "build-ci"),
    ("Resources/Info.plist", "build-ci"),
    ("Resources/Assets.xcassets", "build-ci"),
    ("scripts/", "build-ci"),
]

ERROR_RE = re.compile(
    r"^(?P<file>[^:]+\.(?:swift|m|mm|h|c|cpp|plist|yml|yaml|json)):(?P<line>\d+)"
    r"(?::(?P<col>\d+))?:\s*(?P<sev>error|warning):\s*(?P<msg>.*)$"
)
GENERIC_ERROR_RE = re.compile(r"(?P<sev>error|warning):\s*(?P<msg>\S.*)$")


# --------------------------------------------------------------------------- auth
def token() -> str:
    """Fetch the GitHub token from the credential manager without echoing it."""
    try:
        proc = subprocess.run(
            ["git", "credential", "fill"],
            input="protocol=https\nhost=github.com\n\n",
            capture_output=True,
            text=True,
            check=True,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        sys.exit(f"could not run `git credential fill`: {exc}")
    for line in proc.stdout.splitlines():
        if line.startswith("password="):
            tok = line[len("password="):].strip()
            if tok:
                return tok
    sys.exit("no GitHub token in the credential store (host=github.com)")


# --------------------------------------------------------------------------- http
class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D401
        return None


_opener_plain = urllib.request.build_opener(_NoRedirect)


def _request(url: str, tok: str | None = None, method: str = "GET",
             body: dict | None = None, accept: str | None = None,
             follow: bool = False) -> tuple[int, bytes, dict]:
    data = None
    headers = {"User-Agent": UA, "Accept": accept or "application/vnd.github+json",
               "X-GitHub-Api-Version": "2022-11-28"}
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    if tok:
        headers["Authorization"] = f"Bearer {tok}"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    opener = urllib.request.build_opener() if follow else _opener_plain
    try:
        with opener.open(req, timeout=120) as resp:
            return resp.status, resp.read(), dict(resp.headers)
    except urllib.error.HTTPError as exc:
        payload = b""
        try:
            payload = exc.read()
        except Exception:
            pass
        if exc.code in (301, 302, 303, 307, 308) and follow:
            # should not happen with follow=True, but stay honest if it does
            return exc.code, payload, dict(exc.headers or {})
        return exc.code, payload, dict(exc.headers or {})


def api(path: str, tok: str, **kw) -> tuple[int, bytes, dict]:
    return _request(f"{API}{path}", tok, **kw)


def api_json(path: str, tok: str, **kw):
    status, payload, _ = api(path, tok, **kw)
    if status >= 300:
        sys.exit(f"API {path} -> HTTP {status}: {payload[:400].decode('utf-8', 'replace')}")
    return json.loads(payload or b"null")


def download(url: str, tok: str) -> bytes:
    """Download through GitHub's redirect to blob storage (auth on hop 1 only)."""
    status, payload, headers = _request(url, tok)
    if status in (301, 302, 303, 307, 308):
        loc = headers.get("Location") or headers.get("location")
        if not loc:
            sys.exit("redirect without Location header")
        status, payload, _ = _request(loc, None, follow=True)
    if status >= 300:
        sys.exit(f"download failed: HTTP {status} {payload[:300].decode('utf-8', 'replace')}")
    return payload


# --------------------------------------------------------------------------- verbs
def dispatch(tok: str, ref: str = DEFAULT_REF) -> None:
    path = f"/repos/{OWNER}/{REPO}/actions/workflows/{WORKFLOW}/dispatches"
    status, payload, _ = api(path, tok, method="POST", body={"ref": ref})
    if status not in (204, 201, 200):
        sys.exit(f"dispatch failed: HTTP {status} {payload[:400].decode('utf-8', 'replace')}")
    print(f"dispatched {WORKFLOW} on ref={ref}")


def list_runs(tok: str, limit: int = 10) -> list[dict]:
    """Repo-level run list, filtered client-side to our workflow.

    The workflow-scoped endpoint 404s until GitHub has registered the workflow
    file, so the repo-level list is the reliable one.
    """
    path = f"/repos/{OWNER}/{REPO}/actions/runs?per_page={max(limit * 3, 30)}"
    data = api_json(path, tok)
    runs = (data or {}).get("workflow_runs", [])
    ours = [r for r in runs if r.get("name") == "ios-build"
            or WORKFLOW in (r.get("path") or "")]
    return (ours or runs)[:limit]


def latest_run(tok: str, since_ts: float | None = None) -> dict | None:
    cut = None
    if since_ts is not None:
        # ISO-8601 Zulu timestamps compare correctly as plain strings
        cut = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(since_ts - 120))
    for run in list_runs(tok, 20):
        if cut is None or run.get("created_at", "") >= cut:
            return run
    return None


def wait(tok: str, run_id: int | None = None, timeout: int = 2700) -> dict:
    deadline = time.time() + timeout
    run = None
    while time.time() < deadline:
        if run_id is None:
            run = latest_run(tok)
        else:
            run = api_json(f"/repos/{OWNER}/{REPO}/actions/runs/{run_id}", tok)
        if not run:
            time.sleep(10)
            continue
        run_id = run["id"]
        status, concl = run.get("status"), run.get("conclusion")
        print(f"  run {run_id}: {status} {concl or ''}".rstrip(), flush=True)
        if status == "completed":
            return run
        time.sleep(20)
    sys.exit("timed out waiting for the run")


def fetch_logs(tok: str, run_id: int) -> dict[str, str]:
    blob = download(f"{API}/repos/{OWNER}/{REPO}/actions/runs/{run_id}/logs", tok)
    os.makedirs(LOG_DIR, exist_ok=True)
    zip_path = os.path.join(LOG_DIR, f"run-{run_id}.zip")
    with open(zip_path, "wb") as fh:
        fh.write(blob)
    out: dict[str, str] = {}
    with zipfile.ZipFile(io.BytesIO(blob)) as zf:
        for info in zf.infolist():
            if info.is_dir():
                continue
            raw = zf.read(info)
            out[info.filename] = raw.decode("utf-8", "replace")
            safe = info.filename.replace("/", "__").replace("\\", "__")
            with open(os.path.join(LOG_DIR, f"{run_id}-{safe}"), "w",
                      encoding="utf-8", errors="replace") as fh:
                fh.write(out[info.filename])
    print(f"logs -> {zip_path} ({len(out)} streams)")
    return out


def _rel(path: str) -> str:
    p = path.replace("\\", "/")
    # runner paths look like /Users/runner/work/PupilIOS/PupilIOS/Sources/...
    idx = p.rfind("/PupilIOS/PupilIOS/")
    if idx >= 0:
        p = p[idx + len("/PupilIOS/PupilIOS/"):]
    idx = p.rfind("/PupilIOS/")
    if idx >= 0:
        p = p[idx + len("/PupilIOS/"):]
    p = p.lstrip("/")
    if p.startswith("PupilIOS/"):
        p = p[len("PupilIOS/"):]
    idx = p.find("/Sources/")
    if idx > 0:
        p = p[idx + 1:]
    return p


SHELL_ECHO_HINTS = ("| tail", "grep -q", "tee build.log", "2>&1 |", "set -o pipefail")


def _is_shell_echo(line: str) -> bool:
    """Filter the workflow's own `run:` lines, which contain the word 'error:'."""
    if line.startswith(("\x1b[", "\u001b[")) or "\\x1b[" in line:
        return True
    body = line.lstrip("+ ").strip()
    return any(h in body for h in SHELL_ECHO_HINTS)


def extract_errors(streams: dict[str, str]) -> list[dict]:
    seen: set[tuple] = set()
    found: list[dict] = []
    for _name, text in streams.items():
        for raw in text.splitlines():
            line = raw.rstrip()
            # strip the CI timestamp prefix ("2026-11-27T09:12:33.1234567Z ")
            line = re.sub(r"^\d{4}-\d\d-\d\dT[\d:.]+Z\s", "", line).strip()
            if "error:" not in line and "warning:" not in line:
                continue
            if _is_shell_echo(line):
                continue
            m = ERROR_RE.match(line)
            if m:
                item = {
                    "file": _rel(m.group("file").strip()),
                    "line": int(m.group("line")),
                    "col": int(m.group("col")) if m.group("col") else 0,
                    "severity": m.group("sev"),
                    "message": m.group("msg").strip(),
                }
            else:
                g = GENERIC_ERROR_RE.search(line)
                if not g:
                    continue
                item = {"file": "", "line": 0, "col": 0,
                        "severity": g.group("sev"), "message": g.group("msg").strip()}
            key = (item["file"], item["line"], item["message"])
            if key in seen:
                continue
            seen.add(key)
            found.append(item)
    return found


def owner_of(path: str) -> str:
    p = path.replace("\\", "/")
    for prefix, owner in OWNER_MAP:
        if p.startswith(prefix):
            return owner
    if "/Pods/" in p or "xcodegen" in p.lower() or p.startswith("project.pbxproj"):
        return "build-ci"
    return "build-ci" if not p.startswith("Sources/") else "core-api"


def report_errors(errors: list[dict]) -> dict[str, list[dict]]:
    by_owner: dict[str, list[dict]] = {}
    for item in errors:
        if item["severity"] != "error":
            continue
        by_owner.setdefault(owner_of(item["file"]), []).append(item)
    return by_owner


def fetch_artifact(tok: str, run_id: int | None = None) -> str | None:
    runs = [api_json(f"/repos/{OWNER}/{REPO}/actions/runs/{run_id}", tok)] if run_id else list_runs(tok, 5)
    for run in runs:
        rid = run["id"]
        data = api_json(f"/repos/{OWNER}/{REPO}/actions/runs/{rid}/artifacts", tok)
        for art in (data or {}).get("artifacts", []):
            if art.get("name") != ARTIFACT_NAME or art.get("expired"):
                continue
            print(f"artifact: {art['name']} ({art['size_in_bytes']} bytes) run {rid}")
            blob = download(art["archive_download_url"], tok)
            os.makedirs(DIST, exist_ok=True)
            zp = os.path.join(DIST, f"{ARTIFACT_NAME}.zip")
            with open(zp, "wb") as fh:
                fh.write(blob)
            with zipfile.ZipFile(io.BytesIO(blob)) as zf:
                zf.extractall(DIST)
                names = zf.namelist()
            print(f"saved {zp}")
            for n in names:
                print(f"  -> {os.path.join(DIST, n)}")
            return art.get("archive_download_url")
    print("no unexpired artifact found")
    return None


# --------------------------------------------------------------------------- cli
def cmd_run(args, tok: str) -> None:
    since = time.time()
    dispatch(tok, args.ref)
    time.sleep(5)
    run = None
    deadline = time.time() + 300
    while run is None and time.time() < deadline:
        run = latest_run(tok, since_ts=since)
        if run is None:
            time.sleep(8)
    if run is None:
        sys.exit("dispatched but no run appeared")
    print(f"run {run['id']} -> {run['html_url']}")
    run = wait(tok, run["id"], args.timeout)
    concl = run.get("conclusion")
    print(f"conclusion: {concl}")
    streams = fetch_logs(tok, run["id"])
    errors = extract_errors(streams)
    by_owner = report_errors(errors)
    total_err = sum(len(v) for v in by_owner.values())
    print(f"errors: {total_err}")
    for owner, items in sorted(by_owner.items(), key=lambda kv: -len(kv[1])):
        print(f"\n== {owner} ({len(items)}) ==")
        for it in items[:40]:
            loc = f"{it['file']}:{it['line']}" if it["file"] else "(global)"
            print(f"  {loc}: {it['message']}")
    if concl == "success":
        fetch_artifact(tok, run["id"])
    else:
        print("\nrun failed — see ci-logs/ for the full text")


def main() -> None:
    ap = argparse.ArgumentParser(description="PupilIOS GitHub Actions driver")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("run", help="dispatch, wait, harvest")
    p.add_argument("--ref", default=DEFAULT_REF)
    p.add_argument("--timeout", type=int, default=2700)
    p.set_defaults(func=cmd_run)

    p = sub.add_parser("dispatch")
    p.add_argument("--ref", default=DEFAULT_REF)
    p.set_defaults(func=lambda a, t: dispatch(t, a.ref))

    p = sub.add_parser("status")
    p.add_argument("--limit", type=int, default=10)
    p.set_defaults(func=lambda a, t: _status(t, a.limit))

    p = sub.add_parser("wait")
    p.add_argument("--run-id", type=int)
    p.add_argument("--timeout", type=int, default=2700)
    p.set_defaults(func=lambda a, t: _wait_cmd(t, a.run_id, a.timeout))

    p = sub.add_parser("logs")
    p.add_argument("--run-id", type=int, required=True)
    p.set_defaults(func=lambda a, t: _logs(t, a.run_id))

    p = sub.add_parser("artifact")
    p.add_argument("--run-id", type=int)
    p.set_defaults(func=lambda a, t: fetch_artifact(t, a.run_id))

    p = sub.add_parser("owners")
    p.add_argument("--run-id", type=int)
    p.set_defaults(func=lambda a, t: _owners(t, a.run_id))

    args = ap.parse_args()
    args.func(args, token())


def _wait_cmd(tok: str, run_id: int | None, timeout: int) -> None:
    run = wait(tok, run_id, timeout)
    print(f"run {run['id']} -> {run['html_url']}")
    print(f"conclusion: {run.get('conclusion')}")


def _status(tok: str, limit: int = 10) -> None:
    for r in list_runs(tok, limit):
        print(f"{r['id']}  {r['status']:<10} {str(r.get('conclusion')):<10} "
              f"{r['created_at']}  {r['head_sha'][:8]}")


def _logs(tok: str, run_id: int) -> None:
    errors = extract_errors(fetch_logs(tok, run_id))
    by_owner = report_errors(errors)
    print(f"errors: {sum(len(v) for v in by_owner.values())}")
    for owner, items in sorted(by_owner.items(), key=lambda kv: -len(kv[1])):
        print(f"\n== {owner} ({len(items)}) ==")
        for it in items[:60]:
            loc = f"{it['file']}:{it['line']}" if it["file"] else "(global)"
            print(f"  {loc}: {it['message']}")


def _owners(tok: str, run_id: int | None) -> None:
    if run_id is None:
        run = latest_run(tok)
        if not run:
            sys.exit("no runs")
        run_id = run["id"]
    _logs(tok, run_id)


if __name__ == "__main__":
    main()
