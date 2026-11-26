#!/usr/bin/env python3
"""Record every artifact in dist/ into dist/manifest.json.

The manifest is the inventory of what was packaged: path, size, sha512 and
the component (top-level dist/ dir) each artifact belongs to. It ships inside
every bundle, and acts as the baseline for `delta` — a bundle containing only
artifacts that are new or changed since the manifest was last written.

Subcommands:
  scan    rewrite dist/manifest.json from the current files
  diff    print what is new / changed / missing vs manifest.json
  verify  re-hash everything and report drift vs manifest.json
  delta   tar new+changed artifacts into elastic-offline-delta-*.tar.gz,
          then refresh manifest.json as the new baseline
"""
import argparse
import hashlib
import json
import sys
import tarfile
from datetime import UTC, datetime
from pathlib import Path

MANIFEST = "manifest.json"
DELTA_MANIFEST = "manifest-delta.json"
EXCLUDE = {MANIFEST, DELTA_MANIFEST}


def sha512_of(path: Path) -> str:
    digest = hashlib.sha512()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def scan_dist(root: Path) -> dict:
    """{relpath: {size, sha512, component}} for every payload file."""
    artifacts = {}
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        rel = path.relative_to(root).as_posix()
        if rel in EXCLUDE or path.suffix == ".part":
            continue
        artifacts[rel] = {
            "size": path.stat().st_size,
            "sha512": sha512_of(path),
            "component": rel.split("/", 1)[0],
        }
    return artifacts


def load_manifest(root: Path) -> dict | None:
    path = root / MANIFEST
    if not path.is_file():
        return None
    return json.loads(path.read_text())


def write_manifest(root: Path, artifacts: dict, stack_version: str,
                   name: str = MANIFEST, extra: dict | None = None) -> Path:
    doc = {
        "generated_at": datetime.now(UTC).isoformat(timespec="seconds"),
        "stack_version": stack_version,
        "summary": {
            "count": len(artifacts),
            "total_bytes": sum(a["size"] for a in artifacts.values()),
        },
        "artifacts": artifacts,
    }
    if extra:
        doc.update(extra)
    path = root / name
    path.write_text(json.dumps(doc, indent=1) + "\n")
    return path


def diff_artifacts(current: dict, baseline: dict) -> dict:
    old = baseline.get("artifacts", {})
    return {
        "new": sorted(p for p in current if p not in old),
        "changed": sorted(p for p in current
                          if p in old and current[p]["sha512"] != old[p]["sha512"]),
        "missing": sorted(p for p in old if p not in current),
    }


def cmd_scan(root: Path, args) -> int:
    path = write_manifest(root, scan_dist(root), args.stack_version)
    doc = json.loads(path.read_text())
    print(f"wrote {path}: {doc['summary']['count']} artifacts, "
          f"{doc['summary']['total_bytes']} bytes")
    return 0


def cmd_diff(root: Path, args) -> int:
    baseline = load_manifest(root)
    if baseline is None:
        print(f"no {root / MANIFEST} — run `task manifest` or `task package` first",
              file=sys.stderr)
        return 1
    delta = diff_artifacts(scan_dist(root), baseline)
    print(json.dumps(delta, indent=1))
    print(f"== {len(delta['new'])} new, {len(delta['changed'])} changed, "
          f"{len(delta['missing'])} missing", file=sys.stderr)
    return 0


def cmd_verify(root: Path, args) -> int:
    baseline = load_manifest(root)
    if baseline is None:
        print(f"no {root / MANIFEST} — nothing to verify against", file=sys.stderr)
        return 1
    recorded = baseline.get("artifacts", {})
    drift = diff_artifacts(scan_dist(root), baseline)
    ok = len(recorded) - len(drift["missing"]) - len(drift["changed"])
    print(f"== {ok} match, {len(drift['changed'])} changed, "
          f"{len(drift['missing'])} missing, {len(drift['new'])} unrecorded")
    for p in drift["changed"] + drift["missing"]:
        print(f"  drift: {p}")
    return 1 if drift["changed"] or drift["missing"] else 0


def cmd_delta(root: Path, args) -> int:
    baseline = load_manifest(root)
    if baseline is None:
        print(f"no {root / MANIFEST} — run `task package` first; "
              "a delta needs a packaged baseline to diff against", file=sys.stderr)
        return 1
    current = scan_dist(root)
    delta = diff_artifacts(current, baseline)
    payload = delta["new"] + delta["changed"]
    for p in delta["missing"]:
        print(f"  note: recorded artifact gone from dist (not in delta): {p}")
    if not payload:
        print("== nothing new or changed — no delta bundle written")
        return 0

    stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    write_manifest(
        root,
        {p: current[p] for p in payload},
        args.stack_version,
        name=DELTA_MANIFEST,
        extra={"delta": {
            "baseline_generated_at": baseline.get("generated_at"),
            "new": delta["new"],
            "changed": delta["changed"],
            "not_included_missing": delta["missing"],
        }},
    )
    bundle = Path(f"elastic-offline-delta-{args.stack_version}-{stamp}.tar.gz")
    with tarfile.open(bundle, "w:gz") as tar:
        tar.add(root / DELTA_MANIFEST, arcname=DELTA_MANIFEST)
        for rel in payload:
            tar.add(root / rel, arcname=rel)
    print(f"wrote {bundle}: {len(payload)} artifacts "
          f"({len(delta['new'])} new, {len(delta['changed'])} changed)")
    write_manifest(root, current, args.stack_version)
    print(f"== refreshed {root / MANIFEST} as the new baseline")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dist", default="dist", type=Path)
    ap.add_argument("--stack-version", default="unknown")
    sub = ap.add_subparsers(dest="command", required=True)
    for name in ("scan", "diff", "verify", "delta"):
        sub.add_parser(name)
    args = ap.parse_args()
    if not args.dist.is_dir():
        print(f"error: {args.dist} does not exist — run `task download` first",
              file=sys.stderr)
        return 1
    return {"scan": cmd_scan, "diff": cmd_diff,
            "verify": cmd_verify, "delta": cmd_delta}[args.command](args.dist, args)


if __name__ == "__main__":
    sys.exit(main())
