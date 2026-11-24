#!/usr/bin/env python3
"""Scan osquery package inventory for CVEs, centrally, via the trivy container.

Pipeline:
  1. pull the latest package rows per host from logs-osquery_manager.result-*
     (works best when the pack's queries run with "snapshot": true)
  2. emit one CycloneDX 1.5 SBOM per host (purl-mapped, distro-qualified)
  3. run `trivy sbom` per host in the trivy container (DB cache seeded from
     the mirrored feeds/trivy/*.tar.gz — never update inside the air-gap)
  4. write findings to vulns-default: _id = sha1(host+purl+cve), so re-scans
     are idempotent and only last_seen moves. Optionally decorate findings
     with cve.* fields via mget on a cvelist index (--enrich-index).

Requires: docker, python3, ES access, and the trivy cache seeded:
  mkdir -p /var/lib/vulnscan/trivy-cache/{db,java-db}
  curl -s <ear>/feeds/trivy/db.tar.gz      | tar -xz -C /var/lib/vulnscan/trivy-cache/db/
  curl -s <ear>/feeds/trivy/java-db.tar.gz | tar -xz -C /var/lib/vulnscan/trivy-cache/java-db/

Auth: --api-key / ES_API_KEY, or --user/--password / ES_USER+ES_PASSWORD.
TLS: --ca-cert PATH or --insecure.

Note: vulns-default is a plain index, not a data stream — findings are
updated in place by _id. Grant the vulns-* pattern in your ES roles.
"""

import argparse
import base64
import hashlib
import json
import os
import shutil
import ssl
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

FINDINGS_INDEX = "vulns-default"
OSQUERY_SOURCE = "logs-osquery_manager.result-*"

FINDINGS_MAPPING = {
    "mappings": {
        "properties": {
            "@timestamp": {"type": "date"},
            "host": {"properties": {
                "id": {"type": "keyword"}, "name": {"type": "keyword"},
                "os": {"properties": {"platform": {"type": "keyword"},
                                      "version": {"type": "keyword"}}}}},
            "package": {"properties": {
                "name": {"type": "keyword"}, "version": {"type": "keyword"},
                "type": {"type": "keyword"}, "purl": {"type": "keyword"}}},
            "vulnerability": {"properties": {
                "id": {"type": "keyword"}, "severity": {"type": "keyword"},
                "fix_version": {"type": "keyword"},
                "published_date": {"type": "date"},
                "first_seen": {"type": "date"}, "last_seen": {"type": "date"},
                "description": {"type": "text"}, "reference": {"type": "keyword"},
                "score": {"properties": {"base": {"type": "float"},
                                        "version": {"type": "keyword"}}}}},
            "cve": {"properties": {
                "kev": {"properties": {
                    "date_added": {"type": "date"}, "due_date": {"type": "date"},
                    "required_action": {"type": "text"},
                    "ransomware_use": {"type": "keyword"}}}}},
            "scan": {"properties": {"image": {"type": "keyword"}}},
        }
    }
}

NOW = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def distro_qual(platform: str, version: str) -> str | None:
    """host.os.* -> trivy distro purl qualifier, e.g. ubuntu-22.04 / rhel-9."""
    fam = {
        "ubuntu": "ubuntu", "debian": "debian", "rhel": "rhel", "centos": "rhel",
        "rocky": "rocky", "almalinux": "alma", "fedora": "fedora", "amzn": "amazon",
    }.get((platform or "").lower())
    if not fam or not version:
        return None
    major, _, minor = version.partition(".")
    if fam == "ubuntu":  # ubuntu distros are major.minor: ubuntu-22.04
        return f"ubuntu-{major}.{minor or '04'}"
    return f"{fam}-{major}"


def purl_esc(s: str) -> str:
    return urllib.parse.quote(s or "", safe="")


