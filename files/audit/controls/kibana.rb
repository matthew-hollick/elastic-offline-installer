kb = input('kibana_url').sub(%r{/$}, '')
insecure = input('insecure')
auth = { user: input('es_user'), pass: input('es_password') }

control 'kibana-status' do
  impact 0.7
  title 'Kibana /api/status reports overall available'
  desc 'Kibana /api/status reports overall available'
  res = http("#{kb}/api/status", auth: auth, ssl_verify: !insecure)
  describe res do
    its('status') { should eq 200 }
  end
  describe json(content: res.body) do
    its(%w{status overall level}) { should be_in %w{available degraded} }
  end
end

control 'kibana-login-page' do
  impact 0.5
  title 'Kibana serves its login page'
  desc 'Kibana serves its login page'
  describe http("#{kb}/login", auth: auth, ssl_verify: !insecure) do
    its('status') { should eq 200 }
    its('body') { should match(/kibana/i) }
  end
end
