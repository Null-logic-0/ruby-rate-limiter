# frozen_string_literal: true

require_relative 'lib/rate_guard/version'

Gem::Specification.new do |spec|
  spec.name = 'rate_guard'
  spec.version = RateGuard::VERSION
  spec.authors = ['Luka Tchelidze']
  spec.license = 'MIT'

  spec.summary = 'Rate limiting for Ruby and Rack: six algorithms, per-route policies, optional Redis.'
  spec.description = <<~TEXT.tr("\n", ' ').strip
    Thread-safe rate limiters (token bucket, leaky bucket meter and queue,
    fixed window, sliding window log, sliding window counter) with a Rack 3
    middleware that applies per-route policies, identifies clients by IP,
    API key or user, sends RateLimit headers and retry-after, and can share
    counts between servers through Redis with a fail-open or fail-closed policy.
  TEXT
  spec.homepage = 'https://github.com/Null-logic-0/ruby-rate-limiter'
  spec.metadata = {
    'source_code_uri' => spec.homepage,
    'changelog_uri' => "#{spec.homepage}/blob/main/CHANGELOG.md",
    'rubygems_mfa_required' => 'true',
    # Only push to RubyGems.org.
    'allowed_push_host' => 'https://rubygems.org'
  }

  spec.required_ruby_version = '>= 4.0'

  # Only the library and docs go in the gem (not app/, spec/, examples/...).
  # The .lua file is needed by the Redis algorithm. Build from this folder.
  spec.files = Dir.glob(%w[lib/**/*.{rb,lua} README.md CHANGELOG.md LICENSE], base: __dir__)
  spec.require_paths = ['lib']

  # Rack 3 is needed by the middleware.
  # redis and logger are optional: add them to your Gemfile if you use them.
  spec.add_dependency 'rack', '>= 3.0', '< 4'
end
