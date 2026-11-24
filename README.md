A project to download Elasticsearch components for deployment to an offline environment

Latest version of the Elastic stack is 9.5.7

Reference: https://www.elastic.co/docs/deploy-manage/deploy/self-managed/air-gapped-install

Elasticsearch is deployed on Ubuntu VMs.

This laptop is arm but our production servers are amd64. we need to be able to define which platform to target.

We need to build out an EAR (Elastic Artifact Registry) for hosting on a webserver. The directory layout mirrors https://artifacts.elastic.co/downloads/ so it can be pointed to directly as the Fleet "agent binary download source" and the Endpoint artifact repository:

- .deb files for elasticsearch, kibana, elastic-agent
- linux tar.gz and windows zip for all agent-downloadable components: elastic-agent, fleet-server, apm-server, auditbeat, filebeat, heartbeat, metricbeat, osquerybeat, packetbeat, cloudbeat (linux only), endpoint-security (Elastic Defend), winlogbeat (windows only)
- every artifact accompanied by its .sha512 checksum and .asc signature

We need to build an EPR (Elastic Package Registory)
- Consider https://github.com/elastic/custom-epr-builder but I want to run outside of Docker so that I can easilly add new integrations as they become available.
- Latest version of the Elastic Package Registry binary for linux
- A systemd service definition

There are additional containers that we need to bring with us:
- Elastic Agent
- Prometheus exporter for SNMP

Plus Elastic's support-diagnostics tool (`dist/tools/diagnostics-<ver>-dist.zip`) for capturing full platform state when Elastic Support asks — unzip on a node with a JRE and run `support-diagnostics.sh`.

## Building the bundle

From a clean checkout:

```bash
mise install                          # one-time: go, task, python

task download                         # EAR artifacts + integrations + containers + webserver
task build                            # compiles package-registry (EPR)
task build:integration -- https://github.com/FortytwoM/elastic-nessus-integration nessus
task package                          # verify checksums + tar dist/ -> elastic-offline-bundle-<version>.tar.gz
```

`KIBANA_CONSTRAINT='^8.13.0 || ^9.0.0'` can be set before `build:integration` to relax a package's declared `conditions.kibana.version`.

## Deploying (offline side)

- `dist/ear/` -> `/opt/ear` — webroot of the Elastic Artifact Registry
- `dist/web/` -> `/opt/ear-web` — Caddy binary + `Caddyfile` + `ear.service` (create the `caddy` user per the unit comments; edit the hostname in `Caddyfile` to match the cert SAN)
- TLS certificates are issued inside the offline environment — install them at deploy time: `cat server.crt ca-chain.pem > /opt/ear-web/tls/cert.pem` and `key.pem` alongside (0600, owned by `caddy`)
- `dist/epr/` -> `/opt/epr` — package-registry binary + `config.yml` + `epr.service` + `packages/` (create the `epr` user)
- `dist/containers/elastic-epr-<version>.tar.gz` — alternative EPR deployment as a container (Elastic's recommended "distribution" image: registry + all packages baked in): `gunzip -c elastic-epr-<version>.tar.gz | docker load` then run with the registry port published (see the podman/systemd example in Elastic's air-gapped docs)
- `dist/containers/` -> `gunzip -c <file>.tar.gz | docker load`

Note on TLS and agents: Elastic Agent cannot pin trust for artifact downloads — either install the CA into each host's system trust store and use `https://`, or point agent binary sources at the `http://` endpoint (both are served).
