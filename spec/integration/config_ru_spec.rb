# frozen_string_literal: true

require 'rack/test'
require 'rate_limiter/middleware'

RSpec.describe 'config.ru' do
  include Rack::Test::Methods

  settings = %w[RATE_LIMIT_ALGORITHM RATE_LIMIT RATE_LIMIT_WINDOW TRUSTED_PROXIES REDIS_URL RATE_LIMIT_REDIS_FAILURE
                RATE_LIMIT_API_KEYS]

  # Start every example from the defaults, whatever the shell has set, and
  # restore the environment and global configuration afterwards.
  around do |example|
    saved = ENV.to_h.slice(*settings)
    settings.each { |name| ENV.delete(name) }
    example.run
  ensure
    settings.each { |name| ENV.delete(name) }
    ENV.update(saved)
    RateLimiter.reset_configuration!
  end

  # Each call builds a separate server: its own limiter, its own Redis client.
  def build_app
    Rack::Builder.parse_file(File.expand_path('../../config.ru', __dir__))
  end

  let(:app) { build_app }
  let(:client_key) { last_request.env[RateLimiter::Middleware::CLIENT_KEY] }

  def burst(path, count, headers = {})
    Array.new(count) do
      get path, {}, headers
      last_response.status
    end
  end

  describe 'routing and identification' do
    it 'serves /unlimited without identifying the client' do
      get '/unlimited'

      expect(last_response.body).to eq("Unlimited! Let's Go!")
      expect(client_key).to be_nil
    end

    it 'identifies the client on /limited before the app responds' do
      get '/limited'

      expect(last_response.body).to eq("Limited, don't over use me!")
      expect(client_key).to eq('ip:127.0.0.1')
    end

    it 'identifies the client on an encoded spelling of /limited' do
      get '/%6Cimited'

      expect(last_response.body).to eq("Limited, don't over use me!")
      expect(client_key).to eq('ip:127.0.0.1')
    end

    it 'ignores a forged X-Forwarded-For header' do
      get '/limited', {}, { 'HTTP_X_FORWARDED_FOR' => '198.51.100.1' }

      expect(client_key).to eq('ip:127.0.0.1')
    end
  end

  describe 'identification by API key (RATE_LIMIT_API_KEYS)' do
    let(:issued_key) { 'sk_live_4f9a2c7e1b8d' }

    before { ENV['RATE_LIMIT_API_KEYS'] = "#{issued_key}, sk_live_second" }

    def with_key(key, ip = '127.0.0.1') = { 'HTTP_X_API_KEY' => key, 'REMOTE_ADDR' => ip }

    it 'gives an issued key its own limit, apart from its IP' do
      expect(burst('/limited', 11, with_key(issued_key))).to eq([200] * 10 + [429])
      expect(burst('/limited', 1)).to eq([200])
    end

    it 'shares one limit for an issued key across IPs' do
      statuses = (1..11).map { |i| burst('/limited', 1, with_key(issued_key, "198.51.100.#{i}")).first }

      expect(statuses).to eq([200] * 10 + [429])
    end

    it 'limits a request with an unknown key by its IP, so made-up keys buy nothing' do
      burst('/limited', 10)

      expect(burst('/limited', 1, with_key('made-up-key'))).to eq([429])
      expect(client_key).to eq('ip:127.0.0.1')
    end

    it 'keys by a digest, never the raw key' do
      get '/limited', {}, with_key(issued_key)

      expect(client_key).to match(/\Akey:\h{16}\z/)
    end
  end

  describe 'the default token bucket' do
    it 'admits a burst of 10 and rejects the 11th with 429' do
      expect(burst('/limited', 11)).to eq([200] * 10 + [429])
    end

    it 'does not give a forged X-Forwarded-For a fresh bucket' do
      burst('/limited', 10)

      get '/limited', {}, { 'HTTP_X_FORWARDED_FOR' => '198.51.100.1' }

      expect(last_response.status).to eq(429)
    end

    it 'never limits /unlimited' do
      expect(burst('/unlimited', 20).uniq).to eq([200])
    end
  end

  describe 'rate limit headers' do
    it 'describes the quota on admitted responses' do
      get '/limited'

      expect(last_response.headers).to include(
        'ratelimit-limit' => '10', 'ratelimit-remaining' => '9', 'ratelimit-reset' => '1'
      )
    end

    it 'adds Retry-After to rejected responses' do
      burst('/limited', 11)

      expect(last_response.headers).to include(
        'ratelimit-limit' => '10', 'ratelimit-remaining' => '0', 'ratelimit-reset' => '10', 'retry-after' => '1'
      )
    end

    it 'leaves /unlimited responses alone' do
      get '/unlimited'

      expect(last_response.headers).not_to include('ratelimit-limit')
    end
  end

  describe 'configuration from the environment' do
    it 'uses the algorithm named in RATE_LIMIT_ALGORITHM' do
      ENV['RATE_LIMIT_ALGORITHM'] = 'sliding_window_log'

      get '/limited'

      expect(RateLimiter.configuration.algorithm).to eq(:sliding_window_log)
      expect(last_response.headers['ratelimit-reset']).to eq('10')
    end

    it 'reads the limit and window from RATE_LIMIT and RATE_LIMIT_WINDOW' do
      ENV['RATE_LIMIT'] = '3'
      ENV['RATE_LIMIT_WINDOW'] = '60'

      expect(burst('/limited', 4)).to eq([200, 200, 200, 429])
      expect(last_response.headers['ratelimit-limit']).to eq('3')
    end

    it 'refuses to boot with an unknown algorithm' do
      ENV['RATE_LIMIT_ALGORITHM'] = 'leaky_bucket'

      expect { app }.to raise_error(RateLimiter::ConfigurationError, /:leaky_bucket is not registered/)
    end

    it 'refuses to boot with a queue algorithm' do
      ENV['RATE_LIMIT_ALGORITHM'] = 'leaky_bucket_queue'

      expect { app }.to raise_error(RateLimiter::ConfigurationError, /RateLimiter\.queue/)
    end
  end

  describe 'shared state through Redis', :redis do
    # config.ru uses the default namespace, and rack-test sends from 127.0.0.1.
    let(:shared_key) { 'rate_limiter:w60:ip:127.0.0.1' }

    before do
      ENV['REDIS_URL'] = redis_url
      ENV['RATE_LIMIT_ALGORITHM'] = 'sliding_window_counter'
      ENV['RATE_LIMIT'] = '60'
      ENV['RATE_LIMIT_WINDOW'] = '60'
      redis.del(shared_key)
    end

    after { redis.del(shared_key) }

    it 'enforces one limit across two servers built from config.ru' do
      server_a = Rack::MockRequest.new(build_app)
      server_b = Rack::MockRequest.new(build_app)

      statuses = Array.new(60) { server_a.get('/limited', 'REMOTE_ADDR' => '127.0.0.1').status }
      response = server_b.get('/limited', 'REMOTE_ADDR' => '127.0.0.1')

      expect(statuses.uniq).to eq([200])
      expect(response.status).to eq(429)
      expect(response.headers).to include('ratelimit-limit' => '60', 'ratelimit-remaining' => '0')
    end

    it 'keeps the counters in Redis' do
      get '/limited'

      expect(redis.hgetall(shared_key)).to include('current' => '1')
    end
  end

  describe 'when Redis is unreachable' do
    before do
      ENV['REDIS_URL'] = 'redis://127.0.0.1:1' # nothing listens on port 1
      ENV['RATE_LIMIT_ALGORITHM'] = 'sliding_window_counter'
    end

    # Keep the warnings out of the test output. `output(...).to_stderr` below
    # still sees them, because it swaps in its own $stderr while it runs.
    around do |example|
      original = $stderr
      $stderr = StringIO.new
      example.run
    ensure
      $stderr = original
    end

    it 'reports each failure in the server log' do
      expect { get '/limited' }
        .to output(/\[rate_limiter\] Redis unavailable, allowing the request: Redis::CannotConnectError/).to_stderr
    end

    it 'says it is rejecting when RATE_LIMIT_REDIS_FAILURE=reject' do
      ENV['RATE_LIMIT_REDIS_FAILURE'] = 'reject'

      expect { get '/limited' }.to output(/Redis unavailable, rejecting the request/).to_stderr
    end

    it 'fails open by default' do
      expect(burst('/limited', 12).uniq).to eq([200])
    end

    it 'fails closed with RATE_LIMIT_REDIS_FAILURE=reject' do
      ENV['RATE_LIMIT_REDIS_FAILURE'] = 'reject'

      get '/limited'

      expect(last_response.status).to eq(429)
      expect(last_response.headers['retry-after']).to eq('1')
    end
  end
end
