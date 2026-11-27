import json
import os
import subprocess
import sys
import tempfile
import zipfile

REPO = "inugamisanwolf-svg/PupilIOS"


def token():
    out = subprocess.run(
        ["git", "credential", "fill"],
        input="protocol=https\nhost=github.com\n\n",
        capture_output=True,
        text=True,
    ).stdout
    for line in out.splitlines():
        if line.startswith("password="):
            return line.split("=", 1)[1].strip()
    raise SystemExit("no token")


def api(tok, path, out):
    subprocess.run(
        ["curl.exe", "-sSL", "-H", f"Authorization: token {tok}", f"https://api.github.com{path}", "-o", out],
        check=True,
    )


def main():
    tok = token()
    run_id = sys.argv[1] if len(sys.argv) > 1 else None
    if not run_id:
        api(tok, f"/repos/{REPO}/actions/runs?per_page=1", "runs.json")
        data = json.load(open("runs.json", encoding="utf-8"))
        run_id = data["workflow_runs"][0]["id"]
    print("run", run_id)

    work = tempfile.mkdtemp(prefix="ci-")
    zip_path = os.path.join(work, "logs.zip")
    subprocess.run(
        ["curl.exe", "-sSL", "-H", f"Authorization: token {tok}", f"https://api.github.com/repos/{REPO}/actions/runs/{run_id}/logs", "-o", zip_path],
        check=True,
    )
    try:
        with zipfile.ZipFile(zip_path) as zf:
            zf.extractall(os.path.join(work, "logs"))
    except zipfile.BadZipFile:
        print("logs not a zip (run may still be in progress)")
        return

    errors = []
    for root, _dirs, files in os.walk(os.path.join(work, "logs")):
        for name in files:
            path = os.path.join(root, name)
            with open(path, encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    if "error:" in line and "grep" not in line and "##[error]" not in line:
                        errors.append(line.rstrip())

    seen = set()
    unique = []
    for line in errors:
        key = line.split(" error: ")[-1]
        if key in seen:
            continue
        seen.add(key)
        unique.append(line)

    print(f"unique errors: {len(unique)}")
    for line in unique:
        print(line)

    with open(os.path.join("ci-logs", f"errors-{run_id}.txt"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(unique))


if __name__ == "__main__":
    main()
