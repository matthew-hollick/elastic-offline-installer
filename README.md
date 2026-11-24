A project to download Elasticsearch components for deployment to an offline environment

Latest version of the Elastic stack is 9.5.7

Reference: https://www.elastic.co/docs/deploy-manage/deploy/self-managed/air-gapped-install
(see also: [Fleet air-gapped deployment](https://www.elastic.co/docs/reference/fleet/air-gapped))

Elasticsearch is deployed on Ubuntu VMs ([deb install docs](https://www.elastic.co/docs/deploy-manage/deploy/self-managed/install-elasticsearch-with-debian-package)).

This laptop is arm but our production servers are amd64. we need to be able to define which platform to target.

We need to build out an EAR (Elastic Artifact Registry) for hosting on a webserver. The directory layout mirrors https://artifacts.elastic.co/downloads/ so it can be pointed to directly as the Fleet "agent binary download source" and the Endpoint artifact repository (see [Fleet air-gapped docs](https://www.elastic.co/docs/reference/fleet/air-gapped) — the layout there is what this mirrors):

- .deb files for elasticsearch, kibana, elastic-agent, logstash
- linux tar.gz and windows zip for all agent-downloadable components: elastic-agent, [fleet-server](https://www.elastic.co/docs/reference/fleet/fleet-server), apm-server, auditbeat, filebeat, heartbeat, metricbeat, osquerybeat, packetbeat, cloudbeat (linux only), endpoint-security (Elastic Defend), winlogbeat (windows only)
- every artifact accompanied by its .sha512 checksum and .asc signature
- [`GPG-KEY-elasticsearch`](https://artifacts.elastic.co/GPG-KEY-elasticsearch) at the webroot so .asc signatures can be verified offline
- `geoip/` — GeoLite2 .tgz databases + a rewritten `database.json` manifest for `ingest.geoip.downloader.endpoint` ([ingest/geoip settings](https://www.elastic.co/docs/reference/elasticsearch/configuration-reference/ingest-settings), [geoip processor](https://www.elastic.co/docs/reference/enrich-processor/geoip-processor)) — many integrations' geoip/enrich pipelines fail silently without this
- `models/` — ML trained-model artifacts (opt-in, big): `task download:models` with `ML_MODELS` defaulting to `elser_model_2_linux-x86_64` (275 MB). Available: `elser_model_2` (438 MB, cross-platform), `multilingual-e5-small[_linux-x86_64]` (423–482 MB), `rerank-v1` (777 MB). See [ELSER](https://www.elastic.co/docs/explore-analyze/machine-learning/nlp/ml-nlp-elser) (incl. the air-gapped deployment section) and [ML settings](https://www.elastic.co/docs/reference/elasticsearch/configuration-reference/machine-learning-settings)

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
- [skopeo](https://github.com/containers/skopeo) + [buildah](https://github.com/containers/buildah) tool images, so the toolchain works offline too

Plus tools in `dist/tools/`:
- `diagnostics-<ver>-dist.zip` — Elastic's [support-diagnostics](https://github.com/elastic/support-diagnostics) tool, for capturing full platform state when Elastic Support asks
- a [Temurin JRE](https://adoptium.net/) tarball — support-diagnostics is a Java tool; needed on hosts without a JDK (ES nodes have one bundled at `$ES_HOME/jdk`)
- [`elastic-package`](https://github.com/elastic/elastic-package) (linux/amd64) — for building custom integrations on the offline side ([package-spec](https://github.com/elastic/package-spec))

## Building the bundle

Requires [mise](https://mise.jdx.dev) and [Task](https://taskfile.dev). From a clean checkout:

```bash
mise install                          # one-time: go, task, python

task download                         # EAR artifacts + integrations + containers + webserver
task build                            # compiles package-registry (EPR)
task build:integration -- https://github.com/FortytwoM/elastic-nessus-integration nessus
task package                          # verify checksums + tar dist/ -> elastic-offline-bundle-<version>.tar.gz
```

`KIBANA_CONSTRAINT='^8.13.0 || ^9.0.0'` can be set before `build:integration` to relax a package's declared `conditions.kibana.version` (see [package-spec conditions](https://github.com/elastic/package-spec)).

## Deploying (offline side)

- `dist/ear/` -> `/opt/ear` — webroot of the Elastic Artifact Registry, served by [Caddy](https://caddyserver.com/docs/) with [`file_server`](https://caddyserver.com/docs/caddyfile/directives/file_server)
- `dist/web/` -> `/opt/ear-web` — Caddy binary + `Caddyfile` + `ear.service` (create the `caddy` user per the unit comments; edit the hostname in `Caddyfile` to match the cert SAN)
- TLS certificates are issued inside the offline environment — install them at deploy time: `cat server.crt ca-chain.pem > /opt/ear-web/tls/cert.pem` and `key.pem` alongside (0600, owned by `caddy`). Caddy [`tls` directive](https://caddyserver.com/docs/caddyfile/directives/tls) for details.
- `dist/epr/` -> `/opt/epr` — package-registry binary + `config.yml` + `epr.service` + `packages/` (create the `epr` user). Point Fleet at it via [`xpack.fleet.registryUrl`/`registryUrl` in kibana.yml](https://www.elastic.co/docs/reference/kibana/configuration-reference/fleet-settings)
- `dist/containers/elastic-epr-<version>.tar.gz` — alternative EPR deployment as a container (Elastic's recommended "distribution" image: registry + all packages baked in): `gunzip -c elastic-epr-<version>.tar.gz | docker load` then run with the registry port published (see the podman/systemd example in [Elastic's air-gapped docs](https://www.elastic.co/docs/reference/fleet/air-gapped))
- `dist/containers/` -> `gunzip -c <file>.tar.gz | docker load`
- GeoIP: `sed -i 's/__EAR_HOST__/<ear-fqdn>/' /opt/ear/geoip/database.json`, then set `ingest.geoip.downloader.endpoint: https://<ear-fqdn>/geoip/database.json` in `elasticsearch.yml` ([ingest settings](https://www.elastic.co/docs/reference/elasticsearch/configuration-reference/ingest-settings))
- ML models (if `download:models` was run): set `xpack.ml.model_repository: http://<ear-fqdn>/models/` in `elasticsearch.yml` ([ML settings](https://www.elastic.co/docs/reference/elasticsearch/configuration-reference/machine-learning-settings)) — Kibana's Trained Models page then "downloads" ELSER/e5/rerank from the EAR. Alternative: copy the model files into `$ES_HOME/config/models/` on all master-eligible nodes and point `xpack.ml.model_repository` at `file://${path.home}/config/models/` — both described in the [ELSER air-gapped section](https://www.elastic.co/docs/explore-analyze/machine-learning/nlp/ml-nlp-elser)

Note on TLS and agents: Elastic Agent cannot pin trust for artifact downloads — either install the CA into each host's system trust store and use `https://`, or point agent binary sources at the `http://` endpoint (both are served). See [Fleet air-gapped docs](https://www.elastic.co/docs/reference/fleet/air-gapped).
