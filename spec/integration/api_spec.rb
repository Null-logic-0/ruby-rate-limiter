# frozen_string_literal: true

require 'rack/test'
require_relative '../../app/api'

RSpec.describe Api do
  include Rack::Test::Methods

  def app
    described_class
  end

  describe 'GET /unlimited' do
    it 'responds with the unlimited message as plain text' do
      get '/unlimited'

      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq("Unlimited! Let's Go!")
      expect(last_response.content_type).to eq('text/plain;charset=utf-8')
    end
  end

  describe 'GET /limited' do
    it 'responds with the limited message as plain text' do
      get '/limited'

      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq("Limited, don't over use me!")
      expect(last_response.content_type).to eq('text/plain;charset=utf-8')
    end
  end

  describe 'the endpoint table' do
    { ['GET', '/public'] => 'Public data', ['POST', '/login'] => 'Logged in',
      ['GET', '/premium'] => 'Premium content' }.each do |(verb, path), body|
      it "answers #{verb} #{path}" do
        custom_request verb, path

        expect(last_response.status).to eq(200)
        expect(last_response.body).to eq(body)
      end
    end

    it 'answers POST /upload with the size it received' do
      post '/upload', 'x' * 2048

      expect(last_response.body).to eq('Uploaded 2048 bytes')
    end

    it 'routes only the listed methods' do
      get '/login'

      expect(last_response.status).to eq(404)
    end
  end

  it 'returns 404 for unknown paths' do
    get '/missing'

    expect(last_response.status).to eq(404)
  end

  # Sinatra cleans paths before routing; the middleware must too,
  # or these would skip the limit.
  describe 'alternative spellings of /limited' do
    ['/%6Cimited', '/lim%69ted', '/./limited', '/x/../limited', '/%2e%2e/limited'].each do |path|
      it "routes #{path} to /limited" do
        get path

        expect(last_response.body).to eq("Limited, don't over use me!")
      end
    end
  end
end
