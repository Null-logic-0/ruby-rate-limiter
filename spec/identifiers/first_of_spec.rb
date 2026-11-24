# frozen_string_literal: true

require 'rate_limiter/identifiers'

RSpec.describe RateLimiter::Identifiers::FirstOf do
  subject(:chain) do
    described_class.new(RateLimiter::Identifiers::User.new, RateLimiter::Identifiers::ApiKey.new,
                        RateLimiter::Identifiers::Ip.new)
  end

  let(:anonymous) { { 'REMOTE_ADDR' => '203.0.113.7' } }

  it 'uses the user when someone is logged in' do
    env = anonymous.merge('rate_limiter.user_id' => 42, 'HTTP_X_API_KEY' => 'sk_live_1')

    expect(chain.call(env)).to eq('user:42')
  end

  it 'falls back to the API key when nobody is logged in' do
    expect(chain.call(anonymous.merge('HTTP_X_API_KEY' => 'sk_live_1'))).to start_with('key:')
  end

  it 'falls back to the IP when there is neither' do
    expect(chain.call(anonymous)).to eq('ip:203.0.113.7')
  end

  it 'returns nil when no identifier can identify the request' do
    expect(described_class.new(RateLimiter::Identifiers::User.new).call(anonymous)).to be_nil
  end

  it 'skips an identifier that returns an empty key' do
    expect(described_class.new(->(_env) { '' }, ->(_env) { 'custom:1' }).call({})).to eq('custom:1')
  end

  it 'accepts any callable as a custom strategy' do
    # e.g. an API gateway in front verified an OAuth token and stored its client id
    gateway_client = ->(env) { (id = env['gateway.client_id']) && "client:#{id}" }
    chain = described_class.new(gateway_client, RateLimiter::Identifiers::Ip.new)

    expect(chain.call(anonymous.merge('gateway.client_id' => 'mobile-app'))).to eq('client:mobile-app')
    expect(chain.call(anonymous)).to eq('ip:203.0.113.7')
  end

  it 'needs at least one identifier' do
    expect { described_class.new }.to raise_error(ArgumentError, /at least one/)
  end

  it 'refuses something that is not callable' do
    expect { described_class.new('ip') }.to raise_error(ArgumentError, /does not respond to #call/)
  end
end
