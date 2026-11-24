epr = input('epr_url').sub(%r{/$}, '')
insecure = input('insecure')

control 'epr-health' do
  impact 0.7
  title 'EPR answers /health'
  desc 'EPR answers /health'
  describe http("#{epr}/health", ssl_verify: !insecure) do
    its('status') { should eq 200 }
  end
end

control 'epr-search' do
  impact 0.7
  title 'EPR search returns the package index'
  desc 'EPR search returns the package index'
  res = http("#{epr}/search", ssl_verify: !insecure)
  describe res do
    its('status') { should eq 200 }
  end
  describe 'package index' do
    subject { JSON.parse(res.body) }
    it { should_not be_empty }
  end
end

control 'epr-package-download' do
  impact 0.7
  title 'EPR serves a package zip'
  desc 'EPR serves a package zip'
  pkgs = JSON.parse(http("#{epr}/search", ssl_verify: !insecure).body)
  skip_control 'search returned no packages' if pkgs.empty?
  first = pkgs.first
  describe http("#{epr}/epr/#{first['name']}/#{first['name']}-#{first['version']}.zip", ssl_verify: !insecure) do
    its('status') { should eq 200 }
    its('body.length') { should be > 1000 }
  end
end
