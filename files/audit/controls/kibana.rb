kibana_base_url = input('kibana_url').sub(%r{/$}, '')
skip_tls_verify = input('insecure')
credentials = { user: input('es_user'), pass: input('es_password') }

control 'kibana-status' do
  impact 0.7
  title 'Kibana /api/status reports overall available'
  desc 'Kibana /api/status reports overall available'
  status_response = http("#{kibana_base_url}/api/status", auth: credentials, ssl_verify: !skip_tls_verify)
  describe status_response do
    its('status') { should eq 200 }
  end
  describe json(content: status_response.body) do
    its(%w{status overall level}) { should be_in %w{available degraded} }
  end
end

control 'kibana-login-page' do
  impact 0.5
  title 'Kibana serves its login page'
  desc 'Kibana serves its login page'
  # authenticated requests get 302'd to the app; anonymous gets the 200 login page
  describe http("#{kibana_base_url}/login", auth: credentials, ssl_verify: !skip_tls_verify) do
    its('status') { should be_in [200, 302] }
  end
end
