A project to download Elasticsearch components for deployment to an offline environment

Latest version of the Elastic stack is 9.5.7

Reference: https://www.elastic.co/docs/deploy-manage/deploy/self-managed/air-gapped-install
(see also: [Fleet air-gapped deployment](https://www.elastic.co/docs/reference/fleet/air-gapped))

Elasticsearch is deployed on Ubuntu VMs ([deb install docs](https://www.elastic.co/docs/deploy-manage/deploy/self-managed/install-elasticsearch-with-debian-package)).

This laptop is arm but our production servers are amd64. we need to be able to define which platform to target.

We need to build out an EAR (Elastic Artifact Registry) for hosting on a webserver. `dist/ear/` mirrors the upstream URI space 1:1 — `dist/ear/downloads/` is a mirror of `artifacts.elastic.co/downloads/`, so it can be pointed to directly as the Fleet "agent binary download source" (see [Fleet air-gapped docs](https://www.elastic.co/docs/reference/fleet/air-gapped) — the layout there is what this mirrors):

- `downloads/` — .deb files for elasticsearch, kibana, elastic-agent, logstash
- `downloads/` — linux tar.gz and windows zip for all agent-downloadable components: elastic-agent, [fleet-server](https://www.elastic.co/docs/reference/fleet/fleet-server), apm-server, auditbeat, filebeat, heartbeat, metricbeat, osquerybeat, packetbeat, cloudbeat (linux only), endpoint-security (Elastic Defend binaries), winlogbeat (windows only)
- every artifact accompanied by its .sha512 checksum and .asc signature
- `downloads/endpoint/` — **Elastic Defend client-side detection artifacts** (malware signatures, behavioral models, trust/blocklists — the "fingerprints" the endpoint agent updates continuously; *not* the Kibana/ES SIEM rules). Mirrored from `artifacts.security.elastic.co/downloads/endpoint/` per the [offline endpoints guide](https://www.elastic.co/docs/solutions/security/configure-elastic-defend/configure-offline-endpoints-air-gapped-environments): `manifest/artifacts-<stack>.zip` + content-addressed blobs (filename = sha256, verified at download)
- [`GPG-KEY-elasticsearch`](https://artifacts.elastic.co/GPG-KEY-elasticsearch) at the webroot so .asc signatures can be verified offline
- `geoip/` — GeoLite2 .tgz databases + a rewritten `database.json` manifest for `ingest.geoip.downloader.endpoint` ([ingest/geoip settings](https://www.elastic.co/docs/reference/elasticsearch/configuration-reference/ingest-settings), [geoip processor](https://www.elastic.co/docs/reference/enrich-processor/geoip-processor)) — many integrations' geoip/enrich pipelines fail silently without this
- `models/` — ML trained-model artifacts (opt-in, big): `task download:models` with `ML_MODELS` defaulting to `elser_model_2_linux-x86_64` (275 MB). Available: `elser_model_2` (438 MB, cross-platform), `multilingual-e5-small[_linux-x86_64]` (423–482 MB), `rerank-v1` (777 MB). See [ELSER](https://www.elastic.co/docs/explore-analyze/machine-learning/nlp/ml-nlp-elser) (incl. the air-gapped deployment section) and [ML settings](https://www.elastic.co/docs/reference/elasticsearch/configuration-reference/machine-learning-settings)
- `feeds/` — third-party runtime feeds mirrored by `task download:feeds` (config: `files/feeds.json`, see [Feeds](#feeds) below): `feeds/cisa/known_exploited_vulnerabilities.json` for the [CISA KEVs integration](https://www.elastic.co/docs/reference/integrations/cisa_kevs), and `feeds/taxii/<name>.json` — TAXII 2.x collections flattened to `{"objects": [...]}` for [ti_custom](https://www.elastic.co/docs/reference/integrations/ti_custom). All snapshots — refresh by re-running and redeploying

We need to build an EPR (Elastic Package Registry — [source](https://github.com/elastic/package-registry))
- Consider https://github.com/elastic/custom-epr-builder but I want to run outside of Docker so that I can easilly add new integrations as they become available.
- Latest version of the Elastic Package Registry binary for linux
- A systemd service definition
- Packages come from https://epr.elastic.co — the [Elastic integrations catalog](https://www.elastic.co/docs/reference/integrations)

There are additional containers that we need to bring with us:
- Elastic Agent (also covers containerised [Fleet Server](https://www.elastic.co/docs/reference/fleet/fleet-server) — there is no separate fleet-server image)
- [Logstash](https://www.elastic.co/docs/reference/logstash)
- Elastic Maps Server (`elastic-maps-server-ubi`, for [offline Kibana maps](https://www.elastic.co/guide/en/kibana/current/maps-connect-to-ems.html))
- Prometheus exporter for SNMP
- [trivy](https://github.com/aquasecurity/trivy) `aquasec/trivy` — offline vulnerability/misconfig scanner; pair with the mirrored DBs under `feeds/trivy/`
- [checkov](https://github.com/bridgecrewio/checkov) `bridgecrew/checkov` — IaC/policy scanner; **self-contained** — checks ship inside the image, there is no runtime "DB" to mirror (custom policies travel as your own repo; aux binaries like kustomize/helm/kubectl are only needed if you scan those framework types)
- [kube-state-metrics](https://github.com/kubernetes/kube-state-metrics) `registry.k8s.io/kube-state-metrics/kube-state-metrics` — exposes K8s object state as metrics for the agent's kubernetes integration
- [GitLab Runner](https://docs.gitlab.com/runner/) `gitlab/gitlab-runner:ubuntu-*` — for executing CI pipelines on the disconnected side
- [Cinc Auditor](https://cinc.sh/) `cincproject/auditor` — the open-source build of Chef InSpec, for compliance scanning on the disconnected side
- [venom](https://github.com/ovh/venom) `ovhcom/venom` — OVH's integration-test runner (HTTP/exec/DB assertions from yaml testcases)
- [skopeo](https://github.com/containers/skopeo) + [buildah](https://github.com/containers/buildah) tool images, so the toolchain works offline too

Plus tools in `dist/tools/`:
- `diagnostics-<ver>-dist.zip` — Elastic's [support-diagnostics](https://github.com/elastic/support-diagnostics) tool, for capturing full platform state when Elastic Support asks
- a [Temurin JRE](https://adoptium.net/) tarball — support-diagnostics is a Java tool; needed on hosts without a JDK (ES nodes have one bundled at `$ES_HOME/jdk`)
- [`elastic-package`](https://github.com/elastic/elastic-package) (linux/amd64) — for building custom integrations on the offline side ([package-spec](https://github.com/elastic/package-spec))
- `import_cvelist.py` — bulk-loads the mirrored cvelistV5 corpus into an ES index as ECS `vulnerability.*` docs (see [Feeds](#feeds); run with `--help` for options incl. the enrich-policy example)
- `vulnscan.py` + `vulnscan.service`/`.timer` — centrally scans osquery package inventory with the trivy container and writes findings to `vulns-default` (see [Vulnerability scanning](#vulnerability-scanning))
- `push_containers.sh` — loads every `dist/containers/*.tar.gz` on a docker host and pushes them to a Harbor registry, preserving upstream repo paths under your project (`docker.elastic.co/elastic-agent/elastic-agent:9.5.7` → `harbor.local/<project>/elastic-agent/elastic-agent:9.5.7`)

## Building the bundle

Requires [mise](https://mise.jdx.dev) and [Task](https://taskfile.dev). From a clean checkout:

```bash
mise install                          # one-time: go, task, python
task all                              # download + build + package -> elastic-offline-bundle-<version>.tar.gz
```

Or run the stages individually:

```bash
task download                         # EAR artifacts + integrations + containers + webserver + tools + feeds
task build                            # compiles package-registry (EPR)
task build:integration -- https://github.com/FortytwoM/elastic-nessus-integration nessus
task package                          # verify checksums + tar dist/ -> elastic-offline-bundle-<version>.tar.gz
```

`task check:versions` compares the pinned `Taskfile.yaml` vars against upstream latest releases and exits non-zero if anything is behind — worth running before a bundle refresh. `latest`-pinned vars (caddy, diagnostics, EPR) report what they'd resolve to.

`KIBANA_CONSTRAINT='^8.13.0 || ^9.0.0'` can be set before `build:integration` to relax a package's declared `conditions.kibana.version` (see [package-spec conditions](https://github.com/elastic/package-spec)).

## Feeds

`task download:feeds` mirrors third-party runtime feeds into `dist/ear/feeds/` so repointable integrations work air-gapped. Config is `files/feeds.json`; each entry has `name`, `type`, `url`, optional `dest` (relative to `feeds/`), `enabled`, `description` and `auth`.

- `type: "file"` — downloads `url` verbatim to `dest` (e.g. CISA KEV). `.json` dests are validated as JSON.
- `type: "taxii"` — pulls a TAXII 2.x collection: `url` is the API root and `collection` a title substring (or exact collection `id`); alternatively `url` may point straight at a `.../collections/<id>/objects/` endpoint. All pages are followed via the `more`/`next` envelope and flattened to `{"objects": [...]}` at `dest` (default `taxii/<name>.json`). `taxii_version` defaults to `2.1` (the Accept header version; use `2.0` for older servers); `limit` sets the TAXII page-size param.
- `type: "github-release-asset"` — resolves `releases/latest` of `repo` and downloads the first asset whose name matches the `asset` regex (for assets whose names embed the release date). `dest` is a directory; the remote filename is kept.
- `type: "oci-artifact"` — pulls the first layer of an OCI artifact (`registry`/`repo`/`tag`) through the standard anonymous Bearer-token flow and verifies the layer digest. For tools whose database ships as a registry artifact, not a file — e.g. `trivy-db:2`.

`"skip_if_exists": true` on any feed skips it when the destination file already exists — useful for large date-versioned files.

Auth is per-feed and env-gated — **a feed whose referenced env var is unset is skipped, not failed**, so key-gated feeds can stay in the config and only download once the key is exported:

```json
"auth": { "type": "header", "env": "MY_FEED_KEY", "header": "Authorization", "prefix": "Bearer " }
"auth": { "type": "basic", "username": "guest", "password": "guest" }
"auth": { "type": "basic", "username_env": "FEED_USER", "password_env": "FEED_PASS" }
```

The shipped config enables the CISA KEV file, the CVE List V5 baseline and the two trivy DBs; abuse.ch URLhaus + ThreatFox via [Anomali Limo](https://limo.anomali.com/) (free TAXII 2.x, guest/guest, no registration), MITRE ATT&CK, an OpenCTI collection, and a keyed template ship `enabled: false` — flip to `true` for servers your network can reach.

**OpenCTI**: point `url` at your instance's `/taxii2/root` API root and `collection` at the collection's name or UUID (create one under *Data → Data sharing → TAXII Collections*, filtered however you like — e.g. indicators with score ≥ n). Export `OPENCTI_TOKEN` (a profile API key, sent as `Authorization: Bearer`). This is the recommended aggregation pattern: OpenCTI ingests whatever upstream feeds you subscribe to on the connected side, you curate one collection, and this task mirrors it. Note the `ti_opencti` integration itself is **not** mirrorable — it polls OpenCTI's GraphQL API with cursor-paginated queries and needs a live instance.

**CVE List V5** (`cvelistv5`, ~700 MB): mirrors the nightly `*_all_CVEs_at_midnight.zip.zip` release asset into `feeds/cve/` — the dated filename is its own freshness key, so same-day re-runs skip (`skip_if_exists`). It unzips to a `cves.zip` of one CVE JSON 5.0 record per file. Ways to use it offline:

- **Bulk-index into ES** — `dist/tools/import_cvelist.py` streams the nested zip and bulk-indexes one flattened doc per record (`_id` = CVE id, ECS `vulnerability.*` fields + `cve.*` extras; REJECTED records skipped) into a dated index, then flips an alias. Gives a searchable CVE corpus: descriptions, references, CVSS/CWE, and CISA ADP containers which carry KEV status + SSVC scores (partially redundant with the KEV feed). Example: `python3 import_cvelist.py --es https://es:9200 --index cvelist-2026.11.24 --alias cvelist --ca-cert ca.crt /opt/ear/feeds/cve/2026-11-24_all_CVEs_at_midnight.zip.zip`
- **`enrich` processor** — a `match` enrich policy on the `cvelist` alias keyed by `vulnerability.id` decorates vulnerability findings from scanner integrations (Tenable/Qualys/Wazuh emit `vulnerability.id`) with full CVE metadata at ingest time — the policy example is in `import_cvelist.py --help`.
- **Local tooling** — serve the zip as-is for hosts that consume a CVE JSON5 mirror directly.

`ti_custom` isn't a fit here: CVE records aren't STIX indicator objects, and indicator-match rules don't consume `vulnerability` docs.

**trivy databases** (`feeds/trivy/`): `db.tar.gz` is the `trivy-db:2` layer (`trivy.db` + `metadata.json`, ~140 MB); `java-db.tar.gz` is `trivy-java-db:1` (the GAV→vulnerability index, ~960 MB — needed for jar/pom scans). On each scanner host, seed trivy's cache:

```bash
mkdir -p ~/.cache/trivy/{db,java-db}
curl -s <scheme>://<ear-fqdn>/feeds/trivy/db.tar.gz | tar -xz -C ~/.cache/trivy/db/
curl -s <scheme>://<ear-fqdn>/feeds/trivy/java-db.tar.gz | tar -xz -C ~/.cache/trivy/java-db/
TRIVY_SKIP_DB_UPDATE=true TRIVY_SKIP_JAVA_DB_UPDATE=true trivy fs /path/to/target
```

trivy then runs fully offline. The DBs refresh on every `task download:feeds` (content varies daily; the fixed names mean they always overwrite).

### Vulnerability scanning

`vulnscan.py` turns osquery package inventory into CVE findings **centrally** — no per-host scanner needed:

1. pulls the latest package rows per host from `logs-osquery_manager.result-*` (works best when pack queries run `"snapshot": true`; `--lookback` should exceed your pack interval, default 36h)
2. emits a CycloneDX SBOM per host — purls carry `distro`/`arch` qualifiers (`pkg:deb/ubuntu/libssl3@…?arch=amd64&distro=ubuntu-22.04`) so trivy matches OS packages correctly
3. runs `trivy sbom` per host in the trivy container (`--parallel`), DB from the seeded cache — never updates inside the air-gap
4. writes findings to **`vulns-default`** (plain index, not a data stream — docs update in place): `_id = sha1(host+purl+cve)` makes re-scans idempotent; `vulnerability.first_seen`/`last_seen` track lifecycle; `--prune-days` drops resolved findings
5. `--enrich-index cvelist` decorates findings in bulk via mget — description, CVSS, KEV status baked into each doc

Covered tables: `deb_packages`, `rpm_packages`, `python_packages`, `npm_packages` (full distro/lang matching); `chocolatey_packages`, `homebrew_packages`, `flatpak_packages`, `programs` map to generic purls with sparse trivy coverage. Windows KB patching isn't covered.

Deploy on any docker host (not a data node):

```bash
install -m 0755 dist/tools/vulnscan.py /opt/tools/
install -m 0644 dist/tools/vulnscan.{service,timer} /etc/systemd/system/
# /etc/default/vulnscan — see the unit file comments
systemctl enable --now vulnscan.timer
```

Remember to grant the `vulns-*` pattern in your ES roles — analysts' `logs-*` grants won't cover it.

### Serving to ti_custom

The [ti_custom integration](https://www.elastic.co/docs/reference/integrations/ti_custom) ingests STIX indicators via a CEL input that GETs `url`, decodes the JSON body and maps `body.objects[]` into events — exactly the shape `download:feeds` writes. Configure the integration:

- `url` → `<scheme>://<ear-fqdn>/feeds/taxii/<name>.json`
- `enable_taxii` → leave on, but **leave `initial_interval` empty** — when set, the TAXII program appends `/?added_after=...` to the URL, which 404s on a static file. Without it the agent re-fetches the whole file each `interval` (a full snapshot per poll — correct for a static mirror).
- `restrict_stix` → keep `true` (non-STIX-2.1 objects are dropped upstream of ingest anyway).
- `feed_name`, `ioc_expiration_duration` → as desired.

The resulting indicators land in `logs-ti_custom.*` and feed [indicator-match rules](https://www.elastic.co/docs/solutions/security/detect-and-alert/indicator-match). Feeds are point-in-time snapshots — no delta updates; re-run `task download:feeds` and redeploy the bundle to refresh.

Alternative: `ti_custom` also has a `filestream` input that reads a STIX bundle/JSON file placed directly on the agent host — no EAR dependency, but you distribute the file yourself.

- `rsync -a dist/ear/ /opt/ear/` — EAR webroot contents (mind the trailing slash: the Caddy root is `/opt/ear` itself), served by [Caddy](https://caddyserver.com/docs/) with [`file_server`](https://caddyserver.com/docs/caddyfile/directives/file_server)
- `rsync -a dist/web/ /opt/ear-web/` — Caddy binary + `Caddyfile` + `ear.service` (create the `caddy` user per the unit comments; edit the hostname in `Caddyfile` to match the cert SAN)
- TLS certificates are issued inside the offline environment — install them at deploy time: `cat server.crt ca-chain.pem > /opt/ear-web/tls/cert.pem` and `key.pem` alongside (0600, owned by `caddy`). Caddy [`tls` directive](https://caddyserver.com/docs/caddyfile/directives/tls) for details.
- `rsync -a dist/epr/ /opt/epr/` — package-registry binary + `config.yml` + `epr.service` + `packages/` (create the `epr` user). Point Fleet at it via [`xpack.fleet.registryUrl`/`registryUrl` in kibana.yml](https://www.elastic.co/docs/reference/kibana/configuration-reference/fleet-settings)
- `dist/containers/elastic-epr-<version>.tar.gz` — alternative EPR deployment as a container (Elastic's recommended "distribution" image: registry + all packages baked in): `gunzip -c elastic-epr-<version>.tar.gz | docker load` then run with the registry port published (see the podman/systemd example in [Elastic's air-gapped docs](https://www.elastic.co/docs/reference/fleet/air-gapped))
- `dist/containers/` -> `gunzip -c <file>.tar.gz | docker load`, or push them all to a registry in one pass: `HARBOR=harbor.local HARBOR_PROJECT=elastic dist/tools/push_containers.sh` (dry-run with `-n`)
- Fleet agent binary download source: `<scheme>://<ear-fqdn>/downloads/` (trailing slash matters — agents append `beats/...` to it)
- Elastic Defend: in each Defend integration policy's advanced settings, set `advanced.artifacts.global.base_url` (and its `<os>.advanced.artifacts.global.base_url` variants) to `<scheme>://<ear-fqdn>` — agents then fetch `/downloads/endpoint/...` for detection signatures/models (see [offline endpoints guide](https://www.elastic.co/docs/solutions/security/configure-elastic-defend/configure-offline-endpoints-air-gapped-environments)). The `ETag` header is mandatory for artifact updates; Caddy's `file_server` sends it by default.
- CISA KEVs integration: set the `url` variable to `<scheme>://<ear-fqdn>/feeds/cisa/known_exploited_vulnerabilities.json` (the `url` var is exposed in the [integration's configuration](https://www.elastic.co/docs/reference/integrations/cisa_kevs)); note the mirrored file is a point-in-time snapshot
- ti_custom integration (mirrored TAXII feeds): set `url` to `<scheme>://<ear-fqdn>/feeds/taxii/<name>.json` and leave `initial_interval` empty — see [Feeds](#serving-to-ti_custom)
- GeoIP: `sed -i 's|__EAR_BASE_URL__|https://<ear-fqdn>|' /opt/ear/geoip/database.json`, then set `ingest.geoip.downloader.endpoint: https://<ear-fqdn>/geoip/database.json` in `elasticsearch.yml` ([ingest settings](https://www.elastic.co/docs/reference/elasticsearch/configuration-reference/ingest-settings)). Use the `http://` scheme if ES nodes don't trust the EAR's CA
- ML models (if `download:models` was run): set `xpack.ml.model_repository: <scheme>://<ear-fqdn>/models/` in `elasticsearch.yml` ([ML settings](https://www.elastic.co/docs/reference/elasticsearch/configuration-reference/machine-learning-settings)) — Kibana's Trained Models page then "downloads" ELSER/e5/rerank from the EAR. Alternative: copy the model files into `$ES_HOME/config/models/` on all master-eligible nodes and point `xpack.ml.model_repository` at `file://${path.home}/config/models/` — both described in the [ELSER air-gapped section](https://www.elastic.co/docs/explore-analyze/machine-learning/nlp/ml-nlp-elser)

Note on TLS and agents: Elastic Agent cannot pin trust for artifact downloads — either install the CA into each host's system trust store and use `https://`, or point agent binary sources at the `http://` endpoint (both are served). See [Fleet air-gapped docs](https://www.elastic.co/docs/reference/fleet/air-gapped).