def to_purl(table: str, cols: dict, distro: str | None) -> str | None:
    name, ver = cols.get("name"), cols.get("version")
    if not name:
        return None
    n, v = purl_esc(name), purl_esc(ver or "")
    arch = f"&arch={purl_esc(cols['arch'])}" if cols.get("arch") else ""

    if table == "deb_packages":
        q = {"arch": cols["arch"]} if cols.get("arch") else {}
        if distro:
            q["distro"] = distro
        qs = "?" + urllib.parse.urlencode(q) if q else ""
        return f"pkg:deb/{distro.split('-')[0] if distro else 'debian'}/{n}@{v}{qs}"
    if table == "rpm_packages":
        epoch = f"&epoch={cols['epoch']}" if cols.get("epoch") not in (None, "(none)") else ""
        fam = distro.split("-")[0] if distro else "rhel"
        q = f"?distro={distro}" if distro else ""
        return f"pkg:rpm/{fam}/{n}@{v}{q}{epoch}{arch}"
    if table == "python_packages":
        return f"pkg:pypi/{purl_esc(name.lower())}@{v}"
    if table == "npm_packages":
        return f"pkg:npm/{n}@{v}"
    if table == "chocolatey_packages":
        return f"pkg:chocolatey/{n}@{v}"
    if table == "homebrew_packages":
        return f"pkg:brew/{n}@{v}"
    return f"pkg:generic/{n}@{v}"  # flatpak_packages, programs, anything else


TABLES = (
    "deb_packages", "rpm_packages", "python_packages", "npm_packages",
    "chocolatey_packages", "homebrew_packages", "flatpak_packages", "programs",
)


def request(ctx, url: str, headers: dict, data=None, method=None):
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    return urllib.request.urlopen(req, context=ctx, timeout=300)


def detect_table(osquery_name: str, tables: list) -> str | None:
    for t in sorted(tables, key=len, reverse=True):  # longest suffix wins
        if t in osquery_name:
            return t
    return None


def pull_inventory(ctx, es, headers, args) -> dict:
    """{(host_id): {"host": {...}, "pkgs": {purl: {name, version, table}}}}"""
    tables = args.tables or list(TABLES)
    body = {
        "size": 10000,
        "track_total_hits": True,
        "_source": ["@timestamp", "host", "osquery"],
        "sort": [{"@timestamp": "asc"}, {"_shard_doc": "asc"}],
        "query": {"bool": {"filter": [
            {"range": {"@timestamp": {"gte": f"now-{args.lookback}h"}}},
            {"exists": {"field": "osquery.columns"}},
        ]}},
    }
    hosts: dict = {}
    seen = 0
    search_after = None
    while True:
        if search_after:
            body["search_after"] = search_after
        resp = json.loads(request(
            ctx, f"{es}/{args.source}/_search", headers, json.dumps(body).encode()
        ).read())
        hits = resp["hits"]["hits"]
        if not hits:
            break
        for h in hits:
            seen += 1
            src = h["_source"]
            host = src.get("host", {})
            osq = src.get("osquery", {})
            table = detect_table(osq.get("name", ""), tables)
            cols = osq.get("columns") or {}
            if not table or not cols.get("name"):
                continue
            key = host.get("id") or host.get("name") or "unknown"
            if args.host and args.host not in (host.get("name"), host.get("id")):
                continue
            ctx_h = hosts.setdefault(key, {"host": host, "pkgs": {}})
            distro = distro_qual(host.get("os", {}).get("platform"),
                                 host.get("os", {}).get("version"))
            purl = to_purl(table, cols, distro)
            if not purl:
                continue
            if osq.get("action") == "removed":
                ctx_h["pkgs"].pop(purl, None)
            else:
                ctx_h["pkgs"][purl] = {
                    "name": cols["name"], "version": cols.get("version"),
                    "table": table, "ts": src.get("@timestamp"),
                }
        search_after = hits[-1]["sort"]
        if len(hits) < 10000:
            break
    print(f"inventory: {seen} result rows -> {len(hosts)} host(s)")
    return hosts


def write_sbom(host: dict, path: Path) -> None:
    os_fam = host["host"].get("os", {}).get("platform")
    os_ver = host["host"].get("os", {}).get("version")
    sbom = {
        "bomFormat": "CycloneDX", "specVersion": "1.5", "version": 1,
        "metadata": {
            "timestamp": NOW,
            "component": {"type": "operating-system", "name": os_fam or "linux",
                          "version": os_ver or ""},
        },
        "components": [
            {"bom-ref": purl, "type": "library", "name": p["name"],
             "version": p["version"], "purl": purl}
            for purl, p in host["pkgs"].items()
        ],
    }
    path.write_text(json.dumps(sbom))


