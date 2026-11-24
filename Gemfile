# frozen_string_literal: true

source 'https://rubygems.org'

# Any 4.0.x patch release: the Docker image (ruby:4.0-slim) tracks the newest one.
ruby '~> 4.0.0'

gem 'puma', '~> 8.0'
gem 'rackup', '~> 2.2'
gem 'sinatra', '~> 4.1'

gem 'redis', '~> 6.1'

group :development, :test do
  gem 'rack-test', '~> 2.2'
  gem 'rake', '~> 13.2'
  gem 'rspec', '~> 3.13'
  gem 'simplecov', '~> 1.3', require: false
end
