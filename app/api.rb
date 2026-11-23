# frozen_string_literal: true

require 'sinatra/base'

# Demo HTTP API used to exercise the rate limiter.
class Api < Sinatra::Base
  set :default_content_type, 'text/plain'

  get '/unlimited' do
    "Unlimited! Let's Go!"
  end

  get '/limited' do
    "Limited, don't over use me!"
  end
end
