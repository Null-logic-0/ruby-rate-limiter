# frozen_string_literal: true

require 'rack/test'
require 'rate_limiter/middleware'

RSpec.describe 'config.ru' do
  include Rack::Test::Methods

  settings = %w[RATE_LIMIT_ALGORITHM RATE_LIMIT RATE_LIMIT_WINDOW TRUSTED_PROXIES REDIS_URL RATE_LIMIT_REDIS_FAILURE
                RATE_LIMIT_API_KEYS RATE_LIMIT_PREMIUM_API_KEYS RATE_LIMIT_GLOBAL RATE_LIMIT_BYPASS_IPS
                RATE_LIMIT_BYPASS_API_KEYS]

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

  describe 'the endpoint table' do
    # Frozen clock: nothing refills mid-burst, so every count is exact.
    before { allow(RateLimiter::Clock::Monotonic).to receive(:now).and_return(1_000.0) }

    def statuses(count, verb = :get, path = '/public', body = nil, env = {})
      Array.new(count) do
        send(verb, path, body, env)
        last_response.status
      end
    end

    it 'allows 5 logins a minute per IP' do
      expect(statuses(6, :post, '/login')).to eq([200] * 5 + [429])
      expect(last_response.headers['ratelimit-limit']).to eq('5')
    end

    it 'limits logins by IP, so switching API keys does not help' do
      ENV['RATE_LIMIT_API_KEYS'] = 'sk_a,sk_b'

      statuses(5, :post, '/login', nil, 'HTTP_X_API_KEY' => 'sk_a')

      expect(statuses(1, :post, '/login', nil, 'HTTP_X_API_KEY' => 'sk_b')).to eq([429])
    end

    it 'allows 100 public reads a minute' do
      expect(statuses(101)).to eq([200] * 100 + [429])
    end

    it 'charges uploads by size: 2 MB costs 5 of the 10 per minute' do
      two_mb = 'x' * 2_000_000

      expect(statuses(3, :post, '/upload', two_mb, 'CONTENT_TYPE' => 'application/octet-stream'))
        .to eq([200, 200, 429])
    end

    it 'gives premium API keys 500 premium reads a minute, and everyone else 20' do
      ENV['RATE_LIMIT_PREMIUM_API_KEYS'] = 'sk_premium'

      expect(statuses(21, :get, '/premium')).to eq([200] * 20 + [429])
      get '/premium', nil, 'HTTP_X_API_KEY' => 'sk_premium'
      expect(last_response.headers).to include('ratelimit-limit' => '500', 'ratelimit-remaining' => '499')
    end

    it 'keeps the last 20 public reads for normal traffic: X-Priority: low stops at 80' do
      low = { 'HTTP_X_PRIORITY' => 'low' }

      expect(statuses(81, :get, '/public', nil, low)).to eq([200] * 80 + [429])
      expect(statuses(20)).to eq([200] * 20)
    end

    it 'caps total traffic across clients and endpoints with RATE_LIMIT_GLOBAL' do
      ENV['RATE_LIMIT_GLOBAL'] = '3'

      results = [['/public', '198.51.100.1'], ['/premium', '198.51.100.2'], ['/limited', '198.51.100.3'],
                 ['/public', '198.51.100.4']].map do |path, ip|
        statuses(1, :get, path, nil, 'REMOTE_ADDR' => ip).first
      end

      expect(results).to eq([200, 200, 200, 429])
      expect(last_response.headers['ratelimit-limit']).to eq('3')
    end

    it 'does not charge the global cap for a request an earlier policy rejected' do
      ENV['RATE_LIMIT_GLOBAL'] = '8'

      statuses(6, :post, '/login') # 5 admitted; the 6th rejected by the login policy

      expect(statuses(4)).to eq([200, 200, 200, 429])
    end

    it 'keeps counters per policy: using up /limited leaves /public untouched' do
      statuses(11, :get, '/limited')

      expect(statuses(1)).to eq([200])
    end

    it 'never limits clients in RATE_LIMIT_BYPASS_IPS, and sends them no rate limit headers' do
      ENV['RATE_LIMIT_BYPASS_IPS'] = '10.0.0.0/8'

      expect(statuses(7, :post, '/login', nil, 'REMOTE_ADDR' => '10.1.2.3')).to eq([200] * 7)
      expect(last_response.headers.keys.grep(/\Aratelimit-/)).to be_empty
    end

    it 'never limits clients with a key in RATE_LIMIT_BYPASS_API_KEYS' do
      ENV['RATE_LIMIT_BYPASS_API_KEYS'] = 'sk_partner'

      expect(statuses(7, :post, '/login', nil, 'HTTP_X_API_KEY' => 'sk_partner')).to eq([200] * 7)
    end

    it 'does not let a forged X-Forwarded-For claim a trusted address' do
      ENV['RATE_LIMIT_BYPASS_IPS'] = '10.0.0.0/8'

      expect(statuses(6, :post, '/login', nil, 'HTTP_X_FORWARDED_FOR' => '10.1.2.3')).to eq([200] * 5 + [429])
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
    # Each policy has its own namespace, and rack-test sends from 127.0.0.1.
    let(:shared_key) { 'rate_limiter:limited:w60:ip:127.0.0.1' }
    let(:public_key) { 'rate_limiter:public:w60:ip:127.0.0.1' }
    let(:global_key) { 'rate_limiter:global:w60:global' } # shared by every client, so clean it too

    before do
      ENV['REDIS_URL'] = redis_url
      ENV['RATE_LIMIT_ALGORITHM'] = 'sliding_window_counter'
      ENV['RATE_LIMIT'] = '60'
      ENV['RATE_LIMIT_WINDOW'] = '60'
      redis.del(shared_key, public_key, global_key)
    end

    after { redis.del(shared_key, public_key, global_key) }

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

    it "keeps each policy's counters under its own namespace" do
      get '/limited'
      get '/public'

      expect(redis.hget(shared_key, 'current')).to eq('1')
      expect(redis.hget(public_key, 'current')).to eq('1')
      expect(redis.hget(global_key, 'current')).to eq('2')
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
