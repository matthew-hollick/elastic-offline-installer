#!/usr/bin/env python3
"""Download integration packages from the public EPR (epr.elastic.co).

By default downloads the latest version of every package plus its signature,
so the output directory can be dropped straight into a self-hosted
package-registry `package_paths` dir. Pass package names to download only
those, e.g.:

    python3 scripts/download_integrations.py --out dist/epr/packages nginx system
"""

import argparse
import json
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

EPR_URL = "https://epr.elastic.co"


def version_key(version: str) -> list:
    """Sortable key for versions like '2.1.0' or '2.1.0-rc1'.

    Numeric parts tag 2, non-numeric (pre-release) parts tag 0, and a
    release gets a (1,) sentinel at the end — so a release outranks its
    pre-releases ('2.1.0' > '2.1.0-rc1') while shorter releases still
    rank below longer ones ('0' < '0.2.0').
    """
    parts = [
        (2, int(p)) if p.isdigit() else (0, p) for p in re.split(r"[.-]", version)
    ]
    if not any(kind == 0 for kind, _ in parts):
        parts.append((1,))
    return parts


def urlopen_retry(req: urllib.request.Request, retries: int = 3):
    """urlopen with backoff — the EPR occasionally 5xxs individual files."""
    for attempt in range(retries):
        try:
            return urllib.request.urlopen(req, timeout=120)
        except (urllib.error.URLError, OSError):
            if attempt == retries - 1:
                raise
            time.sleep(2**attempt)


def fetch(url: str, dest: Path) -> str:
    if dest.exists():
        return "exists"
    part = dest.with_name(dest.name + ".part")
    req = urllib.request.Request(url, headers={"User-Agent": "elastic-offline-installer"})
    try:
        with urlopen_retry(req) as r, open(part, "wb") as f:
            while chunk := r.read(1 << 20):
                f.write(chunk)
        part.rename(dest)
        return "downloaded"
    except Exception:
        part.unlink(missing_ok=True)
        raise


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", default="dist/epr/packages", help="output directory")
    ap.add_argument(
        "--all-versions",
        action="store_true",
        help="download every published version, not just the latest of each",
    )
    ap.add_argument("names", nargs="*", help="limit to these package names")
    args = ap.parse_args()

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    print(f"== fetching index from {EPR_URL}/search?all=true")
    req = urllib.request.Request(
        f"{EPR_URL}/search?all=true", headers={"User-Agent": "elastic-offline-installer"}
    )
    with urlopen_retry(req) as r:
        index = json.load(r)

    selected: list[dict] = []
    if args.all_versions:
        selected = [e for e in index if not args.names or e["name"] in args.names]
    else:
        latest: dict[str, dict] = {}
        for e in index:
            if args.names and e["name"] not in args.names:
                continue
            prev = latest.get(e["name"])
            if prev is None or version_key(e["version"]) > version_key(prev["version"]):
                latest[e["name"]] = e
        selected = sorted(latest.values(), key=lambda e: e["name"])

    if not selected:
        print("error: no matching packages found", file=sys.stderr)
        return 1

    print(f"== {len(selected)} package(s) to download into {out}")
    failures = 0
    for entry in selected:
        for key in ("download", "signature_path"):
            path = entry.get(key)
            if not path:
                continue
            dest = out / Path(path).name
            try:
                print(f"{fetch(EPR_URL + path, dest)}: {dest.name}", flush=True)
            except Exception as exc:  # noqa: BLE001 - keep going, tally failures
                print(f"FAIL: {dest.name}: {exc}", file=sys.stderr, flush=True)
                failures += 1

    if failures:
        print(f"== done with {failures} failure(s)", file=sys.stderr)
        return 1
    print(f"== done: {len(selected)} package(s) in {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