def scan_host(args, key: str, host: dict, workdir: Path) -> list:
    """Run trivy on the host's SBOM; return finding docs."""
    safe = "".join(c if c.isalnum() else "-" for c in key)[:48]
    safe += "-" + hashlib.sha1(key.encode()).hexdigest()[:8]
    sbom = workdir / f"{safe}.json"
    write_sbom(host, sbom)
    if args.dry_run:
        return []
    cmd = [  # docker presence checked in main()
        "docker", "run", "--rm",
        "-e", "TRIVY_SKIP_DB_UPDATE=true", "-e", "TRIVY_SKIP_JAVA_DB_UPDATE=true",
        "-e", "TRIVY_DISABLE_VEX_NOTICE=true",
        "-v", f"{args.cache_dir}:/root/.cache/trivy",
        "-v", f"{workdir}:/work:ro",
        args.trivy_image,
        "sbom", "--format", "json", "--scanners", "vuln", "--quiet",
        f"/work/{sbom.name}",
    ]
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=1800)
    if out.returncode != 0:
        print(f"  FAIL trivy {key}: {out.stderr.strip()[:300]}", file=sys.stderr)
        return []
    report = json.loads(out.stdout or "{}")

    findings = []
    for res in report.get("Results", []):
        for v in res.get("Vulnerabilities") or []:
            purl = v.get("PkgIdentifier", {}).get("PURL") or ""
            doc = {
                "@timestamp": NOW,
                "host.id": host["host"].get("id"),
                "host.name": host["host"].get("name"),
                "host.os.platform": host["host"].get("os", {}).get("platform"),
                "host.os.version": host["host"].get("os", {}).get("version"),
                "package.name": v.get("PkgName"),
                "package.version": v.get("InstalledVersion"),
                "package.type": res.get("Class"),
                "package.purl": purl,
                "vulnerability.id": v.get("VulnerabilityID"),
                "vulnerability.severity": v.get("Severity"),
                "vulnerability.fix_version": v.get("FixedVersion") or None,
                "vulnerability.published_date": v.get("PublishedDate"),
                "vulnerability.last_seen": NOW,
                "scan.image": args.trivy_image,
            }
            did = hashlib.sha1(f"{key}|{purl}|{v['VulnerabilityID']}".encode()).hexdigest()
            findings.append((did, {k: x for k, x in doc.items() if x is not None}))
    print(f"  {key}: {len(host['pkgs'])} pkgs -> {len(findings)} findings")
    return findings


ENRICH_FIELDS = (
    "vulnerability.description", "vulnerability.score.base",
    "vulnerability.score.version", "vulnerability.severity",
    "vulnerability.reference",
)


def decorate(ctx, es, headers, findings: list, cvelist_index: str) -> None:
    """Attach cve.* fields to finding docs via mget on the cvelist index.

    cvelist docs use literal dot-notated keys ("vulnerability.id"), so fields
    are copied verbatim — no nested traversal.
    """
    ids = sorted({d["vulnerability.id"] for _, d in findings})
    enriched = {}
    for i in range(0, len(ids), 1000):
        resp = json.loads(request(
            ctx, f"{es}/{cvelist_index}/_mget", headers,
            json.dumps({"ids": ids[i:i + 1000]}).encode(),
        ).read())
        for d in resp["docs"]:
            if d.get("found"):
                enriched[d["_id"]] = d["_source"]
    n = 0
    for _, doc in findings:
        if cve := enriched.get(doc["vulnerability.id"]):
            for k in ENRICH_FIELDS:
                if cve.get(k) is not None:
                    doc[k] = cve[k]
            if cve.get("cve.kev"):
                doc["cve.kev"] = cve["cve.kev"]
            n += 1
    print(f"enriched {n}/{len(findings)} finding(s) from {cvelist_index}")


def ensure_index(ctx, es, headers, index: str) -> None:
    try:
        request(ctx, f"{es}/{index}", headers,
                data=json.dumps(FINDINGS_MAPPING).encode(), method="PUT").read()
        print(f"created {index}")
    except urllib.error.HTTPError as e:
        if e.code != 400:
            raise


