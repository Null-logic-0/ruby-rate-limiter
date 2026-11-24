# frozen_string_literal: true

require 'digest'
require 'rate_limiter/identifiers'

RSpec.describe RateLimiter::Identifiers::ApiKey do
  subject(:identifier) { described_class.new }

  let(:api_key) { 'sk_live_4f9a2c7e1b8d' }

  it 'keys the request by a truncated SHA-256 digest of the X-API-Key header' do
    expect(identifier.call('HTTP_X_API_KEY' => api_key))
      .to eq("key:#{Digest::SHA256.hexdigest(api_key)[0, 16]}")
  end

  it 'never puts the raw key into the key' do
    expect(identifier.call('HTTP_X_API_KEY' => api_key)).not_to include(api_key)
  end

  it 'gives the same key the same identity, and different keys different ones' do
    first = identifier.call('HTTP_X_API_KEY' => api_key)

    expect(identifier.call('HTTP_X_API_KEY' => api_key)).to eq(first)
    expect(identifier.call('HTTP_X_API_KEY' => 'sk_live_other')).not_to eq(first)
  end

  it 'ignores surrounding whitespace' do
    expect(identifier.call('HTTP_X_API_KEY' => " #{api_key} ")).to eq(identifier.call('HTTP_X_API_KEY' => api_key))
  end

  [nil, '', '   '].each do |value|
    it "returns nil for a missing or blank header (#{value.inspect})" do
      expect(identifier.call('HTTP_X_API_KEY' => value)).to be_nil
    end
  end

  it 'reads the header it is configured with' do
    authorization = described_class.new(header: 'X-Client-Token')

    expect(authorization.call('HTTP_X_CLIENT_TOKEN' => api_key)).to start_with('key:')
    expect(authorization.call('HTTP_X_API_KEY' => api_key)).to be_nil
  end

  describe 'with verify:' do
    subject(:identifier) { described_class.new(verify: ->(key) { key == api_key }) }

    it 'identifies keys that pass the check' do
      expect(identifier.call('HTTP_X_API_KEY' => api_key)).to start_with('key:')
    end

    it 'returns nil for unknown keys, so random keys cannot buy fresh limits' do
      expect(identifier.call('HTTP_X_API_KEY' => 'made-up-key')).to be_nil
    end
  end

  it 'refuses a verify: that cannot be called' do
    expect { described_class.new(verify: 'yes') }.to raise_error(ArgumentError, /verify/)
  end
end
