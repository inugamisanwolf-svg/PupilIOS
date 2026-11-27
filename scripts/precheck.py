"""UTF-8 / structural sanity check for every modified Swift file.

Comments in this project are full of Japanese; an invalid UTF-8 byte, a stray
BOM-in-the-middle, or unbalanced braces all show up as compiler errors that are
cheap to catch locally before burning a 6 minute CI run.

    python scripts/precheck.py
"""
from __future__ import annotations

import subprocess
import sys

PAIRS = {")": "(", "]": "[", "}": "{"}


def changed_files() -> list[str]:
    """Working-tree changes plus the files touched by the last commit."""
    out = subprocess.run(["git", "status", "--porcelain"], capture_output=True,
                         text=True, check=True).stdout
    paths: list[str] = []
    for line in out.splitlines():
        if not line.strip():
            continue
        path = line[3:].strip()
        if path.startswith('"') and path.endswith('"'):
            path = path[1:-1]
        paths.append(path)
    out = subprocess.run(["git", "diff", "--name-only", "HEAD~1", "HEAD"],
                         capture_output=True, text=True, check=False).stdout
    for p in out.splitlines():
        if p.strip():
            paths.append(p.strip())
    seen: set[str] = set()
    ordered: list[str] = []
    for p in paths:
        if p in seen:
            continue
        seen.add(p)
        ordered.append(p)
    return ordered


def strip_strings_and_comments(src: str) -> str:
    """Remove comments and string literals so brace counting is meaningful."""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                i += 1
        elif c == "/" and i + 1 < n and src[i + 1] == "*":
            i += 2
            while i + 1 < n and not (src[i] == "*" and src[i + 1] == "/"):
                i += 1
            i += 2
        elif c == '"':
            # triple-quoted then single-quoted, honouring escapes and \( ) interpolation
            if src.startswith('"""', i):
                i += 3
                while i + 2 < n and not src.startswith('"""', i):
                    i += 1
                i += 3
            else:
                i += 1
                depth = 0
                while i < n:
                    ch = src[i]
                    if ch == "\\":
                        i += 2
                        continue
                    if ch == '"':
                        i += 1
                        break
                    i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def check(path: str) -> list[str]:
    problems: list[str] = []
    raw = open(path, "rb").read()
    try:
        src = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        return [f"not valid UTF-8: {exc}"]
    if "\ufffd" in src:
        problems.append(f"contains {src.count(chr(0xFFFD))} U+FFFD replacement char(s)")
    crlf = raw.count(b"\r\n")
    if crlf and path.endswith(".swift"):
        problems.append(f"{crlf} CRLF line ending(s)")
    if path.endswith(".swift"):
        code = strip_strings_and_comments(src)
        stack: list[str] = []
        for idx, ch in enumerate(code):
            if ch in "([{":
                stack.append(ch)
            elif ch in ")]}":
                if not stack or stack.pop() != PAIRS[ch]:
                    line = code.count("\n", 0, idx) + 1
                    problems.append(f"unbalanced '{ch}' near line {line}")
                    stack = []
                    break
        if stack:
            problems.append(f"unclosed {''.join(stack)!r} at EOF")
        for i, line in enumerate(src.splitlines(), 1):
            if line.rstrip() != line and not line.rstrip() == "":
                if line.endswith(" ") or line.endswith("\t"):
                    problems.append(f"trailing whitespace line {i}")
                    break
    return problems


def main() -> int:
    paths = [p for p in changed_files() if p.endswith((".swift", ".yml", ".json", ".md", ".plist"))]
    if not paths:
        print("no changed files")
        return 0
    bad = 0
    for p in paths:
        problems = check(p)
        if problems:
            bad += 1
            print(f"NG  {p}")
            for pr in problems:
                print(f"      {pr}")
        else:
            print(f"ok  {p}")
    print(f"\n{len(paths) - bad}/{len(paths)} clean")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
