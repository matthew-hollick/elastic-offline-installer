ear_base_url = input('ear_url').sub(%r{/$}, '')
stack_version = input('stack_version')
skip_tls_verify = input('insecure')

control 'ear-gpg-key' do
  impact 0.7
  title 'EAR serves the Elastic release-signing public key'
  desc 'EAR serves the Elastic release-signing public key'
  describe http("#{ear_base_url}/GPG-KEY-elasticsearch", ssl_verify: !skip_tls_verify) do
    its('status') { should eq 200 }
    its('body') { should match 'BEGIN PGP PUBLIC KEY BLOCK' }
  end
end

control 'ear-artifact-checksum' do
  impact 0.7
  title 'EAR serves stack artifacts + sha512 checksums'
  desc 'EAR serves stack artifacts + sha512 checksums'
  describe http("#{ear_base_url}/downloads/elasticsearch/elasticsearch-#{stack_version}-amd64.deb.sha512", ssl_verify: !skip_tls_verify) do
    its('status') { should eq 200 }
    its('body') { should match(/^[0-9a-f]{128}  elasticsearch-/) }
  end
end

control 'ear-endpoint-artifacts' do
  impact 0.5
  title 'EAR serves the Elastic Defend artifacts manifest'
  desc 'EAR serves the Elastic Defend artifacts manifest'
  describe http("#{ear_base_url}/downloads/endpoint/manifest/artifacts-#{stack_version}.zip", ssl_verify: !skip_tls_verify) do
    its('status') { should eq 200 }
  end
end

control 'ear-geoip-manifest' do
  impact 0.5
  title 'EAR serves the rewritten GeoIP downloader manifest'
  desc 'EAR serves the rewritten GeoIP downloader manifest'
  geoip_response = http("#{ear_base_url}/geoip/database.json", ssl_verify: !skip_tls_verify)
  describe geoip_response do
    its('status') { should eq 200 }
  end
  describe 'geoip manifest entries' do
    subject { JSON.parse(geoip_response.body) }
    it { should_not be_empty }
  end
end

control 'ear-docs-site' do
  impact 0.5
  title 'EAR serves the mirrored Elastic documentation site'
  desc 'EAR serves the mirrored Elastic documentation site'
  describe http("#{ear_base_url}/docs/index.html", ssl_verify: !skip_tls_verify) do
    its('status') { should eq 200 }
  end
  describe http("#{ear_base_url}/docs/get-started/the-stack.html", ssl_verify: !skip_tls_verify) do
    its('status') { should eq 200 }
    its('body') { should match 'Elastic Stack' }
  end
end

control 'ear-docs-search' do
  impact 0.5
  title 'EAR serves the offline documentation search'
  desc 'EAR serves the offline documentation search'
  describe http("#{ear_base_url}/docs/search.html", ssl_verify: !skip_tls_verify) do
    its('status') { should eq 200 }
    its('body') { should match 'PagefindUI' }
  end
  describe http("#{ear_base_url}/docs/pagefind/pagefind-entry.json", ssl_verify: !skip_tls_verify) do
    its('status') { should eq 200 }
    its('body') { should match 'page_count' }
  end
end

control 'ear-kev-feed' do
  impact 0.5
  title 'EAR serves the mirrored CISA KEV feed'
  desc 'EAR serves the mirrored CISA KEV feed'
  kev_response = http("#{ear_base_url}/feeds/cisa/known_exploited_vulnerabilities.json", ssl_verify: !skip_tls_verify)
  describe kev_response do
    its('status') { should eq 200 }
  end
  describe json(content: kev_response.body) do
    its('title') { should eq 'CISA Catalog of Known Exploited Vulnerabilities' }
  end
end