def bulk_write(ctx, es, headers, index: str, findings: list) -> int:
    """Scripted upsert preserving vulnerability.first_seen."""
    lines = []
    for did, doc in findings:
        base = dict(doc)
        base.pop("vulnerability.first_seen", None)
        lines.append(json.dumps({"update": {"_id": did}}))
        lines.append(json.dumps({
            "script": {
                # _source holds literal dot-notated keys; bracket access required
                "source": "ctx._source.putAll(params.doc);"
                          "def fs = ctx._source['vulnerability.first_seen'];"
                          "ctx._source['vulnerability.first_seen'] ="
                          "  fs == null ? params.now : fs",
                "params": {"doc": base, "now": NOW},
            },
            "upsert": {**base, "vulnerability.first_seen": NOW},
        }))
    failed = 0
    for i in range(0, len(lines), 4000):
        resp = json.loads(request(
            ctx, f"{es}/{index}/_bulk", headers,
            ("\n".join(lines[i:i + 4000]) + "\n").encode(),
        ).read())
        if resp.get("errors"):
            failed += sum(1 for it in resp["items"] if it.get("update", {}).get("error"))
    return failed


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--es", required=True, help="elasticsearch base URL")
    ap.add_argument("--source", default=OSQUERY_SOURCE, help="inventory index pattern")
    ap.add_argument("--index", default=FINDINGS_INDEX, help="findings index")
    ap.add_argument("--lookback", type=int, default=36,
                    help="hours of osquery results to consider (>= pack interval)")
    ap.add_argument("--tables", nargs="+", help="osquery tables (default: all)")
    ap.add_argument("--host", help="limit to one host (name or id)")
    ap.add_argument("--trivy-image", default="aquasec/trivy:0.76.2")
    ap.add_argument("--cache-dir", default="/var/lib/vulnscan/trivy-cache",
                    help="host dir mounted as trivy's cache (seeded from feeds)")
    ap.add_argument("--parallel", type=int, default=4, help="concurrent trivy scans")
    ap.add_argument("--enrich-index", help="cvelist index to mget-decorate findings")
    ap.add_argument("--prune-days", type=int,
                    help="delete findings with last_seen older than N days")
    ap.add_argument("--dry-run", action="store_true",
                    help="write SBOMs to --workdir, don't scan or index")
    ap.add_argument("--workdir", type=Path, help="keep SBOMs here (default: temp)")
    ap.add_argument("--api-key", default=os.environ.get("ES_API_KEY"))
    ap.add_argument("--api-key-env", help="env var holding the API key")
    ap.add_argument("--user", default=os.environ.get("ES_USER"))
    ap.add_argument("--password", default=os.environ.get("ES_PASSWORD"))
    ap.add_argument("--ca-cert", type=Path)
    ap.add_argument("--insecure", action="store_true")
    args = ap.parse_args()

    es = args.es.rstrip("/")
    headers = {"User-Agent": "elastic-offline-installer/vulnscan",
               "Content-Type": "application/json"}
    key = args.api_key or os.environ.get(args.api_key_env or "", "")
    if key:
        headers["Authorization"] = f"ApiKey {key}"
    elif args.user is not None:
        headers["Authorization"] = "Basic " + base64.b64encode(
            f"{args.user}:{args.password or ''}".encode()).decode()
    ctx = ssl.create_default_context(cafile=args.ca_cert) if not args.insecure \
        else ssl._create_unverified_context()

    hosts = pull_inventory(ctx, es, headers, args)
    if not hosts:
        print("no inventory found in window", file=sys.stderr)
        return 1

    findings = []
    if args.dry_run:
        workdir = args.workdir or Path("vulnscan-sboms")
        workdir.mkdir(parents=True, exist_ok=True)
        for key, host in hosts.items():
            write_sbom(host, workdir / f"{key[:64]}.json")
        print(f"dry-run: wrote {len(hosts)} SBOM(s) to {workdir}")
        return 0

    if not shutil.which("docker"):
        sys.exit("error: docker not found — needed to run the trivy container")

    with tempfile.TemporaryDirectory() as td, \
            ThreadPoolExecutor(args.parallel) as pool:
        workdir = Path(td)
        for batch in pool.map(
            lambda kv: scan_host(args, kv[0], kv[1], workdir), hosts.items()
        ):
            findings += batch

    if not findings:
        print("no findings; nothing to index")
        return 0

    if args.enrich_index:
        decorate(ctx, es, headers, findings, args.enrich_index)

    ensure_index(ctx, es, headers, args.index)
    failed = bulk_write(ctx, es, headers, args.index, findings)
    print(f"== {len(findings)} findings -> {args.index} ({failed} failed)")

    if args.prune_days:
        q = {"query": {"range": {"vulnerability.last_seen":
             {"lt": f"now-{args.prune_days}d"}}}}
        resp = json.loads(request(
            ctx, f"{es}/{args.index}/_delete_by_query?conflicts=proceed",
            headers, json.dumps(q).encode(), method="POST").read())
        print(f"pruned {resp.get('deleted', 0)} stale finding(s)")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
