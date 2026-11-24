# frozen_string_literal: true

require 'rate_guard/identifiers'

RSpec.describe RateGuard::Identifiers::Ip do
  it 'keys the request by REMOTE_ADDR' do
    expect(described_class.new.call('REMOTE_ADDR' => '203.0.113.7')).to eq('ip:203.0.113.7')
  end

  it 'ignores X-Forwarded-For unless the request came through a trusted proxy' do
    env = { 'REMOTE_ADDR' => '203.0.113.7', 'HTTP_X_FORWARDED_FOR' => '198.51.100.1' }

    expect(described_class.new.call(env)).to eq('ip:203.0.113.7')
  end

  it 'uses the ClientIp it is given, e.g. one that trusts a proxy' do
    client_ip = RateGuard::Middleware::ClientIp.new(trusted_proxies: ['10.0.0.0/8'])
    env = { 'REMOTE_ADDR' => '10.0.0.5', 'HTTP_X_FORWARDED_FOR' => '203.0.113.7' }

    expect(described_class.new(client_ip: client_ip).call(env)).to eq('ip:203.0.113.7')
  end

  it 'returns nil when there is no address to go on' do
    expect(described_class.new.call({})).to be_nil
  end
end
