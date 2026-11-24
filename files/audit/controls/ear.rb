ear = input('ear_url').sub(%r{/$}, '')
ver = input('stack_version')
insecure = input('insecure')

control 'ear-gpg-key' do
  impact 0.7
  title 'EAR serves the Elastic release-signing public key'
  desc 'EAR serves the Elastic release-signing public key'
  describe http("#{ear}/GPG-KEY-elasticsearch", ssl_verify: !insecure) do
    its('status') { should eq 200 }
    its('body') { should match 'BEGIN PGP PUBLIC KEY BLOCK' }
  end
end

control 'ear-artifact-checksum' do
  impact 0.7
  title 'EAR serves stack artifacts + sha512 checksums'
  desc 'EAR serves stack artifacts + sha512 checksums'
  describe http("#{ear}/downloads/elasticsearch/elasticsearch-#{ver}-amd64.deb.sha512", ssl_verify: !insecure) do
    its('status') { should eq 200 }
    its('body') { should match(/^[0-9a-f]{128}  elasticsearch-/) }
  end
end

control 'ear-endpoint-artifacts' do
  impact 0.5
  title 'EAR serves the Elastic Defend artifacts manifest'
  desc 'EAR serves the Elastic Defend artifacts manifest'
  describe http("#{ear}/downloads/endpoint/manifest/artifacts-#{ver}.zip", ssl_verify: !insecure) do
    its('status') { should eq 200 }
  end
end

control 'ear-geoip-manifest' do
  impact 0.5
  title 'EAR serves the rewritten GeoIP downloader manifest'
  desc 'EAR serves the rewritten GeoIP downloader manifest'
  res = http("#{ear}/geoip/database.json", ssl_verify: !insecure)
  describe res do
    its('status') { should eq 200 }
  end
  describe 'geoip manifest entries' do
    subject { JSON.parse(res.body) }
    it { should_not be_empty }
  end
end

control 'ear-kev-feed' do
  impact 0.5
  title 'EAR serves the mirrored CISA KEV feed'
  desc 'EAR serves the mirrored CISA KEV feed'
  res = http("#{ear}/feeds/cisa/known_exploited_vulnerabilities.json", ssl_verify: !insecure)
  describe res do
    its('status') { should eq 200 }
  end
  describe json(content: res.body) do
    its('title') { should eq 'CISA Catalog of Known Exploited Vulnerabilities' }
  end
end
