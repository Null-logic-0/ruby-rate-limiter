# frozen_string_literal: true

require_relative 'app/api'
require_relative 'lib/rate_limiter'
require_relative 'lib/rate_limiter/middleware'

# Settings come from the environment. A value that isn't a number becomes nil,
# so RateLimiter.configure reports every bad setting together, at boot.
RateLimiter.configure do |config|
  config.algorithm = ENV.fetch('RATE_LIMIT_ALGORITHM', 'token_bucket')
  config.limit = Integer(ENV.fetch('RATE_LIMIT', '10'), exception: false)
  config.window = Float(ENV.fetch('RATE_LIMIT_WINDOW', '10'), exception: false)

  redis_url = ENV.fetch('REDIS_URL', '')
  unless redis_url.empty?
    require 'redis'
    config.redis = Redis.new(url: redis_url, timeout: 0.25)
    config.redis_failure_policy = ENV.fetch('RATE_LIMIT_REDIS_FAILURE', 'allow')

    # Without this, failing open is silent: the API looks healthy while it
    # stops limiting. Every failure is reported in the server's log instead.
    action = config.redis_failure_policy == :reject ? 'rejecting' : 'allowing'
    config.on_redis_error = lambda do |error|
      warn "[rate_limiter] Redis unavailable, #{action} the request: #{error.class}: #{error.message}"
    end
  end
end

trusted_proxies = ENV.fetch('TRUSTED_PROXIES', '').split(',').map(&:strip).reject(&:empty?)

use RateLimiter::Middleware,
    limiter: RateLimiter.limiter,
    paths: ['/limited'],
    client_ip: RateLimiter::Middleware::ClientIp.new(trusted_proxies: trusted_proxies)

run Api
