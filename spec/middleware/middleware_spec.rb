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

  def headers_of(path, extra = {})
    request(path, extra)[1]
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

  describe 'construction' do
    it 'refuses a queue algorithm, which cannot answer allow-or-reject immediately' do
      queue = RateLimiter::Algorithms::LeakyBucketQueue.new(capacity: 2, leak_rate: 1, clock: clock)

      expect { described_class.new(inner_app, limiter: queue, paths: ['/limited']) }
        .to raise_error(ArgumentError, /queue algorithms/)
    end
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

    it "passes the app's status, content-type and body through" do
      status, headers, body = request('/limited')

      expect(status).to eq(200)
      expect(headers['content-type']).to eq('text/plain')
      expect(body).to eq(['OK'])
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

  # Capacity 2, refilling 1 token per second: each request leaves the bucket
  # one token further from full, so ratelimit-reset grows by a second.
  describe 'rate limit headers' do
    it 'reports limit, remaining and reset on the first request' do
      expect(headers_of('/limited'))
        .to include('ratelimit-limit' => '2', 'ratelimit-remaining' => '1', 'ratelimit-reset' => '1')
    end

    it 'counts down on the second request' do
      request('/limited')

      expect(headers_of('/limited')).to include('ratelimit-remaining' => '0', 'ratelimit-reset' => '2')
    end

    it 'reports all three, plus retry-after, on a 429' do
      2.times { request('/limited') }

      status, headers, _body = request('/limited')

      expect(status).to eq(429)
      expect(headers).to include('ratelimit-limit' => '2', 'ratelimit-remaining' => '0',
                                 'ratelimit-reset' => '2', 'retry-after' => '1')
    end

    it 'rounds retry-after and ratelimit-reset up to whole seconds' do
      2.times { request('/limited') }
      clock.advance(0.25)

      # 0.75 s until one token is back, 1.75 s until the bucket is full again.
      expect(headers_of('/limited')).to include('retry-after' => '1', 'ratelimit-reset' => '2')
    end

    it 'omits ratelimit-reset when the limiter does not report it' do
      custom = Class.new do
        def limit = 5

        def acquire(_key, cost: 1)
          RateLimiter::Result.new(allowed: true, remaining: 5 - cost, retry_after: 0.0)
        end
      end
      app = described_class.new(inner_app, limiter: custom.new, paths: ['/limited'])

      _status, headers, _body = app.call(build_env('/limited'))

      expect(headers).to include('ratelimit-limit' => '5', 'ratelimit-remaining' => '4')
      expect(headers).not_to have_key('ratelimit-reset')
    end

    it 'adds no rate limit headers to other paths' do
      expect(headers_of('/unlimited').keys.grep(/\Aratelimit-/)).to be_empty
    end

    it 'exposes the decision to the app in the env' do
      env = build_env('/limited')

      middleware.call(env)

      expect(env[described_class::RESULT_KEY])
        .to be_a(RateLimiter::Result).and have_attributes(allowed?: true, remaining: 1)
    end
  end

  describe 'the 429 response' do
    immediate = RateLimiter::Registry.names.select do |name|
      RateLimiter::Registry.fetch(name).kind == :immediate
    end

    immediate.each do |algorithm|
      it "is the same for #{algorithm}" do
        config = RateLimiter::Configuration.new.tap do |settings|
          settings.algorithm = algorithm
          settings.limit = 1
          settings.window = 60
          settings.clock = FakeClock.new(600.0)
        end
        app = described_class.new(inner_app, limiter: RateLimiter.limiter(config), paths: ['/limited'])

        app.call(build_env('/limited'))
        status, headers, body = app.call(build_env('/limited'))

        expect(status).to eq(429)
        expect(headers.keys).to contain_exactly('content-type', 'retry-after', 'ratelimit-limit',
                                                'ratelimit-remaining', 'ratelimit-reset')
        expect(headers).to include('ratelimit-limit' => '1', 'ratelimit-remaining' => '0')
        expect(body).to eq(["Too Many Requests\n"])
      end
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
