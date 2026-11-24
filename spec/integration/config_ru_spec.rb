# frozen_string_literal: true

require 'rack/test'
require 'rate_limiter/middleware'

RSpec.describe 'config.ru' do
  include Rack::Test::Methods

  let(:app) { Rack::Builder.parse_file(File.expand_path('../../config.ru', __dir__)) }
  let(:client_key) { last_request.env[RateLimiter::Middleware::CLIENT_KEY] }

  def burst(path, count, headers = {})
    Array.new(count) do
      get path, {}, headers
      last_response.status
    end
  end

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
end
