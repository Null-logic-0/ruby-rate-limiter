# frozen_string_literal: true

require 'rate_limiter/middleware'

RSpec.describe RateLimiter::Middleware::ClientIp do
  def env(remote_addr, forwarded_for = nil)
    { 'REMOTE_ADDR' => remote_addr, 'HTTP_X_FORWARDED_FOR' => forwarded_for }.compact
  end

  context 'with no trusted proxies (the default)' do
    subject(:client_ip) { described_class.new }

    it 'returns REMOTE_ADDR' do
      expect(client_ip.call(env('203.0.113.7'))).to eq('203.0.113.7')
    end

    it 'ignores X-Forwarded-For, which any client can forge' do
      expect(client_ip.call(env('203.0.113.7', '198.51.100.1'))).to eq('203.0.113.7')
    end

    it 'ignores X-Forwarded-For even from a loopback address' do
      expect(client_ip.call(env('127.0.0.1', '198.51.100.1'))).to eq('127.0.0.1')
    end
  end

  context 'behind trusted proxies' do
    subject(:client_ip) { described_class.new(trusted_proxies: ['10.0.0.0/8', '192.0.2.10']) }

    it 'returns the client address the proxy reported' do
      expect(client_ip.call(env('10.0.0.5', '203.0.113.7'))).to eq('203.0.113.7')
    end

    it 'skips every trusted proxy in the chain' do
      result = client_ip.call(env('10.0.0.5', '203.0.113.7, 192.0.2.10, 10.1.1.1'))

      expect(result).to eq('203.0.113.7')
    end

    it 'ignores addresses the client added to the left of the chain' do
      expect(client_ip.call(env('10.0.0.5', '198.51.100.1, 203.0.113.7'))).to eq('203.0.113.7')
    end

    it 'ignores X-Forwarded-For when the request did not come from a trusted proxy' do
      expect(client_ip.call(env('203.0.113.7', '198.51.100.1'))).to eq('203.0.113.7')
    end

    it 'falls back to REMOTE_ADDR when the proxy sent no X-Forwarded-For' do
      expect(client_ip.call(env('10.0.0.5'))).to eq('10.0.0.5')
    end

    it 'treats malformed entries as untrusted instead of raising' do
      expect(client_ip.call(env('10.0.0.5', 'garbage, 203.0.113.7'))).to eq('203.0.113.7')
    end
  end

  it 'supports IPv6 addresses and ranges' do
    client_ip = described_class.new(trusted_proxies: ['fd00::/8'])

    expect(client_ip.call(env('fd00::1', '2001:db8::7'))).to eq('2001:db8::7')
  end

  it 'rejects an invalid trusted proxy at boot' do
    expect { described_class.new(trusted_proxies: ['not-an-ip']) }
      .to raise_error(IPAddr::InvalidAddressError)
  end
end
