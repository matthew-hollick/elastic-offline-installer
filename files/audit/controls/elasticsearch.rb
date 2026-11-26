elasticsearch_url = input('es_url').sub(%r{/$}, '')
skip_tls_verify = input('insecure')
credentials = { user: input('es_user'), pass: input('es_password') }

control 'es-root' do
  impact 0.7
  title 'Elasticsearch answers / with the expected tagline'
  desc 'Elasticsearch answers / with the expected tagline'
  root_response = http("#{elasticsearch_url}/", auth: credentials, ssl_verify: !skip_tls_verify)
  describe root_response do
    its('status') { should eq 200 }
  end
  describe json(content: root_response.body) do
    its('tagline') { should eq 'You Know, for Search' }
  end
end

control 'es-cluster-health' do
  impact 0.7
  title 'Cluster health is not red'
  desc 'Cluster health is not red'
  health_response = http("#{elasticsearch_url}/_cluster/health", auth: credentials, ssl_verify: !skip_tls_verify)
  describe health_response do
    its('status') { should eq 200 }
  end
  describe json(content: health_response.body) do
    its('status') { should be_in %w{green yellow} }
  end
end

control 'es-disk-space' do
  impact 0.7
  title 'Every node is below its flood-stage disk watermark'
  desc 'Every node is below its flood-stage disk watermark'

  node_allocations = JSON.parse(http("#{elasticsearch_url}/_cat/allocation?format=json", auth: credentials, ssl_verify: !skip_tls_verify).body)
  cluster_settings = JSON.parse(http("#{elasticsearch_url}/_cluster/settings?include_defaults=true", auth: credentials, ssl_verify: !skip_tls_verify).body)

  # effective flood_stage: transient > persistent > defaults; may be a
  # percentage ("95%") or an absolute size ("1gb" — as start-local sets it)
  flood_stage_watermark = %w{transient persistent defaults}
                          .filter_map { |level| cluster_settings.dig(level, 'cluster', 'routing', 'allocation', 'disk', 'watermark', 'flood_stage') }
                          .first || '95%'
  bytes_per_unit = { 'b' => 1, 'kb' => 1024, 'mb' => 1024**2, 'gb' => 1024**3, 'tb' => 1024**4 }
  parse_size_bytes = lambda do |size|
    match = size.to_s.strip.downcase.match(/([\d.]+)\s*(b|kb|mb|gb|tb)?/)
    match ? match[1].to_f * bytes_per_unit.fetch(match[2] || 'b', 1) : 0
  end

  node_allocations.each do |node|
    describe "disk headroom on node #{node['node']} (#{node['disk.used']}/#{node['disk.total']} used, watermark #{flood_stage_watermark})" do
      if flood_stage_watermark.end_with?('%')
        subject { node['disk.percent'].to_f }
        it { should be < flood_stage_watermark.to_f }
      else
        subject { parse_size_bytes.(node['disk.avail']) }
        it { should be > parse_size_bytes.(flood_stage_watermark) }
      end
    end
  end
end

control 'es-requires-auth' do
  impact 0.5
  title 'Unauthenticated requests are rejected (security enabled)'
  desc 'Unauthenticated requests are rejected (security enabled)'
  describe http("#{elasticsearch_url}/", ssl_verify: !skip_tls_verify) do
    its('status') { should eq 401 }
  end
end
