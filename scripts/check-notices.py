#!/usr/bin/env python3
"""Fail when THIRD_PARTY_NOTICES.md does not cover every pin in the Package.resolved files.

Read-only, stdlib only. Each pin must appear in the notices as a line
    - Pin: `<identity> <version or -> <revision>` (...)
with the same version and revision. Notice pins that no resolved file contains are reported as stale.

Usage: python3 scripts/check-notices.py [--notices PATH] [--resolved PATH ...]
"""
import argparse
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_RESOLVED = [
    "Package.resolved",
    "Sources/TonamoxExample/TonamoxExample.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
]
PIN_LINE = re.compile(r"^- Pin: `(\S+) (\S+) ([0-9a-f]{40})`")


def load_resolved(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    return [(p["identity"], p["state"].get("version") or "-", p["state"]["revision"]) for p in data.get("pins", [])]


def load_notice_pins(path):
    pins = set()
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = PIN_LINE.match(line)
            if m:
                pins.add(m.groups())
    return pins


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--notices", default=os.path.join(REPO, "THIRD_PARTY_NOTICES.md"))
    parser.add_argument("--resolved", action="append", help="Package.resolved to check (repeatable)")
    args = parser.parse_args()
    resolved_paths = args.resolved or [os.path.join(REPO, p) for p in DEFAULT_RESOLVED]

    notice_pins = load_notice_pins(args.notices)
    by_identity = {}
    for identity, version, revision in notice_pins:
        by_identity.setdefault(identity, []).append((version, revision))

    errors = []
    seen = set()
    for path in resolved_paths:
        if not os.path.exists(path):
            errors.append(f"{path}: not found")
            continue
        label = os.path.relpath(path, REPO)
        for pin in load_resolved(path):
            identity, version, revision = pin
            seen.add(pin)
            if pin in notice_pins:
                continue
            listed = by_identity.get(identity)
            if not listed:
                errors.append(f"{label}: {identity} {version} ({revision[:7]}) is missing from the notices")
            else:
                found = ", ".join(f"{v} ({r[:7]})" for v, r in listed)
                errors.append(f"{label}: {identity} resolves to {version} ({revision[:7]}), notices list {found}")

    # Staleness needs every pinned file; a partial --resolved list would flag the other file's pins.
    stale = sorted(notice_pins - seen) if args.resolved is None else []
    for identity, version, revision in stale:
        errors.append(f"notices: {identity} {version} ({revision[:7]}) is not pinned in any checked Package.resolved")

    if errors:
        print("\n".join(errors), file=sys.stderr)
        print(f"check-notices: {len(errors)} problem(s)", file=sys.stderr)
        return 1
    print(f"check-notices: {len(seen)} pin(s) across {len(resolved_paths)} file(s) match THIRD_PARTY_NOTICES.md")
    return 0


if __name__ == "__main__":
    sys.exit(main())
