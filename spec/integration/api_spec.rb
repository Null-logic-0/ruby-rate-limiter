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

  it 'returns 404 for unknown paths' do
    get '/missing'

    expect(last_response.status).to eq(404)
  end

  # Sinatra decodes and cleans paths before routing. The rate-limiting
  # middleware must recognise all of these too, or they become a bypass.
  describe 'alternative spellings of /limited' do
    ['/%6Cimited', '/lim%69ted', '/./limited', '/x/../limited', '/%2e%2e/limited'].each do |path|
      it "routes #{path} to /limited" do
        get path

        expect(last_response.body).to eq("Limited, don't over use me!")
      end
    end
  end
end
