epr_base_url = input('epr_url').sub(%r{/$}, '')
skip_tls_verify = input('insecure')

control 'epr-health' do
  impact 0.7
  title 'EPR answers /health'
  desc 'EPR answers /health'
  describe http("#{epr_base_url}/health", ssl_verify: !skip_tls_verify) do
    its('status') { should eq 200 }
  end
end

control 'epr-search' do
  impact 0.7
  title 'EPR search returns the package index'
  desc 'EPR search returns the package index'
  search_response = http("#{epr_base_url}/search", ssl_verify: !skip_tls_verify)
  describe search_response do
    its('status') { should eq 200 }
  end
  describe 'package index' do
    subject { JSON.parse(search_response.body) }
    it { should_not be_empty }
  end
end

control 'epr-package-download' do
  impact 0.7
  title 'EPR serves a package zip'
  desc 'EPR serves a package zip'
  packages = JSON.parse(http("#{epr_base_url}/search", ssl_verify: !skip_tls_verify).body)
  skip_control 'search returned no packages' if packages.empty?
  first_package = packages.first
  describe http("#{epr_base_url}/epr/#{first_package['name']}/#{first_package['name']}-#{first_package['version']}.zip", ssl_verify: !skip_tls_verify) do
    its('status') { should eq 200 }
    its('body.length') { should be > 1000 }
  end
end
