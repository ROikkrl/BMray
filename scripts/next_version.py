#!/usr/bin/env python3
"""Advance BMray versions with a single digit patch (0.3.9 -> 0.4.0)."""

from pathlib import Path
import re


def next_version(current: str) -> str:
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)\+(\d+)", current)
    if not match:
        raise ValueError(f"Invalid pubspec version: {current}")
    major, minor, patch, build = map(int, match.groups())
    if patch >= 9:
        minor += 1
        patch = 0
    else:
        patch += 1
    return f"{major}.{minor}.{patch}+{build + 1}"


if __name__ == "__main__":
    pubspec = Path(__file__).resolve().parent.parent / "pubspec.yaml"
    source = pubspec.read_text()
    match = re.search(r"^version: (\S+)$", source, flags=re.MULTILINE)
    if not match:
        raise SystemExit("version missing from pubspec.yaml")
    updated = next_version(match.group(1))
    pubspec.write_text(source[: match.start(1)] + updated + source[match.end(1) :])
    print(updated)
