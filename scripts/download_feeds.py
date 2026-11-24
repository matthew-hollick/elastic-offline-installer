#!/usr/bin/env python3
"""Download third-party runtime feeds into dist/ear/feeds for EAR to serve.

Config: files/feeds.json — a list under "feeds". Two types:

  file   download a URL verbatim (e.g. the CISA KEV JSON consumed by the
         cisa_kevs integration's `url` var)
  taxii  pull a TAXII 2.x collection (all pages) and flatten it to
         {"objects": [...]} — the shape ti_custom's CEL input maps into
         events, so the static file acts as a single-page collection
  github-release-asset
         download an asset (matched by "asset" regex) from the latest
         release of "repo" — for release assets whose names contain the
         release date and so can't use a fixed URL. For this type "dest"
         is a directory; the remote filename is kept.
  oci-artifact
         download the first (single) layer of an OCI artifact —
         "registry" (default ghcr.io), "repo", "tag" (default latest).
         For tools like trivy whose database ships as a registry
         artifact rather than a file; the layer is the tar.gz payload
         and its digest is verified.

Auth per feed is optional ("auth" object):
  {"type": "header", "env": "VAR", "header": "Authorization", "prefix": "Bearer "}
  {"type": "basic", "username": "u", "password": "p"}
  {"type": "basic", "username_env": "U", "password_env": "P"}
Any referenced env var that is unset skips the feed (not a failure).
"""

import argparse
import base64
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

UA = {"User-Agent": "elastic-offline-installer"}


def urlopen_retry(req: urllib.request.Request, retries: int = 3):
    """urlopen with backoff for transient 5xx/connection errors."""
    for attempt in range(retries):
        try:
            return urllib.request.urlopen(req, timeout=120)
        except (urllib.error.URLError, OSError):
            if attempt == retries - 1:
                raise
            time.sleep(2**attempt)


def auth_headers(feed: dict) -> tuple[dict, str | None]:
    """Headers for the feed, or a skip reason when a needed env var is unset."""
    auth = feed.get("auth")
    if not auth:
        return {}, None

    def env(name: str | None) -> tuple[str | None, str | None]:
        if name and name not in os.environ:
            return None, f"env var {name} not set"
        return os.environ.get(name, ""), None

    if auth.get("type") == "header":
        val, missing = env(auth.get("env"))
        if missing:
            return {}, missing
        return {auth["header"]: auth.get("prefix", "") + val}, None

    if auth.get("type") == "basic":
        user, pw = auth.get("username"), auth.get("password")
        if user is None:
            user, missing = env(auth.get("username_env"))
            if missing:
                return {}, missing
        if pw is None:
            pw, missing = env(auth.get("password_env"))
            if missing:
                return {}, missing
        token = base64.b64encode(f"{user}:{pw}".encode()).decode()
        return {"Authorization": f"Basic {token}"}, None

    return {}, f"unsupported auth type {auth.get('type')!r}"


def get_json(url: str, headers: dict, accept: str | None = None):
    h = {**UA, **headers}
    if accept:
        h["Accept"] = accept
    req = urllib.request.Request(url, headers=h)
    with urlopen_retry(req) as r:
        return json.load(r)


def taxii_accept(feed: dict) -> str:
    return f"application/taxii+json;version={feed.get('taxii_version', '2.1')}"


def resolve_collection(feed: dict, headers: dict) -> str:
    """Find a collection id on the API root by title substring or exact id."""
    api_root = feed["url"].rstrip("/")
    data = get_json(f"{api_root}/collections/", headers, taxii_accept(feed))
    cols = data.get("collections", [])
    want = feed["collection"].lower()
    for c in cols:
        if c.get("id") == feed["collection"] or want in c.get("title", "").lower():
            return c["id"]
    known = ", ".join(f"{c.get('id')} ({c.get('title')})" for c in cols)
    raise RuntimeError(
        f"collection {feed['collection']!r} not found on {api_root}; available: {known}"
    )


def fetch_taxii(feed: dict, headers: dict) -> list:
    """Follow the TAXII objects endpoint across `more`/`next` pages."""
    if feed.get("collection"):
        cid = resolve_collection(feed, headers)
        url = f"{feed['url'].rstrip('/')}/collections/{cid}/objects/"
    else:
        url = feed["url"]

    if feed.get("limit"):
        url += ("&" if urllib.parse.urlparse(url).query else "?") + f"limit={feed['limit']}"

    objects = []
    while url:
        envelope = get_json(url, headers, taxii_accept(feed))
        objects += envelope.get("objects", [])
        nxt = envelope.get("next")
        url = (
            url
            + ("&" if urllib.parse.urlparse(url).query else "?")
            + "next="
            + urllib.parse.quote(str(nxt), safe="")
            if envelope.get("more") and nxt
            else None
        )
    return objects


def fetch_github_release(feed: dict, headers: dict) -> tuple[str, str, str]:
    """Return (tag, asset_name, download_url) for the matching latest-release asset."""
    api = f"https://api.github.com/repos/{feed['repo']}/releases/latest"
    rel = get_json(api, headers, accept="application/vnd.github+json")
    want = re.compile(feed["asset"])
    for a in rel.get("assets", []):
        if want.search(a["name"]):
            return rel["tag_name"], a["name"], a["browser_download_url"]
    known = ", ".join(a["name"] for a in rel.get("assets", []))
    raise RuntimeError(
        f"no asset matching /{feed['asset']}/ in {rel['tag_name']}; available: {known}"
    )


