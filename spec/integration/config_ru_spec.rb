# frozen_string_literal: true

require 'rack/test'
require 'rate_limiter/middleware'

RSpec.describe 'config.ru' do
  include Rack::Test::Methods

  settings = %w[RATE_LIMIT_ALGORITHM RATE_LIMIT RATE_LIMIT_WINDOW TRUSTED_PROXIES]

  # Each example boots config.ru from a clean slate: the variables it reads are
  # cleared, and whatever your shell had is put back afterwards, even on failure.
  around do |example|
    saved = settings.to_h { |name| [name, ENV.fetch(name, nil)] }

    begin
      settings.each { |name| ENV.delete(name) }
      RateLimiter.reset_configuration!
      example.run
    ensure
      saved.each { |name, value| ENV[name] = value } # assigning nil deletes the variable
      RateLimiter.reset_configuration!
    end
  end

  # Freeze both clocks so nothing refills mid-burst and every header is exact.
  # Wall time sits 15 s into a 60 s window, so a fixed window never rolls over.
  before do
    allow(RateLimiter::Clock::Monotonic).to receive(:now).and_return(1_000.0)
    allow(RateLimiter::Clock::Wall).to receive(:now).and_return(1_800_000_015.0)
  end

  # Built lazily, on the first request, so an example can set ENV first.
  let(:app) { Rack::Builder.parse_file(File.expand_path('../../config.ru', __dir__)) }
  let(:client_key) { last_request.env[RateLimiter::Middleware::CLIENT_KEY] }

  def burst(path, count, headers = {})
    Array.new(count) do
      get path, {}, headers
      last_response.status
    end
  end

  describe 'with the defaults (token bucket, 10 per 10 seconds)' do
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

    it 'admits a burst of 10 and rejects the 11th with 429' do
      expect(burst('/limited', 11)).to eq([200] * 10 + [429])
      expect(last_response.headers['retry-after']).to eq('1')
    end

    it 'does not give a forged X-Forwarded-For a fresh bucket' do
      burst('/limited', 10)

      get '/limited', {}, { 'HTTP_X_FORWARDED_FOR' => '198.51.100.1' }

      expect(last_response.status).to eq(429)
    end

    it 'never limits /unlimited' do
      expect(burst('/unlimited', 20).uniq).to eq([200])
    end

    it 'reports the limit, what is left and when it resets on the first /limited response' do
      get '/limited'

      expect(last_response.headers).to include('ratelimit-limit' => '10', 'ratelimit-remaining' => '9',
                                               'ratelimit-reset' => '1')
    end

    it 'reports an empty bucket, a full reset and retry-after on the 11th request' do
      burst('/limited', 11)

      expect(last_response.headers).to include('ratelimit-remaining' => '0', 'ratelimit-reset' => '10',
                                               'retry-after' => '1')
    end

    it 'adds no rate limit headers to /unlimited' do
      get '/unlimited'

      expect(last_response.headers).not_to have_key('ratelimit-limit')
    end
  end

  describe 'configured from the environment' do
    it 'uses the algorithm named in RATE_LIMIT_ALGORITHM' do
      ENV['RATE_LIMIT_ALGORITHM'] = 'sliding_window_log'

      get '/limited'

      expect(RateLimiter.configuration.algorithm).to eq(:sliding_window_log)
      expect(last_response.headers['ratelimit-reset']).to eq('10')
    end

    it 'uses the limit and window from RATE_LIMIT and RATE_LIMIT_WINDOW' do
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
end
