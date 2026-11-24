#!/usr/bin/env python3
"""Warn when a newer upstream version exists than the Taskfile vars pin.

Read-only — prints a table; exits 1 if anything is behind (use it in CI or
before a bundle refresh). Sources: GitHub releases, GitLab releases, the
Elastic artifacts versions API. Vars set to "latest" are reported as their
resolved current release.
"""

import json
import re
import sys
import urllib.request
from pathlib import Path

TASKFILE = Path(__file__).resolve().parent.parent / "Taskfile.yaml"
UA = {"User-Agent": "elastic-offline-installer"}

# var name -> (kind, locator)
#   github  : "owner/repo"         -> releases/latest .tag_name
#   gitlab  : "group/project"      -> releases[0] .tag_name
#   elastic : None                 -> latest 9.x on artifacts-api
SOURCES = {
    "STACK_VERSION": ("elastic", None),
    "SNMP_EXPORTER_VERSION": ("github", "prometheus/snmp_exporter"),
    "TRIVY_VERSION": ("github", "aquasecurity/trivy"),
    "CHECKOV_VERSION": ("github", "bridgecrewio/checkov"),
    "KSM_VERSION": ("github", "kubernetes/kube-state-metrics"),
    "GITLAB_RUNNER_VERSION": ("gitlab", "gitlab-org/gitlab-runner"),
    "AUDITOR_VERSION": ("github", "chef/inspec"),  # cincproject/auditor tracks InSpec
    "VENOM_VERSION": ("github", "ovh/venom"),
    "CADDY_VERSION": ("github", "caddyserver/caddy"),
    "DIAG_VERSION": ("github", "elastic/support-diagnostics"),
    "EPR_VERSION": ("github", "elastic/package-registry"),
}


def get_json(url: str):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def taskfile_vars() -> dict:
    vars_ = {}
    in_vars = False
    for line in TASKFILE.read_text().splitlines():
        if line == "vars:":
            in_vars = True
            continue
        if in_vars:
            m = re.match(r"^  (\w+):\s*\"?([^\"\s]+)", line)
            if not m:
                break
            vars_[m.group(1)] = m.group(2)
    return vars_


def latest(kind: str, loc: str | None) -> str | None:
    if kind == "github":
        return get_json(
            f"https://api.github.com/repos/{loc}/releases/latest"
        ).get("tag_name")
    if kind == "gitlab":
        rels = get_json(
            f"https://gitlab.com/api/v4/projects/{loc.replace('/', '%2F')}/releases"
        )
        return max((r["tag_name"] for r in rels), key=version_key, default=None)
    if kind == "elastic":
        data = get_json("https://artifacts-api.elastic.co/v1/versions")
        nines = [
            v for v in data.get("versions", [])
            if re.fullmatch(r"9\.\d+\.\d+", v)
        ]
        return max(nines, key=version_key, default=None)
    return None


def version_key(v: str) -> list:
    return [int(x) if x.isdigit() else 0 for x in re.split(r"[.-]", v.lstrip("v"))]


def main() -> int:
    pinned = taskfile_vars()
    rows, behind = [], False
    for name, (kind, loc) in SOURCES.items():
        cur = pinned.get(name)
        if cur is None:
            continue
        try:
            new = latest(kind, loc)
        except Exception as e:
            rows.append((name, cur, f"check failed: {e}", "?"))
            continue
        state = "ok"
        if cur == "latest":
            state = f"-> {new}"
        elif new and version_key(new) > version_key(cur):
            state, behind = f"UPDATE -> {new}", True
        rows.append((name, cur, new or "?", state))

    width = max(len(r[0]) for r in rows)
    for name, cur, new, state in rows:
        print(f"{name:<{width}}  pinned={cur:<10} latest={new:<14} {state}")
    return 1 if behind else 0


if __name__ == "__main__":
    sys.exit(main())
