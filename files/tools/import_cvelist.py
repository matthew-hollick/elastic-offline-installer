#!/usr/bin/env python3
"""Import the mirrored CVE List V5 corpus into Elasticsearch.

Usage:
    python3 import_cvelist.py --es https://es:9200 --index cvelist-2026.11.24 \
        --alias cvelist /opt/ear/feeds/cve/2026-11-24_all_CVEs_at_midnight.zip.zip

CORPUS may be the nested release zip (contains cves.zip), an extracted
cves.zip, or a directory tree of CVE JSON 5.0 records.

Records are flattened to ECS-ish fields — vulnerability.id is the enrich
match key — plus a cve.* block. REJECTED records are skipped. Docs are
indexed with _id = CVE id, so re-runs are idempotent.

No ILM: this is a replaceable snapshot, not time-series data. Index into a
dated index, then flip the --alias (e.g. cvelist) to it — point enrich
policies and pipelines at the alias and refreshes are transparent.

Auth: --api-key / ES_API_KEY, or --user/--password / ES_USER+ES_PASSWORD.
TLS: --ca-cert PATH to trust the offline CA, or --insecure.

Example enrich policy once indexed:

    PUT _enrich/policy/cve-lookup
    {"match": {"indices": "cvelist", "match_field": "vulnerability.id",
      "enrich_fields": ["vulnerability.description", "vulnerability.score.base",
                        "vulnerability.severity", "cve.kev", "vulnerability.reference"]}}
"""

import argparse
import base64
import json
import os
import ssl
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

CVSS_KEYS = ("cvssV4_0", "cvssV3_1", "cvssV3_0", "cvssV2_0")

MAPPING = {
    "mappings": {
        "properties": {
            "@timestamp": {"type": "date"},
            "vulnerability": {
                "properties": {
                    "id": {"type": "keyword"},
                    "enumeration": {"type": "keyword"},
                    "title": {"type": "text"},
                    "description": {"type": "text"},
                    "published_date": {"type": "date"},
                    "reference": {"type": "keyword"},
                    "score": {
                        "properties": {
                            "base": {"type": "float"},
                            "version": {"type": "keyword"},
                        }
                    },
                    "severity": {"type": "keyword"},
                }
            },
            "cve": {
                "properties": {
                    "assigner": {"type": "keyword"},
                    "state": {"type": "keyword"},
                    "date_updated": {"type": "date"},
                    "cwe": {"type": "keyword"},
                    "cpes": {"type": "keyword"},
                    "affected": {
                        "properties": {
                            "vendor": {"type": "keyword"},
                            "product": {"type": "keyword"},
                        }
                    },
                    "kev": {
                        "properties": {
                            "date_added": {"type": "date"},
                            "due_date": {"type": "date"},
                            "required_action": {"type": "text"},
                            "ransomware_use": {"type": "keyword"},
                        }
                    },
                }
            },
        }
    }
}


def pick_cvss(containers: list) -> dict:
    """Best available CVSS metrics across cna+adp, highest version first."""
    for key in CVSS_KEYS:
        for c in containers:
            for m in c.get("metrics", []):
                if key in m:
                    v = m[key]
                    return {
                        "base": v.get("baseScore"),
                        "version": key.removeprefix("cvssV").replace("_", "."),
                        "severity": v.get("baseSeverity") or v.get("severity"),
                    }
    return {}


def to_doc(rec: dict) -> dict | None:
    meta = rec.get("cveMetadata", {})
    if meta.get("state") != "PUBLISHED":  # REJECTED/RESERVED carry no content
        return None

    containers = rec.get("containers", {})
    cna = containers.get("cna", {})
    adp = containers.get("adp", [])

    def first(c):
        return next(
            (d["value"] for d in c.get("descriptions", []) if d.get("lang") == "en"),
            None,
        )

    kev = None
    for a in adp:
        if a.get("providerMetadata", {}).get("shortName") == "CISA-ADP":
            for m in a.get("metrics", []):
                if m.get("other", {}).get("type") == "kev":
                    c = m["other"].get("content", {})
                    kev = {
                        "date_added": c.get("dateAdded"),
                        "due_date": c.get("dueDate"),
                        "required_action": c.get("requiredAction"),
                        "ransomware_use": c.get("knownRansomwareCampaignUse"),
                    }

    affected = cna.get("affected", [])
    score = pick_cvss([cna, *adp])
    doc = {
        "@timestamp": meta.get("dateUpdated") or meta.get("datePublished"),
        "vulnerability.id": meta.get("cveId"),
        "vulnerability.enumeration": "CVE",
        "vulnerability.title": cna.get("title"),
        "vulnerability.description": first(cna),
        "vulnerability.published_date": meta.get("datePublished"),
        "vulnerability.reference": [
            r["url"] for r in cna.get("references", []) if r.get("url")
        ]
        or None,
        "vulnerability.score.base": score.get("base"),
        "vulnerability.score.version": score.get("version"),
        "vulnerability.severity": score.get("severity"),
        "cve.assigner": meta.get("assignerShortName"),
        "cve.state": meta.get("state"),
        "cve.date_updated": meta.get("dateUpdated"),
        "cve.cwe": sorted(
            {
                d["cweId"]
                for pt in cna.get("problemTypes", [])
                for d in pt.get("descriptions", [])
                if d.get("cweId")
            }
        )
        or None,
        "cve.cpes": sorted({c for a in affected for c in a.get("cpes", [])}) or None,
        "cve.affected.vendor": sorted(
            {a["vendor"] for a in affected if a.get("vendor")}
        )
        or None,
        "cve.affected.product": sorted(
            {a["product"] for a in affected if a.get("product")}
        )
        or None,
        "cve.kev": kev,
    }
    return {k: v for k, v in doc.items() if v is not None}


