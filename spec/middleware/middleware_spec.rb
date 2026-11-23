# frozen_string_literal: true

require 'rate_limiter/middleware'

RSpec.describe RateLimiter::Middleware do
  subject(:middleware) { described_class.new(inner_app, paths: ['/limited']) }

  let(:inner_app) { ->(_env) { [200, { 'content-type' => 'text/plain' }, ['OK']] } }

  # Builds a Rack env with a raw PATH_INFO, exactly as Puma would pass it.
  def build_env(path, extra = {})
    Rack::MockRequest.env_for('/').merge('PATH_INFO' => path, 'REMOTE_ADDR' => '203.0.113.7', **extra)
  end

  def client_key_for(path, extra = {})
    env = build_env(path, extra)
    middleware.call(env)
    env[described_class::CLIENT_KEY]
  end

  it "tags requests to a limited path with the client's IP key" do
    expect(client_key_for('/limited')).to eq('ip:203.0.113.7')
  end

  it 'gives each client IP its own key' do
    expect(client_key_for('/limited', 'REMOTE_ADDR' => '198.51.100.9')).to eq('ip:198.51.100.9')
  end

  it 'leaves requests to other paths untagged' do
    expect(client_key_for('/unlimited')).to be_nil
  end

  it 'returns the downstream response unchanged' do
    expect(middleware.call(build_env('/limited'))).to eq([200, { 'content-type' => 'text/plain' }, ['OK']])
  end

  describe 'path normalization' do
    ['/%6Cimited', '/lim%69ted', '//limited', '/./limited', '/x/../limited',
     '/%2e%2e/limited', '/%2Flimited', '/%5Climited', '/limited/'].each do |path|
      it "treats #{path} as /limited" do
        expect(client_key_for(path)).to eq('ip:203.0.113.7')
      end
    end

    ['/limitedx', '/limited/extra', '/%256Cimited'].each do |path|
      it "does not treat #{path} as /limited" do
        expect(client_key_for(path)).to be_nil
      end
    end

    ['/%FF%FE', '/%'].each do |path|
      it "handles the invalid encoding in #{path} without raising" do
        expect(client_key_for(path)).to be_nil
      end
    end
  end

  it 'uses an injected client IP resolver' do
    middleware = described_class.new(inner_app, paths: ['/limited'], client_ip: ->(_env) { '198.51.100.42' })
    env = build_env('/limited')

    middleware.call(env)

    expect(env[described_class::CLIENT_KEY]).to eq('ip:198.51.100.42')
  end

  it 'complies with the Rack specification' do
    linted = Rack::Lint.new(described_class.new(Rack::Lint.new(inner_app), paths: ['/limited']))

    status, _headers, body = linted.call(build_env('/limited'))
    body.close

    expect(status).to eq(200)
  end
end
