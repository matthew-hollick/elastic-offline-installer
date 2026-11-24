es = input('es_url').sub(%r{/$}, '')
insecure = input('insecure')
auth = { user: input('es_user'), pass: input('es_password') }

control 'es-root' do
  impact 0.7
  title 'Elasticsearch answers / with the expected tagline'
  desc 'Elasticsearch answers / with the expected tagline'
  res = http("#{es}/", auth: auth, ssl_verify: !insecure)
  describe res do
    its('status') { should eq 200 }
  end
  describe json(content: res.body) do
    its('tagline') { should eq 'You Know, for Search' }
  end
end

control 'es-cluster-health' do
  impact 0.7
  title 'Cluster health is not red'
  desc 'Cluster health is not red'
  res = http("#{es}/_cluster/health", auth: auth, ssl_verify: !insecure)
  describe res do
    its('status') { should eq 200 }
  end
  describe json(content: res.body) do
    its('status') { should be_in %w{green yellow} }
  end
end

control 'es-requires-auth' do
  impact 0.5
  title 'Unauthenticated requests are rejected (security enabled)'
  desc 'Unauthenticated requests are rejected (security enabled)'
  describe http("#{es}/", ssl_verify: !insecure) do
    its('status') { should eq 401 }
  end
end