def corpus_entries(path: Path, scratch: tempfile.TemporaryDirectory):
    """Yield (name, bytes) for every CVE record in a zip, nested zip, or dir."""
    if path.is_dir():
        for f in sorted(path.rglob("*.json")):
            yield f.name, f.read_bytes()
        return
    zf = zipfile.ZipFile(path)
    names = zf.namelist()
    inner = [n for n in names if n.endswith("cves.zip")]
    if inner and not any(n.endswith(".json") for n in names):  # nested release zip
        scratch_file = Path(scratch.name) / "cves.zip"
        with zf.open(inner[0]) as src, open(scratch_file, "wb") as dst:
            while chunk := src.read(1 << 20):
                dst.write(chunk)
        zf = zipfile.ZipFile(scratch_file)
        names = zf.namelist()
    for n in names:
        if n.endswith(".json"):
            yield Path(n).name, zf.read(n)


def request(ctx, url: str, headers: dict, data=None, method=None):
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    return urllib.request.urlopen(req, context=ctx, timeout=120)


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("corpus", type=Path, help="release zip, cves.zip, or dir of .json")
    ap.add_argument("--es", required=True, help="elasticsearch base URL")
    ap.add_argument("--index", required=True, help="target index, e.g. cvelist-2026.11.24")
    ap.add_argument("--alias", help="flip this alias to the new index after import")
    ap.add_argument("--prune", action="store_true",
                    help="delete indices previously behind --alias (with --alias)")
    ap.add_argument("--recreate", action="store_true", help="delete target index first")
    ap.add_argument("--chunk", type=int, default=2000, help="docs per _bulk request")
    ap.add_argument("--api-key", default=os.environ.get("ES_API_KEY"))
    ap.add_argument("--api-key-env", help="env var holding the API key")
    ap.add_argument("--user", default=os.environ.get("ES_USER"))
    ap.add_argument("--password", default=os.environ.get("ES_PASSWORD"))
    ap.add_argument("--ca-cert", type=Path, help="CA bundle to verify the ES TLS cert")
    ap.add_argument("--insecure", action="store_true", help="skip TLS verification")
    args = ap.parse_args()

    es = args.es.rstrip("/")
    headers = {"User-Agent": "elastic-offline-installer/import_cvelist"}
    key = args.api_key or os.environ.get(args.api_key_env or "", "")
    if key:
        headers["Authorization"] = f"ApiKey {key}"
    elif args.user is not None:
        headers["Authorization"] = "Basic " + base64.b64encode(
            f"{args.user}:{args.password or ''}".encode()
        ).decode()

    ctx = ssl.create_default_context(cafile=args.ca_cert) if not args.insecure \
        else ssl._create_unverified_context()

    if args.recreate:
        try:
            request(ctx, f"{es}/{args.index}", headers, method="DELETE").read()
            print(f"deleted {args.index}")
        except urllib.error.HTTPError as e:
            if e.code != 404:
                raise
    try:
        request(
            ctx, f"{es}/{args.index}", headers,
            data=json.dumps(MAPPING).encode(), method="PUT",
        ).read()
        print(f"created {args.index} with cvelist mapping")
    except urllib.error.HTTPError as e:
        if e.code != 400:  # resource_already_exists
            raise
        print(f"index {args.index} exists; indexing into it")

    headers["Content-Type"] = "application/x-ndjson"
    buf: list[str] = []
    n_docs = n_skip = n_failed = 0

    def flush():
        nonlocal buf, n_failed
        body = ("\n".join(buf) + "\n").encode()
        buf = []
        resp = json.loads(request(ctx, f"{es}/{args.index}/_bulk", headers, body).read())
        if resp.get("errors"):
            errs = [i["index"]["error"]["reason"] for i in resp["items"]
                    if i.get("index", {}).get("error")]
            n_failed += len(errs)
            print(f"  {len(errs)} bulk error(s), first: {errs[0]}", file=sys.stderr)

    with tempfile.TemporaryDirectory() as td:
        scratch = tempfile.TemporaryDirectory(dir=td)
        for fname, blob in corpus_entries(args.corpus, scratch):
            try:
                doc = to_doc(json.loads(blob))
            except (json.JSONDecodeError, KeyError) as e:
                print(f"  warn: skipping unparseable {fname}: {e}", file=sys.stderr)
                continue
            if doc is None:
                n_skip += 1
                continue
            buf.append(json.dumps({"index": {"_id": doc["vulnerability.id"]}}))
            buf.append(json.dumps(doc))
            n_docs += 1
            if len(buf) >= args.chunk * 2:
                flush()
                if n_docs % 20000 < args.chunk:
                    print(f"  ...{n_docs} indexed")
        if buf:
            flush()

    print(f"== indexed {n_docs} CVEs into {args.index}"
          f" ({n_skip} non-PUBLISHED skipped, {n_failed} failed)")
    if n_failed:
        return 1

    if args.alias:
        old = []
        try:
            resp = json.loads(request(ctx, f"{es}/_alias/{args.alias}", headers).read())
            old = [i for i in resp if i != args.index]
        except urllib.error.HTTPError as e:
            if e.code != 404:
                raise
        actions = [{"add": {"index": args.index, "alias": args.alias}}]
        if old:
            actions.insert(0, {"remove": {"indices": old, "alias": args.alias}})
        request(ctx, f"{es}/_aliases", headers,
                data=json.dumps({"actions": actions}).encode(), method="POST").read()
        print(f"alias {args.alias} -> {args.index}"
              + (f" (was: {', '.join(old)})" if old else ""))
        if args.prune:
            for i in old:
                request(ctx, f"{es}/{i}", headers, method="DELETE").read()
                print(f"pruned {i}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
