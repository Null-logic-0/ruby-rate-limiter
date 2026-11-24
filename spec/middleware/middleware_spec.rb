# frozen_string_literal: true

require 'rate_limiter/middleware'

RSpec.describe RateLimiter::Middleware do
  subject(:middleware) { described_class.new(inner_app, limiter: limiter, paths: ['/limited']) }

  let(:clock) { FakeClock.new }
  let(:limiter) { RateLimiter::Algorithms::TokenBucket.new(capacity: 2, refill_rate: 1, clock: clock) }
  let(:app_calls) { [] }
  let(:inner_app) do
    lambda do |env|
      app_calls << env['PATH_INFO']
      [200, { 'content-type' => 'text/plain' }, ['OK']]
    end
  end

  # Builds a Rack env with a raw PATH_INFO, exactly as Puma would pass it.
  def build_env(path, extra = {})
    Rack::MockRequest.env_for('/').merge('PATH_INFO' => path, 'REMOTE_ADDR' => '203.0.113.7', **extra)
  end

  def request(path, extra = {})
    middleware.call(build_env(path, extra))
  end

  def status_of(path, extra = {})
    request(path, extra).first
  end

  def client_key_for(path, extra = {})
    env = build_env(path, extra)
    middleware.call(env)
    env[described_class::CLIENT_KEY]
  end

  def linted_status(path)
    linted = Rack::Lint.new(described_class.new(Rack::Lint.new(inner_app), limiter: limiter, paths: ['/limited']))
    status, _headers, body = linted.call(build_env(path))
    body.close
    status
  end

  describe 'client identification' do
    it "tags requests to a limited path with the client's IP key" do
      expect(client_key_for('/limited')).to eq('ip:203.0.113.7')
    end

    it 'gives each client IP its own key' do
      expect(client_key_for('/limited', 'REMOTE_ADDR' => '198.51.100.9')).to eq('ip:198.51.100.9')
    end

    it 'leaves requests to other paths untagged' do
      expect(client_key_for('/unlimited')).to be_nil
    end

    it 'returns the downstream response unchanged when admitted' do
      expect(request('/limited')).to eq([200, { 'content-type' => 'text/plain' }, ['OK']])
    end

    it 'uses an injected client IP resolver' do
      custom = described_class.new(inner_app, limiter: limiter, paths: ['/limited'],
                                              client_ip: ->(_env) { '198.51.100.42' })
      env = build_env('/limited')

      custom.call(env)

      expect(env[described_class::CLIENT_KEY]).to eq('ip:198.51.100.42')
    end
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

  describe 'rate limiting' do
    it 'admits requests while tokens remain' do
      expect([status_of('/limited'), status_of('/limited')]).to eq([200, 200])
    end

    it 'answers 429 once the bucket is empty' do
      2.times { request('/limited') }

      status, headers, body = request('/limited')

      expect(status).to eq(429)
      expect(headers['content-type']).to eq('text/plain')
      expect(body).to eq(["Too Many Requests\n"])
    end

    it 'rounds Retry-After up to whole seconds' do
      2.times { request('/limited') }
      clock.advance(0.25)

      _status, headers, _body = request('/limited')

      expect(headers['retry-after']).to eq('1')
    end

    it 'does not call the app for rejected requests' do
      3.times { request('/limited') }

      expect(app_calls.size).to eq(2)
    end

    it 'admits requests again after a refill' do
      2.times { request('/limited') }
      clock.advance(1)

      expect(status_of('/limited')).to eq(200)
    end

    it 'limits each client separately' do
      2.times { request('/limited') }

      expect(status_of('/limited')).to eq(429)
      expect(status_of('/limited', 'REMOTE_ADDR' => '198.51.100.9')).to eq(200)
    end

    it 'never limits other paths' do
      statuses = Array.new(5) { status_of('/unlimited') }

      expect(statuses).to eq([200] * 5)
      expect(limiter.tokens('ip:203.0.113.7')).to eq(2.0)
    end

    it 'charges every spelling of a limited path to the same bucket' do
      statuses = ['/limited', '/%6Cimited', '/x/../limited'].map { |path| status_of(path) }

      expect(statuses).to eq([200, 200, 429])
    end
  end

  describe 'Rack compliance' do
    it 'holds for admitted requests' do
      expect(linted_status('/limited')).to eq(200)
    end

    it 'holds for rejected requests' do
      2.times { request('/limited') }

      expect(linted_status('/limited')).to eq(429)
    end
  end
end
