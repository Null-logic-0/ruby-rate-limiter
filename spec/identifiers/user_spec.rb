# frozen_string_literal: true

require 'rate_limiter/identifiers'

RSpec.describe RateLimiter::Identifiers::User do
  it 'keys the request by the user id your authentication stored in the env' do
    expect(described_class.new.call('rate_limiter.user_id' => 42)).to eq('user:42')
  end

  it 'reads another env key when told to' do
    expect(described_class.new(from: 'warden.user_id').call('warden.user_id' => 'u_7')).to eq('user:u_7')
  end

  it 'asks a callable, e.g. your authentication library' do
    session_user = ->(env) { env.dig('rack.session', 'user_id') }

    expect(described_class.new(from: session_user).call('rack.session' => { 'user_id' => 9 })).to eq('user:9')
  end

  [nil, ''].each do |id|
    it "returns nil when nobody is logged in (#{id.inspect})" do
      expect(described_class.new.call('rate_limiter.user_id' => id)).to be_nil
    end
  end

  it 'ignores a user id the client sent in a header' do
    env = { 'HTTP_X_USER_ID' => 'admin', 'HTTP_RATE_LIMITER_USER_ID' => 'admin' }

    expect(described_class.new.call(env)).to be_nil
  end

  ['HTTP_X_USER_ID', 'http_x_user_id'].each do |header|
    it "refuses to read the request header #{header}, which any client can forge" do
      expect { described_class.new(from: header) }.to raise_error(ArgumentError, /forge/)
    end
  end

  it 'refuses something that is neither an env key nor callable' do
    expect { described_class.new(from: :user_id) }.to raise_error(ArgumentError, /env key/)
  end
end
