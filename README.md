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
