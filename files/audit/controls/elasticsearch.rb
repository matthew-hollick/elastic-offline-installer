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

control 'es-disk-space' do
  impact 0.7
  title 'Every node is below its flood-stage disk watermark'
  desc 'Every node is below its flood-stage disk watermark'

  alloc = JSON.parse(http("#{es}/_cat/allocation?format=json", auth: auth, ssl_verify: !insecure).body)
  settings = JSON.parse(http("#{es}/_cluster/settings?include_defaults=true", auth: auth, ssl_verify: !insecure).body)

  # effective flood_stage: transient > persistent > defaults; may be a
  # percentage ("95%") or an absolute size ("1gb" — as start-local sets it)
  wm = %w{transient persistent defaults}
       .filter_map { |t| settings.dig(t, 'cluster', 'routing', 'allocation', 'disk', 'watermark', 'flood_stage') }
       .first || '95%'
  units = { 'b' => 1, 'kb' => 1024, 'mb' => 1024**2, 'gb' => 1024**3, 'tb' => 1024**4 }
  to_bytes = lambda do |v|
    m = v.to_s.strip.downcase.match(/([\d.]+)\s*(b|kb|mb|gb|tb)?/)
    m ? m[1].to_f * units.fetch(m[2] || 'b', 1) : 0
  end

  alloc.each do |n|
    describe "disk headroom on node #{n['node']} (#{n['disk.used']}/#{n['disk.total']} used, watermark #{wm})" do
      if wm.end_with?('%')
        subject { n['disk.percent'].to_f }
        it { should be < wm.to_f }
      else
        subject { to_bytes.(n['disk.avail']) }
        it { should be > to_bytes.(wm) }
      end
    end
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
