# frozen_string_literal: true

source 'https://rubygems.org'

# Any Ruby 4.0.x.
ruby '~> 4.0.0'

# The gem itself, from this folder.
gemspec

# ---- Demo app (config.ru, app/), not needed by the gem ----
gem 'puma', '~> 8.0'
gem 'rackup', '~> 2.2'
gem 'sinatra', '~> 4.1'

# Optional for the gem: shared limits.
gem 'redis', '~> 6.1'

# Optional for the gem: JSON logs.
gem 'logger', '~> 1.7'

# ---- Development only (not in the Docker image) ----
group :development, :test do
  gem 'benchmark', '~> 0.4'
  gem 'rack-test', '~> 2.2'
  gem 'rake', '~> 13.2'
  gem 'rspec', '~> 3.13'
  gem 'simplecov', '~> 1.3', require: false
end
