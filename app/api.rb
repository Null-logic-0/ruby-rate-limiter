# frozen_string_literal: true

require 'sinatra/base'

# Demo API. Rate limiting is set up in config.ru, not here.
class Api < Sinatra::Base
  set :default_content_type, 'text/plain'

  get '/unlimited' do
    "Unlimited! Let's Go!"
  end

  get '/limited' do
    "Limited, don't over use me!"
  end

  get '/public' do
    'Public data'
  end

  post '/login' do
    'Logged in'
  end

  get '/premium' do
    'Premium content'
  end

  post '/upload' do
    "Uploaded #{request.content_length.to_i} bytes"
  end
end
