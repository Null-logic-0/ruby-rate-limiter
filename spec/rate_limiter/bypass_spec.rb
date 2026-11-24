# frozen_string_literal: true

require 'rate_limiter/bypass'

RSpec.describe RateLimiter::Bypass do
  subject(:bypass) { described_class.new(ip_ranges: ['10.0.0.0/8', 'fd00::/8'], api_keys: ['sk_partner_1']) }

  it 'trusts addresses in the given ranges, IPv4 and IPv6' do
    expect(bypass.call('REMOTE_ADDR' => '10.20.30.40')).to be(true)
    expect(bypass.call('REMOTE_ADDR' => 'fd00::1')).to be(true)
  end

  it 'does not trust other addresses' do
    expect(bypass.call('REMOTE_ADDR' => '203.0.113.7')).to be(false)
  end

  it 'ignores a forged X-Forwarded-For claiming a trusted address' do
    expect(bypass.call('REMOTE_ADDR' => '203.0.113.7', 'HTTP_X_FORWARDED_FOR' => '10.0.0.1')).to be(false)
  end

  it 'uses X-Forwarded-For behind a trusted proxy' do
    behind_proxy = described_class.new(
      ip_ranges: ['10.0.0.0/8'],
      client_ip: RateLimiter::Middleware::ClientIp.new(trusted_proxies: ['192.0.2.10'])
    )

    expect(behind_proxy.call('REMOTE_ADDR' => '192.0.2.10', 'HTTP_X_FORWARDED_FOR' => '10.0.0.1')).to be(true)
  end

  it 'trusts the listed API keys' do
    expect(bypass.call('REMOTE_ADDR' => '203.0.113.7', 'HTTP_X_API_KEY' => 'sk_partner_1')).to be(true)
  end

  ['sk_partner_2', '', nil].each do |key|
    it "does not trust the API key #{key.inspect}" do
      expect(bypass.call('REMOTE_ADDR' => '203.0.113.7', 'HTTP_X_API_KEY' => key)).to be(false)
    end
  end

  it 'keeps only digests of the API keys' do
    expect(bypass.inspect).not_to include('sk_partner_1')
  end

  it 'handles a missing or malformed address' do
    expect(bypass.call({})).to be(false)
    expect(bypass.call('REMOTE_ADDR' => 'not-an-ip')).to be(false)
  end

  it 'trusts nobody when given nothing' do
    expect(described_class.new.call('REMOTE_ADDR' => '10.0.0.1')).to be(false)
  end
end