OCI_MANIFEST_MT = "application/vnd.oci.image.manifest.v1+json"


def fetch_oci_artifact(feed: dict, headers: dict, dest: Path) -> None:
    """Download an OCI artifact's first layer, verifying its digest."""
    registry = feed.get("registry", "ghcr.io")
    base = f"https://{registry}/v2/{feed['repo']}"
    man_url = f"{base}/manifests/{feed.get('tag', 'latest')}"
    h = {**UA, **headers, "Accept": OCI_MANIFEST_MT}
    auth: dict = {}
    try:
        req = urllib.request.Request(man_url, headers=h)
        manifest = json.loads(urlopen_retry(req).read())
    except urllib.error.HTTPError as e:
        if e.code != 401:
            raise
        # standard Bearer challenge: exchange at realm for an (anonymous) token
        p = dict(re.findall(r'(\w+)="([^"]*)"', e.headers["WWW-Authenticate"]))
        tok_url = p["realm"] + "?" + urllib.parse.urlencode(
            {k: p[k] for k in ("service", "scope") if k in p}
        )
        auth = {"Authorization": "Bearer " + get_json(tok_url, headers)["token"]}
        manifest = get_json(man_url, {**headers, **auth}, OCI_MANIFEST_MT)

    layer = manifest["layers"][0]
    req = urllib.request.Request(
        f"{base}/blobs/{layer['digest']}", headers={**UA, **headers, **auth}
    )
    part = dest.with_name(dest.name + ".part")
    digest = hashlib.sha256()
    try:
        with urlopen_retry(req) as r, open(part, "wb") as f:
            while chunk := r.read(1 << 20):
                digest.update(chunk)
                f.write(chunk)
        if digest.hexdigest() != layer["digest"].removeprefix("sha256:"):
            raise RuntimeError(f"layer digest mismatch for {layer['digest']}")
        part.rename(dest)
    except Exception:
        part.unlink(missing_ok=True)
        raise


def write_json(dest: Path, payload) -> None:
    part = dest.with_name(dest.name + ".part")
    part.write_text(json.dumps(payload))
    part.rename(dest)


def fetch_file(feed: dict, headers: dict, dest: Path) -> None:
    part = dest.with_name(dest.name + ".part")
    req = urllib.request.Request(feed["url"], headers={**UA, **headers})
    try:
        with urlopen_retry(req) as r, open(part, "wb") as f:
            while chunk := r.read(1 << 20):
                f.write(chunk)
        if dest.suffix == ".json":  # catches HTML error pages masquerading as JSON
            with open(part) as f:
                json.load(f)
        part.rename(dest)
    except Exception:
        part.unlink(missing_ok=True)
        raise


def run_feed(feed: dict, out: Path) -> str:
    name = feed.get("name", "?")
    if feed.get("enabled") is False:
        return f"SKIP {name}: disabled"
    headers, skip = auth_headers(feed)
    if skip:
        return f"SKIP {name}: {skip}"

    if feed.get("type") == "github-release-asset":
        tag, fname, url = fetch_github_release(feed, headers)
        rel = Path(feed.get("dest", f"github/{name}")) / fname
    else:
        rel = Path(feed.get("dest", f"taxii/{name}.json"))
        tag = url = None
    dest = out / rel
    if rel.is_absolute() or not dest.resolve().is_relative_to(out.resolve()):
        raise ValueError(f"unsafe dest {rel}")
    dest.parent.mkdir(parents=True, exist_ok=True)

    if feed.get("skip_if_exists") and dest.exists():
        return f"SKIP {name}: {rel} exists"

    if feed.get("type") == "github-release-asset":
        fetch_file({"url": url}, headers, dest)
        return f"OK   {name}: {tag} -> {rel}"

    if feed.get("type") == "oci-artifact":
        fetch_oci_artifact(feed, headers, dest)
        return f"OK   {name} -> {rel}"

    if feed.get("type") == "taxii":
        objects = fetch_taxii(feed, headers)
        write_json(dest, {"objects": objects})
        return f"OK   {name}: {len(objects)} object(s) -> {dest.relative_to(out)}"
    fetch_file(feed, headers, dest)
    return f"OK   {name} -> {dest.relative_to(out)}"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--config", default="files/feeds.json")
    ap.add_argument("--dest", default="dist/ear/feeds")
    ap.add_argument("names", nargs="*", help="limit to these feed names")
    args = ap.parse_args()

    feeds = json.loads(Path(args.config).read_text())["feeds"]
    out = Path(args.dest)
    out.mkdir(parents=True, exist_ok=True)

    failures = 0
    for feed in feeds:
        if args.names and feed.get("name") not in args.names:
            continue
        try:
            print(run_feed(feed, out), flush=True)
        except Exception as exc:  # noqa: BLE001 - one bad feed must not kill the rest
            print(f"FAIL {feed.get('name', '?')}: {exc}", file=sys.stderr, flush=True)
            failures += 1

    if failures:
        print(f"== done with {failures} failure(s)", file=sys.stderr)
        return 1
    print(f"== feeds mirrored into {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
